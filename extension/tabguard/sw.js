// Tab Guard service worker: activity tracking, sleep scheduler, cold save,
// and the native-messaging bridge to the Chinchilla app. Fully functional
// without the app; the port simply stays disconnected.
import { HOST_NAME, DEFAULT_SETTINGS, COLD_SAVE_CAP, hostnameOf, isProtected } from "./schema.js";

let settings = { ...DEFAULT_SETTINGS };
let gaming = { active: false, pauseVideos: false };
let port = null;
let reconnectDelay = 5_000;

// ── Activity tracking ────────────────────────────────────────────────
// tab.lastAccessed is unreliable (undefined after discard, spotty updates),
// so we keep our own record: per-tabId for this session, per-URL for days.

async function markActive(tabId, url) {
  const now = Date.now();
  const { tabActivity = {} } = await chrome.storage.session.get("tabActivity");
  tabActivity[tabId] = { lastActive: now, url: url ?? tabActivity[tabId]?.url };
  await chrome.storage.session.set({ tabActivity });
  if (url && !isProtected(url)) {
    const { urlActivity = {} } = await chrome.storage.local.get("urlActivity");
    urlActivity[url] = now;
    await chrome.storage.local.set({ urlActivity });
  }
}

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  try {
    const tab = await chrome.tabs.get(tabId);
    await markActive(tabId, tab.url);
  } catch {}
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (changeInfo.url || changeInfo.audible !== undefined) {
    if (tab.active || changeInfo.url) await markActive(tabId, tab.url);
  }
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  const { tabActivity = {} } = await chrome.storage.session.get("tabActivity");
  delete tabActivity[tabId];
  await chrome.storage.session.set({ tabActivity });
});

async function seedActivity() {
  const now = Date.now();
  const { urlActivity = {} } = await chrome.storage.local.get("urlActivity");
  const tabs = await chrome.tabs.query({});
  const tabActivity = {};
  for (const tab of tabs) {
    tabActivity[tab.id] = {
      lastActive: urlActivity[tab.url] ?? now,
      url: tab.url,
    };
  }
  await chrome.storage.session.set({ tabActivity });
}

// ── Scheduler ────────────────────────────────────────────────────────

chrome.runtime.onInstalled.addListener(init);
chrome.runtime.onStartup.addListener(init);

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.settings) {
    settings = { ...DEFAULT_SETTINGS, ...(changes.settings.newValue ?? {}) };
  }
});

async function init() {
  const stored = await chrome.storage.local.get("settings");
  settings = { ...DEFAULT_SETTINGS, ...(stored.settings ?? {}) };
  await seedActivity();
  chrome.alarms.create("tick", { periodInMinutes: 1 });
  connectHost();
}

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name !== "tick") return;
  await sweep();
  await pushStats();
});

function skips(tab) {
  if (tab.active || tab.audible || tab.discarded) return true;
  if (settings.excludePinned && tab.pinned) return true;
  if (isProtected(tab.url)) return true;
  if (settings.allowlist.includes(hostnameOf(tab.url))) return true;
  return false;
}

async function sweep() {
  const now = Date.now();
  const tabs = await chrome.tabs.query({});
  const { tabActivity = {} } = await chrome.storage.session.get("tabActivity");
  const { urlActivity = {} } = await chrome.storage.local.get("urlActivity");
  const discardMs = settings.discardAfterMinutes * 60_000;
  const coldMs = settings.coldSaveAfterDays * 86_400_000;

  for (const tab of tabs) {
    if (skips(tab)) continue;
    const lastActive = tabActivity[tab.id]?.lastActive ?? urlActivity[tab.url] ?? now;

    if (settings.coldSaveEnabled && now - lastActive > coldMs) {
      await coldSave(tab);
      continue;
    }
    if (now - lastActive > discardMs) {
      try { await chrome.tabs.discard(tab.id); } catch {}
    }
  }
  await pruneUrlActivity(urlActivity, now, coldMs);
}

async function coldSave(tab) {
  const { coldSaved = [] } = await chrome.storage.local.get("coldSaved");
  if (!coldSaved.some((item) => item.url === tab.url)) {
    coldSaved.unshift({
      url: tab.url,
      title: tab.title ?? tab.url,
      favIconUrl: tab.favIconUrl ?? "",
      savedAt: Date.now(),
    });
    if (coldSaved.length > COLD_SAVE_CAP) coldSaved.length = COLD_SAVE_CAP;
    await chrome.storage.local.set({ coldSaved });
  }
  try { await chrome.tabs.remove(tab.id); } catch {}
}

async function pruneUrlActivity(urlActivity, now, coldMs) {
  const horizon = coldMs + 7 * 86_400_000;
  let dirty = false;
  for (const [url, at] of Object.entries(urlActivity)) {
    if (now - at > horizon) { delete urlActivity[url]; dirty = true; }
  }
  if (dirty) await chrome.storage.local.set({ urlActivity });
}

// ── Gaming signal ────────────────────────────────────────────────────

async function applyGaming() {
  if (!gaming.active) return;
  const tabs = await chrome.tabs.query({});
  for (const tab of tabs) {
    if (tab.active || tab.discarded || isProtected(tab.url)) continue;
    if (tab.audible && gaming.pauseVideos) {
      // Pausing beats discarding for media tabs: position is preserved.
      try {
        await chrome.scripting.executeScript({
          target: { tabId: tab.id, allFrames: true },
          func: () => document.querySelectorAll("video, audio").forEach((m) => m.pause()),
        });
      } catch {}
      continue;
    }
    if (!tab.audible) {
      try { await chrome.tabs.discard(tab.id); } catch {}
    }
  }
}

// ── Native port ──────────────────────────────────────────────────────

function connectHost() {
  try {
    port = chrome.runtime.connectNative(HOST_NAME);
  } catch {
    port = null;
    scheduleReconnect();
    return;
  }
  reconnectDelay = 5_000;
  port.onMessage.addListener(onHostMessage);
  port.onDisconnect.addListener(() => {
    port = null;
    scheduleReconnect();
  });
  send({ type: "hello", extVersion: chrome.runtime.getManifest().version });
  pushStats();
  // Ping keeps the service worker alive and lets the app mark us connected.
  setInterval(() => send({ type: "pong" }), 30_000);
}

function scheduleReconnect() {
  setTimeout(connectHost, reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, 60_000);
}

function send(message) {
  try { port?.postMessage(message); } catch {}
}

async function onHostMessage(message) {
  switch (message.type) {
    case "settings":
      settings = { ...settings, ...message.settings };
      await chrome.storage.local.set({ settings });
      break;
    case "gaming":
      gaming = { active: !!message.active, pauseVideos: !!message.pauseVideos };
      await applyGaming();
      break;
    case "restoreColdSaved": {
      const { coldSaved = [] } = await chrome.storage.local.get("coldSaved");
      const toRestore = message.all ? coldSaved : coldSaved.filter((i) => message.urls?.includes(i.url));
      for (const item of toRestore) {
        try { await chrome.tabs.create({ url: item.url, active: false }); } catch {}
      }
      const remaining = message.all ? [] : coldSaved.filter((i) => !message.urls?.includes(i.url));
      await chrome.storage.local.set({ coldSaved: remaining });
      break;
    }
    case "openColdSavePage":
      chrome.tabs.create({ url: chrome.runtime.getURL("coldsave.html") });
      break;
    case "ping":
      send({ type: "pong" });
      break;
  }
  await pushStats();
}

async function pushStats() {
  if (!port) return;
  const tabs = await chrome.tabs.query({});
  const discarded = tabs.filter((t) => t.discarded).length;
  const { coldSaved = [] } = await chrome.storage.local.get("coldSaved");
  send({
    type: "stats",
    tabs: tabs.length,
    discarded,
    coldSavedCount: coldSaved.length,
    // Chrome exposes no per-tab memory to extensions; this is a labeled
    // rough estimate (~80 MB per slept tab) and the UI says so.
    estSavedBytes: discarded * 80 * 1024 * 1024,
  });
}

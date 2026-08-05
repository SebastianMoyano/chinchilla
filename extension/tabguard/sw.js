// Tab Guard service worker: activity tracking, sleep scheduler, cold save,
// and the native-messaging bridge to the Chinchilla app. Fully functional
// without the app; the port simply stays disconnected.
import { HOST_NAME, DEFAULT_SETTINGS, COLD_SAVE_CAP, hostnameOf, isProtected } from "./schema.js";

let settings = { ...DEFAULT_SETTINGS };
let gaming = { active: false, pauseVideos: false };
let port = null;
let reconnectDelay = 5_000;
let reconnectTimer = null;

// ── Activity tracking ────────────────────────────────────────────────
// tab.lastAccessed is unreliable (undefined after discard, spotty updates),
// so we keep our own record: per-tabId for this session, per-URL for days.
// Writes are batched: markActive fires on every tab switch, and rewriting
// the whole urlActivity map each time got expensive with thousands of URLs.
// Marks land in in-memory dirty maps, flushed at most every 30 s and on
// every tick alarm (the worker's guaranteed wake-up); readers merge storage
// with the dirty maps, so observed behavior is unchanged.

let dirtyTabActivity = {};   // tabId -> { lastActive, url? } pending flush
let dirtyUrlActivity = {};   // url -> lastActive pending flush
let removedTabIds = new Set();
let flushTimer = null;
const FLUSH_INTERVAL_MS = 30_000;

function markActive(tabId, url) {
  const entry = dirtyTabActivity[tabId] ?? (dirtyTabActivity[tabId] = {});
  entry.lastActive = Date.now();
  if (url) entry.url = url; // no url: keep whatever storage already has
  if (url && !isProtected(url)) dirtyUrlActivity[url] = entry.lastActive;
  scheduleFlush();
}

function scheduleFlush() {
  if (flushTimer !== null) return;
  flushTimer = setTimeout(flushActivity, FLUSH_INTERVAL_MS);
}

async function flushActivity() {
  if (flushTimer !== null) { clearTimeout(flushTimer); flushTimer = null; }
  if (!Object.keys(dirtyTabActivity).length &&
      !Object.keys(dirtyUrlActivity).length &&
      !removedTabIds.size) return;
  // Snapshot and reset first, so marks arriving mid-write land in the next flush.
  const tabDirty = dirtyTabActivity; dirtyTabActivity = {};
  const urlDirty = dirtyUrlActivity; dirtyUrlActivity = {};
  const removed = removedTabIds; removedTabIds = new Set();

  const { tabActivity = {} } = await chrome.storage.session.get("tabActivity");
  for (const id of removed) delete tabActivity[id];
  for (const [id, entry] of Object.entries(tabDirty)) {
    tabActivity[id] = { ...tabActivity[id], ...entry };
  }
  await chrome.storage.session.set({ tabActivity });

  if (Object.keys(urlDirty).length) {
    const { urlActivity = {} } = await chrome.storage.local.get("urlActivity");
    Object.assign(urlActivity, urlDirty);
    await chrome.storage.local.set({ urlActivity });
  }
}

async function getTabActivity() {
  const { tabActivity = {} } = await chrome.storage.session.get("tabActivity");
  for (const id of removedTabIds) delete tabActivity[id];
  for (const [id, entry] of Object.entries(dirtyTabActivity)) {
    tabActivity[id] = { ...tabActivity[id], ...entry };
  }
  return tabActivity;
}

async function getUrlActivity() {
  const { urlActivity = {} } = await chrome.storage.local.get("urlActivity");
  return Object.assign(urlActivity, dirtyUrlActivity);
}

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  try {
    const tab = await chrome.tabs.get(tabId);
    markActive(tabId, tab.url);
  } catch {}
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.url || changeInfo.audible !== undefined) {
    if (tab.active || changeInfo.url) markActive(tabId, tab.url);
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  delete dirtyTabActivity[tabId];
  removedTabIds.add(tabId);
  scheduleFlush();
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
    scheduleTick();
  }
});

async function init() {
  const stored = await chrome.storage.local.get("settings");
  settings = { ...DEFAULT_SETTINGS, ...(stored.settings ?? {}) };
  await seedActivity();
  scheduleTick();
  connectHost();
}

// The tick only needs to fire a few times per discard window, not at
// Chrome's 1-minute floor forever; re-created whenever settings change.
let tickPeriodMinutes = 0;
function scheduleTick() {
  const period = Math.max(1, Math.min(settings.discardAfterMinutes / 5, 5));
  if (period === tickPeriodMinutes) return;
  tickPeriodMinutes = period;
  chrome.alarms.create("tick", { periodInMinutes: period });
}

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name !== "tick") return;
  await flushActivity(); // persist activity before the worker can suspend
  const tabs = await sweep();
  await pushStats(tabs);
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
  const tabActivity = await getTabActivity();
  const urlActivity = await getUrlActivity();
  const discardMs = settings.discardAfterMinutes * 60_000;
  const coldMs = settings.coldSaveAfterDays * 86_400_000;
  const toColdSave = [];

  for (const tab of tabs) {
    if (skips(tab)) continue;
    const lastActive = tabActivity[tab.id]?.lastActive ?? urlActivity[tab.url] ?? now;

    if (settings.coldSaveEnabled && now - lastActive > coldMs) {
      toColdSave.push(tab);
      continue;
    }
    if (now - lastActive > discardMs) {
      try { await chrome.tabs.discard(tab.id); tab.discarded = true; } catch {}
    }
  }
  await coldSave(toColdSave);
  await pruneUrlActivity(urlActivity, now, coldMs);
  // Post-sweep view of the world, so pushStats needn't query again.
  const coldIds = new Set(toColdSave.map((tab) => tab.id));
  return tabs.filter((tab) => !coldIds.has(tab.id));
}

// One read and one write of the coldSaved array per sweep, no matter how
// many tabs qualify.
async function coldSave(tabs) {
  if (!tabs.length) return;
  const { coldSaved = [] } = await chrome.storage.local.get("coldSaved");
  const known = new Set(coldSaved.map((item) => item.url));
  let changed = false;
  for (const tab of tabs) {
    if (!known.has(tab.url)) {
      known.add(tab.url);
      coldSaved.unshift({
        url: tab.url,
        title: tab.title ?? tab.url,
        favIconUrl: tab.favIconUrl ?? "",
        savedAt: Date.now(),
      });
      changed = true;
    }
  }
  if (coldSaved.length > COLD_SAVE_CAP) coldSaved.length = COLD_SAVE_CAP;
  if (changed) await chrome.storage.local.set({ coldSaved });
  for (const tab of tabs) {
    try { await chrome.tabs.remove(tab.id); } catch {}
  }
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
  if (reconnectTimer !== null) { clearTimeout(reconnectTimer); reconnectTimer = null; }

  try {
    port = chrome.runtime.connectNative(HOST_NAME);
  } catch {
    port = null;
    scheduleReconnect();
    return;
  }
  port.onMessage.addListener(onHostMessage);
  port.onDisconnect.addListener(() => {
    port = null;
    scheduleReconnect();
  });
  send({ type: "hello", extVersion: chrome.runtime.getManifest().version });
  pushStats();
  // No keepalive ping here: since Chrome 105 an open native-messaging port
  // extends the worker's lifetime by itself, and the app pings us on its own
  // schedule (answered with "pong" in onHostMessage). A 30 s interval used to
  // do this — created per attempt and never cleared, so with the app absent
  // ~720 leaked timers an hour all flushed into its stdin the moment it came up.
}

function scheduleReconnect() {
  if (reconnectTimer !== null) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectHost();
  }, reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, 60_000);
}

function send(message) {
  try { port?.postMessage(message); } catch {}
}

async function onHostMessage(message) {
  // Proof the app is actually there. The backoff used to reset as soon as
  // connectNative() returned — but it returns a port even with no host
  // installed and drops it immediately, so the delay never grew past 5 s and
  // Chrome relaunched the lookup every 5 seconds, forever.
  reconnectDelay = 5_000;

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

async function pushStats(tabs) {
  if (!port) return;
  tabs ??= await chrome.tabs.query({}); // sweep passes its list; other callers query
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

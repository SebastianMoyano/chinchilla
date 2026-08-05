import { DEFAULT_SETTINGS } from "./schema.js";

const fields = [
  "discardAfterMinutes", "coldSaveEnabled", "coldSaveAfterDays",
  "excludePinned", "pauseVideosWhileGaming",
];

async function load() {
  const { settings = {} } = await chrome.storage.local.get("settings");
  const merged = { ...DEFAULT_SETTINGS, ...settings };
  for (const field of fields) {
    const el = document.getElementById(field);
    if (el.type === "checkbox") el.checked = merged[field];
    else el.value = merged[field];
  }
  document.getElementById("allowlist").value = merged.allowlist.join(", ");
}

// People paste full URLs here; the matcher compares hostnames, so anything
// not reduced to one would never match and the exclusion would fail silently.
function toHostname(entry) {
  const s = entry.trim().toLowerCase();
  if (!s) return "";
  for (const candidate of [s, "https://" + s]) {
    try {
      const host = new URL(candidate).hostname;
      if (host) return host;
    } catch {}
  }
  return "";
}

async function save() {
  const settings = {};
  for (const field of fields) {
    const el = document.getElementById(field);
    if (el.type === "checkbox") {
      settings[field] = el.checked;
      continue;
    }
    // An empty or garbled field must not become 0 (which would sleep every
    // tab within a minute) or NaN (which silently disables the feature).
    let value = el.value.trim() === "" ? NaN : Number(el.value);
    if (!Number.isFinite(value)) value = DEFAULT_SETTINGS[field];
    value = Math.min(Number(el.max), Math.max(Number(el.min), Math.round(value)));
    el.value = value;
    settings[field] = value;
  }
  const allowlistEl = document.getElementById("allowlist");
  settings.allowlist = allowlistEl.value.split(",").map(toHostname).filter(Boolean);
  // Write the cleaned-up list back so the user sees what actually took effect.
  allowlistEl.value = settings.allowlist.join(", ");

  if (settings.pauseVideosWhileGaming) {
    const granted = await chrome.permissions.request({ origins: ["<all_urls>"] });
    if (!granted) {
      settings.pauseVideosWhileGaming = false;
      document.getElementById("pauseVideosWhileGaming").checked = false;
    }
  }
  await chrome.storage.local.set({ settings });
}

for (const field of [...fields, "allowlist"]) {
  document.getElementById(field).addEventListener("change", save);
}
document.getElementById("openColdSave").onclick = () => {
  chrome.tabs.create({ url: chrome.runtime.getURL("coldsave.html") });
};

chrome.storage.local.get("coldSaved").then(({ coldSaved = [] }) => {
  document.getElementById("saved").textContent = `${coldSaved.length} saved`;
});

load();

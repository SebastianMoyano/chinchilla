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

async function save() {
  const settings = {};
  for (const field of fields) {
    const el = document.getElementById(field);
    settings[field] = el.type === "checkbox" ? el.checked : Number(el.value);
  }
  settings.allowlist = document.getElementById("allowlist").value
    .split(",").map((s) => s.trim()).filter(Boolean);

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

import { DEFAULT_SETTINGS } from "./schema.js";

async function load() {
  const { coldSaved = [] } = await chrome.storage.local.get("coldSaved");
  const { settings = {} } = await chrome.storage.local.get("settings");
  document.getElementById("days").textContent =
    settings.coldSaveAfterDays ?? DEFAULT_SETTINGS.coldSaveAfterDays;

  const list = document.getElementById("list");
  list.textContent = "";
  document.getElementById("empty").hidden = coldSaved.length > 0;

  let currentDay = "";
  for (const item of coldSaved) {
    const day = new Date(item.savedAt).toLocaleDateString();
    if (day !== currentDay) {
      currentDay = day;
      const h = document.createElement("div");
      h.className = "day";
      h.textContent = day;
      list.appendChild(h);
    }
    const row = document.createElement("div");
    row.className = "item";
    const icon = document.createElement("img");
    icon.src = item.favIconUrl || "icons/16.png";
    icon.onerror = () => { icon.src = "icons/16.png"; };
    const link = document.createElement("a");
    link.href = "#";
    link.textContent = item.title || item.url;
    link.title = item.url;
    link.onclick = (e) => { e.preventDefault(); restore([item.url]); };
    const forget = document.createElement("button");
    forget.textContent = "✕";
    forget.title = "Forget";
    forget.onclick = () => removeItems([item.url]);
    row.append(icon, link, forget);
    list.appendChild(row);
  }
}

async function restore(urls) {
  for (const url of urls) {
    await chrome.tabs.create({ url, active: urls.length === 1 });
  }
  await removeItems(urls);
}

async function removeItems(urls) {
  const { coldSaved = [] } = await chrome.storage.local.get("coldSaved");
  await chrome.storage.local.set({
    coldSaved: coldSaved.filter((i) => !urls.includes(i.url)),
  });
  await load();
}

document.getElementById("restoreAll").onclick = async () => {
  const { coldSaved = [] } = await chrome.storage.local.get("coldSaved");
  await restore(coldSaved.map((i) => i.url));
};
document.getElementById("clearAll").onclick = async () => {
  if (confirm("Forget every saved tab? They won't be reopened.")) {
    await chrome.storage.local.set({ coldSaved: [] });
    await load();
  }
};

load();
chrome.storage.onChanged.addListener(load);

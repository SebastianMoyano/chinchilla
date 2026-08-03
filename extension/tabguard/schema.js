// Shared constants for Tab Guard. Message schema is additive-only.
export const HOST_NAME = "com.sebastian.chinchilla";

export const DEFAULT_SETTINGS = {
  discardAfterMinutes: 30,   // sleep tabs inactive longer than this
  coldSaveEnabled: false,    // close+save ancient tabs
  coldSaveAfterDays: 7,
  excludePinned: true,
  allowlist: [],             // hostnames never touched
  pauseVideosWhileGaming: false,
};

export const COLD_SAVE_CAP = 500;

export function hostnameOf(url) {
  try {
    return new URL(url).hostname;
  } catch {
    return "";
  }
}

export function isProtected(url) {
  // Never touch browser-internal pages.
  return !url || !/^https?:/.test(url);
}

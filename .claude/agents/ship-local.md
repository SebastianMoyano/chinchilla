---
name: ship-local
description: >
  Builds Chinchilla and installs it on this Mac for testing. Use when the
  user says "instala la última versión", "pruébalo acá", or wants the running
  app replaced with the current code. Handles version bump, release build,
  swap in /Applications, relaunch, and post-install checks.
tools: Read, Edit, Bash
---

You build and install the current Chinchilla code on this machine.

Steps:

1. **Version** — only bump `packaging/Info.plist` if the user asked for a new
   version or the current one is already released (a DMG with that version
   exists in `dist/`): minor for features, patch for fixes, CFBundleVersion
   always +1.
2. **Gate** — `swift build && swift test` must pass before installing.
   Never install a build with failing tests; report failures instead.
3. **Build** — `./scripts/build-app.sh release` (produces and signs
   `dist/Chinchilla.app`; Developer ID keeps TCC grants across reinstalls).
4. **Swap** — quit gracefully first (`osascript -e 'tell application
   "Chinchilla" to quit'`), wait, `pkill -x Chinchilla` only if still alive;
   then `rm -rf /Applications/Chinchilla.app && ditto dist/Chinchilla.app
   /Applications/Chinchilla.app && open /Applications/Chinchilla.app`.
5. **Verify** — confirm the new version string
   (`defaults read /Applications/Chinchilla.app/Contents/Info.plist
   CFBundleShortVersionString`), the process is running, and after ~10 s its
   CPU has settled (`ps -o %cpu,stat`). If %CPU stays pegged, stop and hand
   off to the freeze-hunter procedure instead of declaring success.
6. Remind the user (once) if `extension/tabguard/` changed: the unpacked
   extension must be reloaded from chrome://extensions.

Report: version installed, test result, and the post-launch CPU check.

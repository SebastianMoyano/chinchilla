# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Chinchilla: a native macOS cleaning/maintenance app (SwiftUI, Swift 6, zero external dependencies, builds with Command Line Tools only — no Xcode). Ships as a signed+notarized .app whose binary doubles as a CLI (`chinchilla scan/clean/history/status`). Spanish README; code and comments in English.

## Commands

```bash
swift build                      # compile all targets
swift test                       # full suite (swift-testing, @Test functions)
swift test --filter <name>       # single test / suite by name substring
./scripts/build-app.sh debug     # build dist/Chinchilla.app (debug)
./scripts/dev-run.sh             # build debug bundle and launch it
./scripts/build-app.sh release   # release bundle (CHINCHILLA_UNIVERSAL=1 for arm64+x86_64)
./scripts/release.sh             # sign + notarize + DMG (needs Developer ID + notary profile)
node --check extension/tabguard/sw.js   # syntax-check the Chrome extension worker
```

- **Always test TCC-dependent features (screen recording, Full Disk Access) from the bundle** (`dev-run.sh`), never `swift run` — permissions attach to the bundle identity.
- Version lives in `packaging/Info.plist` (CFBundleShortVersionString + CFBundleVersion). Bump minor for features, patch for fixes; build number always increments. Local install for testing: build release, quit the running app, replace `/Applications/Chinchilla.app`, relaunch (Developer ID signing keeps TCC grants across reinstalls).

## Architecture

SwiftPM targets, layered bottom-up:

- **DiskScanKit** — parallel `fts(3)` disk walking (`FTSWalker`), sizing (`DiskSize`), duplicates, artifact hunting. Home of the two concurrency primitives everything else uses: `Blocking.run` (bounded gate for blocking work off the cooperative pool) and `CancelFlag`/`isCancelled` closures, plus `Locked<T>`.
- **SystemKit** — syscall/IOKit/process layer: `ProcessMemory` (libproc sampling), `SystemStats`, `ShellRunner` (deadline-safe process spawning), `RollingLog` (bounded JSONL logs), `NativeMessaging` (Chrome extension host), `AppTerminator`, `ProcessPauser`.
- **CleanCore** — cleaning domain: `RuleCatalog` (what's junk), `Scanner`, `Cleaner`, `SafetyPolicy` (deny-prefixes), `OrphanFinder`, `AppInventory`.
- **CastKit** (+ **VirtualDisplayKit**) — three cast protocols implemented from scratch: Google Cast v2 (hand-rolled protobuf over TLS, `GoogleCast.swift`), DLNA/UPnP, FCast. Screen mirroring: ScreenCaptureKit → VideoToolbox H.264 → RTP/AES (`CastMirrorSession`, fast path) or HLS/fMP4 over a local `CastHTTPServer` (fallback).
- **StreamHostKit** — GameStream/Moonlight host (Bonjour `_nvstream._tcp`, PIN pairing, openssl-minted identity in `HostIdentity`).
- **Chinchilla** (executable) — SwiftUI app. `AppState` owns one `@Observable` model per screen (`Sources/Chinchilla/ViewModels/`); views in `Sources/Chinchilla/Views/<Feature>/`. `ChinchillaCLI` routes CLI subcommands; `MenuBarView` is the always-alive menu-bar panel; this is an accessory app that keeps running when the window closes — that fact drives most of the rules below.
- **extension/tabguard/** — Chrome MV3 extension (Tab Guard), talks to the app via native messaging + files in Application Support.

Tests are swift-testing (`@Test`, `#expect`), organized per-target under `Tests/`.

## Hard-learned rules (each one was a shipped bug — do not reintroduce)

### UI freezes
1. **Never add per-screen `.toolbar { }` items.** The window toolbar is `MainWindow.swift`'s `.toolbar(id: "main")` with a *constant* item set; per-screen actions go inside `ScreenToolbarItem` (contents switch on `appState.selection`). Changing the window's toolbar item set makes AppKit rebuild the toolbar, which live-locks in an endless menu-form-representation loop resolving images through CUICatalog (app frozen at 100% of a core). Custom-styled `Label`s inside toolbar items make it worse. Both rules are documented at the top of `MainWindow.swift`.
2. **Diagnosing a "freeze"**: `sample $(pgrep -x Chinchilla) 3 -file out.txt` and `/usr/bin/log show --last 10m --predicate 'process == "Chinchilla"'`. Look for the AppKit warning "layoutSubtreeIfNeeded has continued for 300 iterations" (layout loop) vs a blocked main thread (deadlock). A stack full of `AppKitToolbarItem`/`PlatformItemListNamedImageRepresentable`/`CUICatalog` frames is the toolbar bug above.
3. **No expensive work in `body` or computed properties read by `body`.** Pattern to follow: store the value and refresh it at the moments it can change (`CastModel.macAddressForDisplay`, `screenPermissionGranted`). Derive chart/list aggregates once per data change in the model, never per render (`MemoryHistoryModel.recompute`, `DeepCleanModel.selectedCountsByCategory`, `TreemapView`'s cached layout).

### Background work in an app that never quits
4. **Everything that starts must have a paired stop tied to visibility.** This app lives in the menu bar for weeks; an unpaired `onAppear` start runs forever. Patterns: `CastModel.discoveryViewAppeared()/discoveryViewDisappeared()` (viewer refcount stops the three Bonjour browsers), `GamingModel.statsViewerAppeared()` (1 Hz sampling only while the screen/overlay is visible), `DesktopWidgetModel.hide()` (drops `contentView` so the `.task` loop cancels — `orderOut` alone does not).
5. **Polling loops must end on their own**, not only via user action: DLNA position poll stops at end-of-track and after 5 missed responses; every `AsyncStream` close path must cancel its heartbeat, cancel the connection, and call `continuation.finish()` or consumers hang forever (`GoogleCast.swift` handles ready/failed/cancelled *and* the remote-FIN receive path — all three).
6. **Rate-limit process spawns and re-reads** behind staleness windows: `tmutil` (SnapshotModel, 5 min), `shortcuts list` (GamingModel, 5 min), `docker` idle probe (2 min), SSDP sweep (`startDiscoveryIfStale`, 30 s), history file loaded once per launch. Follow these when adding anything that shells out on a view appearance.

### Blocking and cancellation
7. **All blocking work goes through `Blocking.run`** (bounded gate; keeps the cooperative pool alive). `waitUntilExit`, synchronous file I/O, and full-disk walks must never run on the main actor or bare in an async context (`HostIdentity` keygen, `AppTerminator.close`'s pid scan).
8. **`Task.isCancelled` is always false inside `Blocking.run`** — long scans take an `isCancelled: (@Sendable () -> Bool)?` parameter checked every ~2048 entries (`DiskSize.allocated`, `DuplicateFinder.find`, `Scanner`, `OrphanFinder`, `ArtifactFinder`). New scanners must accept it too.

### Bounded resources
9. **Logs and in-memory histories are capped, and both caps must actually hold**: `RollingLog.trimIfNeeded` enforces bytes *and* lines (trimming only on line count once let the memory log rewrite ~4.5 MB per minute forever — `RollingLogTests` has the regression test); the sampler's in-memory array mirrors the disk cap (`MemoryHistory.keptSamples`).
10. **Track every accepted `NWConnection` and cancel it in `stop()`** (`CastHTTPServer.stopAll`, `GameStreamHost.live`); when replacing a connection's `stateUpdateHandler`, the replacement must keep removing the connection from the live list. Cap every network frame/buffer (`GoogleCast.maxFrameBytes` and the comment there).
11. **Bonjour browsers are continuous** — never restart them for "refresh" (that empties the list); `start()` guards `browser == nil`, refresh only re-runs the one-shot SSDP sweep.

### Scanning
12. **Dedupe candidate paths before sizing, not after** — two rules matching the same directory means walking a multi-GB tree twice (`cachesSkipNames` in `RuleCatalog` excludes the dirs the dev rules name; commit 1dd1277 "The freeze was two rules finding the same folder").
13. In fts hot loops, materialize `String`s only for entries that survive filters; hardlink dedupe keys are `(dev, ino)` structs, not interpolated strings (`FTSWalker`, `DuplicateFinder`).

### Extension (sw.js)
14. Storage writes are batched/debounced (dirty maps flushed every 30 s and on the tick alarm) — never a full-map rewrite per tab event. The tick alarm period derives from the discard threshold. No keepalive `setInterval`: Chrome ≥105 keeps the worker alive for the open native-messaging port (a 30 s keepalive once leaked ~720 intervals flooding stdin — comment in the file).

## Where to look first

- New screen/feature: model in `Sources/Chinchilla/ViewModels/` (owned by `AppState`), view in `Sources/Chinchilla/Views/<Feature>/`, follow rules 1, 3, 4.
- Cleaning rules / what gets deleted: `CleanCore/RuleCatalog.swift` + `SafetyPolicy.swift` (deny list) + `Scanner.swift`.
- Cast bugs: `CastModel.swift` (UI orchestration) → `CastKit/` per protocol; mirroring paths in `CastMirrorSession` (fast) vs `ScreenStreamer`+`CastHTTPServer` (fallback).
- Performance regressions: re-read the rules above; the codebase's own comments mark past hangs — a comment starting with why something is stored/bounded/stopped is load-bearing, keep the invariant when editing.

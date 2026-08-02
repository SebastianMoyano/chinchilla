#!/bin/bash
# Build the debug bundle and launch it. Always test TCC-dependent features
# from the bundle (never `swift run`).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh" debug
open "$ROOT/dist/Chinchilla.app"

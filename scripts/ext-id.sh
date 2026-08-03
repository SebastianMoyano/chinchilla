#!/bin/bash
# Derives the Tab Guard extension ID from the pinned public key in
# manifest.json (SHA-256 of the DER key, first 128 bits, hex mapped a-p).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT/extension/tabguard/manifest.json" <<'EOF'
import base64, hashlib, json, sys
key = json.load(open(sys.argv[1]))["key"]
digest = hashlib.sha256(base64.b64decode(key)).hexdigest()[:32]
print(digest.translate(str.maketrans("0123456789abcdef", "abcdefghijklmnop")))
EOF

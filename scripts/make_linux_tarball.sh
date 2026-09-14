#!/bin/bash
# Builds the iphone-vm-linux.tar.gz release tarball: the CLI, the web UI, the backend scripts and the
# manifest, laid out the way Linux/iphone-vm looks for them outside a git checkout (./backend, ./manifest.json).
# Usage: scripts/make_linux_tarball.sh [output-dir]      (default: ./out)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/out}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$OUT" "$STAGE/iphone-vm/backend"
cp "$ROOT/Linux/iphone-vm" "$ROOT/Linux/webui.py" "$ROOT/Linux/README.txt" "$STAGE/iphone-vm/"
cp -r "$ROOT/Windows/wsl/." "$STAGE/iphone-vm/backend/"
cp "$ROOT/Mac/Resources/manifest.json" "$STAGE/iphone-vm/manifest.json"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/iphone-vm/"
chmod +x "$STAGE/iphone-vm/iphone-vm" "$STAGE/iphone-vm/backend/"*.sh

# The backend must be self-contained: nothing may reach back into the repo layout.
if grep -rn '\.\./Windows/wsl\|\.\./Mac/Resources' "$STAGE/iphone-vm/backend" >/dev/null 2>&1; then
    echo "backend still refers to the repo layout" >&2; exit 1
fi
tar -czf "$OUT/iphone-vm-linux.tar.gz" -C "$STAGE" iphone-vm
echo "$OUT/iphone-vm-linux.tar.gz"
tar -tzf "$OUT/iphone-vm-linux.tar.gz" | head -20

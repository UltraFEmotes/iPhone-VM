#!/bin/bash
# Copies a .utm VM package into the InfernoPhone app's Documents folder on the iPhone (AFC/house_arrest).
# The app lists every .utm package in its Documents folder on launch.
# Usage: push_vm_to_phone.sh [path/to/VM.utm]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="${1:-$ROOT/out/iPhone11-iOS14.utm}"
DEVICE="${DEVICE:-00008150-000431062E40C01C}"   # iPhone 17
BUNDLE_ID="${BUNDLE_ID:-com.infernophone.9ll7add265.UTM}"

[ -f "$PKG/config.plist" ] || { echo "not a .utm package: $PKG" >&2; exit 1; }
NAME="$(basename "$PKG")"

afc() { printf '%s\nquit\n' "$1" | afcclient -u "$DEVICE" --documents "$BUNDLE_ID" 2>&1; }

echo "== copying $NAME ($(du -sh "$PKG" | cut -f1)) to $BUNDLE_ID Documents; this takes a while over USB"
afc "put -rf \"$PKG\" \"/$NAME\""
echo "== on device:"
afc "ls -l \"/$NAME/Data\""

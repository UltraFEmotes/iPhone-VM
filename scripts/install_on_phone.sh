#!/bin/bash
# Builds the InfernoPhone app (UTM iOS scheme) with free-account automatic signing and installs it
# on the connected iPhone. Launch it afterwards through StikDebug so JIT is enabled.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/App"
DEVICE="${DEVICE:-00008150-000431062E40C01C}"   # iPhone 17
DERIVED="$ROOT/out/DerivedData"

cd "$APP_DIR"
[ -f CodeSigning.xcconfig ] || { echo "missing App/CodeSigning.xcconfig" >&2; exit 1; }

xcodebuild \
    -project UTM.xcodeproj \
    -scheme iOS \
    -configuration Release \
    -destination "id=$DEVICE" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    build 2>&1 | tee "$ROOT/out/install_build.log" | grep -E "error:|warning: .*provision|\*\* BUILD (SUCCEEDED|FAILED) \*\*" || true

APP="$(find "$DERIVED/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP" ] || { echo "BUILD FAILED - see $ROOT/out/install_build.log" >&2; exit 1; }
echo "== built $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier"

xcrun devicectl device install app --device "$DEVICE" "$APP"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
echo "== installed $BUNDLE_ID on $DEVICE"
echo "Open StikDebug and launch the app from there to enable JIT."

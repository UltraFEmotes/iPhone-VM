#!/bin/bash
# Wraps the Inferno iOS dylib as qemu-aarch64-softmmu.framework, laid out exactly like UTM's
# (mirrors fixup_dylib/fixup_imports in UTM's scripts/build_dependencies.sh).
# Usage: package_qemu_framework.sh [input.dylib] [output Frameworks dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="${1:-$ROOT/deps/inferno-ios/build-ios/libqemu-aarch64-softmmu.dylib}"
OUT_DIR="${2:-$ROOT/out/Frameworks}"

[ -f "$IN" ] || { echo "missing input dylib: $IN" >&2; exit 1; }

BASE="$(basename "$IN")"
BASEFILENAME="${BASE%.*}"
LIBNAME="${BASEFILENAME#lib}"                 # qemu-aarch64-softmmu
FRAMEWORK="$OUT_DIR/$LIBNAME.framework"
NEWFILE="$FRAMEWORK/$LIBNAME"

rm -rf "$FRAMEWORK"
mkdir -p "$FRAMEWORK"
cp "$IN" "$NEWFILE"

MINOS="$(vtool -show-build-version "$IN" 2>/dev/null | awk '/minos/ {print $2; exit}')"
MINOS="${MINOS:-14.0}"
PLIST="$FRAMEWORK/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $LIBNAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.utmapp.$LIBNAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string $MINOS" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0" "$PLIST"

install_name_tool -id "@rpath/$LIBNAME.framework/$LIBNAME" "$NEWFILE"

# Rewrite every dependency that came from a sysroot lib dir (UTM's CI path or ours) or @rpath
# into UTM's framework form: @rpath/<name>.framework/<name>
otool -L "$NEWFILE" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    dir="$(dirname "$dep")"
    case "$dir" in
        */sysroot-iOS-arm64/lib|@rpath) ;;
        *) continue ;;
    esac
    [ "$dep" = "@rpath/$LIBNAME.framework/$LIBNAME" ] && continue
    base="$(basename "$dep")"
    name="${base%.*}"; name="${name#lib}"
    case "$dep" in @rpath/*.framework/*) continue ;; esac
    install_name_tool -change "$dep" "@rpath/$name.framework/$name" "$NEWFILE"
done

codesign --force --sign - "$NEWFILE" >/dev/null 2>&1 || true

echo "== packaged $FRAMEWORK"
otool -L "$NEWFILE" | tail -n +2 | awk '{print "   " $1}'
# Every @rpath framework we link must exist in UTM's sysroot, or the app will fail to launch
missing=0
for fw in $(otool -L "$NEWFILE" | tail -n +2 | awk '{print $1}' | grep -oE '^@rpath/[^/]+\.framework' | sed 's#@rpath/##'); do
    [ "$fw" = "$LIBNAME.framework" ] && continue
    [ -d "$HOME/Documents/iphone/UTM/sysroot-iOS-arm64/Frameworks/$fw" ] || { echo "   MISSING in sysroot: $fw"; missing=1; }
done
[ $missing -eq 0 ] && echo "   all linked frameworks present in UTM sysroot"
nm -gU "$NEWFILE" | grep -E " _qemu_(init|main_loop|cleanup)$" || { echo "missing qemu entry points" >&2; exit 1; }

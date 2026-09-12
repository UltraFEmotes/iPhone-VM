#!/bin/bash
# Cross-compiles ChefKiss Inferno (ios-port branch) as libqemu-aarch64-softmmu.dylib for arm64 iOS,
# against UTM's prebuilt iOS sysroot plus our own lzfse/nettle/libtasn1 builds.
# Output: deps/inferno-ios/build-ios/libqemu-aarch64-softmmu.dylib (exports qemu_init/qemu_main_loop/qemu_cleanup)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/deps/inferno-ios"
BUILD="$SRC/build-ios"
UTM_SYSROOT="$HOME/Documents/iphone/UTM/sysroot-iOS-arm64"
OUR_PREFIX="$ROOT/deps/ios-arm64"
IOS_MIN="${IOS_MIN:-14.0}"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
CLANGXX="$(xcrun --sdk iphoneos --find clang++)"
AR="$(xcrun --sdk iphoneos --find ar)"
NM="$(xcrun --sdk iphoneos --find nm)"
RANLIB="$(xcrun --sdk iphoneos --find ranlib)"
STRIP="$(xcrun --sdk iphoneos --find strip)"

for d in "$SRC" "$UTM_SYSROOT/lib" "$OUR_PREFIX/lib"; do
    [ -d "$d" ] || { echo "missing: $d" >&2; exit 1; }
done

# Python modules QEMU's build needs live in UTM's build venv
export PATH="$HOME/Documents/iphone/UTM/.buildvenv/bin:$PATH"

TARGET_FLAGS="-target arm64-apple-ios$IOS_MIN -arch arm64 -isysroot $SDK"
INC_FLAGS="-I$UTM_SYSROOT/include -I$OUR_PREFIX/include -F$UTM_SYSROOT/Frameworks"
LIB_FLAGS="-L$UTM_SYSROOT/lib -L$OUR_PREFIX/lib -F$UTM_SYSROOT/Frameworks -lhogweed -lnettle"

export PKG_CONFIG_LIBDIR="$UTM_SYSROOT/lib/pkgconfig:$UTM_SYSROOT/share/pkgconfig:$OUR_PREFIX/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""
unset PKG_CONFIG_PATH || true

mkdir -p "$BUILD"
CROSS="$BUILD/ios-arm64.cross"
q() { printf "'%s'" "$1"; }
{
    echo "[binaries]"
    echo "c = [$(q "$CLANG"), '-target', 'arm64-apple-ios$IOS_MIN']"
    echo "cpp = [$(q "$CLANGXX"), '-target', 'arm64-apple-ios$IOS_MIN']"
    echo "objc = [$(q "$CLANG"), '-target', 'arm64-apple-ios$IOS_MIN']"
    echo "ar = [$(q "$AR")]"
    echo "nm = [$(q "$NM")]"
    echo "ranlib = [$(q "$RANLIB")]"
    echo "strip = [$(q "$STRIP"), '-x']"
    echo "pkg-config = [$(q "$(command -v pkg-config)")]"
    echo "python = [$(q "$(command -v python3)")]"
    echo "glib-mkenums = [$(q "$(command -v glib-mkenums)")]"
    echo "glib-compile-resources = [$(q "$(command -v glib-compile-resources)")]"
    echo "[host_machine]"
    echo "system = 'ios'"
    echo "kernel = 'xnu'"
    echo "subsystem = 'ios'"
    echo "cpu_family = 'aarch64'"
    echo "cpu = 'aarch64'"
    echo "endian = 'little'"
    echo "[properties]"
    echo "needs_exe_wrapper = true"
} > "$CROSS"

cd "$BUILD"
if [ "${REBUILD:-}" != "1" ] || [ ! -f build.ninja ]; then
    CFLAGS="$TARGET_FLAGS $INC_FLAGS" \
    CXXFLAGS="$TARGET_FLAGS $INC_FLAGS" \
    OBJCFLAGS="$TARGET_FLAGS $INC_FLAGS" \
    LDFLAGS="$TARGET_FLAGS $LIB_FLAGS" \
    ../configure \
        --cross-prefix="" \
        --cc="$CLANG" --cxx="$CLANGXX" --objcc="$CLANG" \
        --extra-cflags="$TARGET_FLAGS $INC_FLAGS" \
        --extra-ldflags="$TARGET_FLAGS $LIB_FLAGS" \
        --cpu=aarch64 \
        --target-list=aarch64-softmmu \
        --enable-shared-lib \
        --enable-ucontext --with-coroutine=libucontext \
        --disable-hvf --disable-pvg \
        --disable-cocoa --disable-sdl --disable-gtk --disable-coreaudio \
        --disable-curses --disable-libssh --disable-virtfs \
        --disable-gnutls --disable-gcrypt --enable-nettle \
        --enable-lzfse --enable-slirp --disable-slirp-smbd \
        --enable-spice --disable-opengl \
        --disable-tools --disable-guest-agent \
        --disable-werror --disable-qom-cast-debug --disable-debug-info \
        2>&1 | tee configure-ios.log
    [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "CONFIGURE FAILED - see $BUILD/configure-ios.log"; exit 1; }
fi

ninja -j"$(sysctl -n hw.ncpu)" libqemu-aarch64-softmmu.dylib 2>&1 | tee ninja-ios.log | grep -E "FAILED|error:|^\[[0-9]+/[0-9]+\] Linking" || true

LIB="$BUILD/libqemu-aarch64-softmmu.dylib"
[ -f "$LIB" ] || { echo "BUILD FAILED - see $BUILD/ninja-ios.log"; exit 1; }
echo "== built $LIB"
lipo -info "$LIB"
otool -l "$LIB" | grep -A4 LC_BUILD_VERSION | grep -E "platform|minos"
nm -gU "$LIB" | grep -E " _qemu_(init|main_loop|cleanup)$"

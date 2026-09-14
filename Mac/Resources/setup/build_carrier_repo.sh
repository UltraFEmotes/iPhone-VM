#!/bin/bash
# Builds the companion-served carrier repo and the guest iOS helper tools.
set -euo pipefail

RES="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-${INFERNO_DATA:-$HOME/Library/Application Support/InfernoMac/InfernoData}/carrier}"
BUILD="$OUT/build"
REPO="$OUT/repo"
ENTS="$RES/carrier_ents.plist"

mkdir -p "$OUT" "$BUILD" "$REPO"
install -m 755 "$RES/serve.sh" "$OUT/serve.sh"
install -m 644 "$RES/carrier-files/broker.py" "$OUT/broker.py"
install -m 755 "$RES/carrier-files/carrier-msg" "$OUT/carrier-msg"

sign_ios() {
    local path="$1"
    codesign -f -s - --entitlements "$ENTS" "$path" >/dev/null
}

build_sqlite() {
    if [ -x "$OUT/carrier-sqlite3" ]; then
        sign_ios "$OUT/carrier-sqlite3" || true
        return 0
    fi
    (
        cd "$BUILD"
        curl -sf -A 'Debian APT-HTTP/1.3 (1.8.2)' -o sqlite3.deb \
            https://apt.bingner.com/debs/1443.00/sqlite3_3.24.0-1_iphoneos-arm.deb
        rm -rf sqlite3-root
        mkdir sqlite3-root
        (cd sqlite3-root && ar x ../sqlite3.deb && tar xf data.tar.*)
    )
    install -m 755 "$BUILD/sqlite3-root/usr/bin/sqlite3" "$OUT/carrier-sqlite3"
    sign_ios "$OUT/carrier-sqlite3"
}

build_guest_tool() {
    local src="$1" out="$2"
    local sdk clang
    sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
    clang="$(xcrun --sdk iphoneos --find clang)"
    "$clang" -arch arm64 -isysroot "$sdk" -miphoneos-version-min=14.0 -fobjc-arc \
        "$src" -o "$out" -framework Foundation -framework UIKit
    sign_ios "$out"
}

build_sqlite
build_guest_tool "$RES/carrier-src/carrier-agentd.m" "$OUT/carrier-agentd"
build_guest_tool "$RES/carrier-src/carrier-clip.m" "$OUT/carrier-clip"

PKG="$BUILD/pkg"
rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" \
         "$PKG/var/mobile/Library/InfernoCarrier/bin" \
         "$PKG/usr/local/bin" \
         "$PKG/Library/LaunchDaemons"

install -m 755 "$OUT/carrier-sqlite3" "$PKG/var/mobile/Library/InfernoCarrier/bin/carrier-sqlite3"
install -m 755 "$OUT/carrier-msg" "$PKG/var/mobile/Library/InfernoCarrier/bin/carrier-msg"
install -m 755 "$OUT/carrier-agentd" "$PKG/var/mobile/Library/InfernoCarrier/bin/carrier-agentd"
install -m 755 "$OUT/carrier-clip" "$PKG/var/mobile/Library/InfernoCarrier/bin/carrier-clip"
ln -sf /var/mobile/Library/InfernoCarrier/bin/carrier-sqlite3 "$PKG/usr/local/bin/carrier-sqlite3"
ln -sf /var/mobile/Library/InfernoCarrier/bin/carrier-msg "$PKG/usr/local/bin/carrier-msg"
ln -sf /var/mobile/Library/InfernoCarrier/bin/carrier-agentd "$PKG/usr/local/bin/carrier-agentd"
ln -sf /var/mobile/Library/InfernoCarrier/bin/carrier-clip "$PKG/usr/local/bin/carrier-clip"

cat > "$PKG/Library/LaunchDaemons/com.infernophone.carrier-agentd.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.infernophone.carrier-agentd</string>
    <key>ProgramArguments</key>
    <array>
        <string>/var/mobile/Library/InfernoCarrier/bin/carrier-agentd</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/carrier-agentd.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/carrier-agentd.err</string>
</dict>
</plist>
PLIST

cat > "$PKG/DEBIAN/control" <<'CONTROL'
Package: carrier-sqlite3
Name: Inferno Carrier Helper
Version: 2.0
Architecture: iphoneos-arm
Maintainer: InfernoPhone
Description: SMS database, carrier broker and clipboard helpers for InfernoMac.
CONTROL

cat > "$PKG/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
mkdir -p /var/mobile/Library/InfernoCarrier/bin
chown -R mobile:mobile /var/mobile/Library/InfernoCarrier 2>/dev/null || true
chmod 755 /var/mobile/Library/InfernoCarrier /var/mobile/Library/InfernoCarrier/bin 2>/dev/null || true
if [ -x /bin/launchctl ]; then
    /bin/launchctl unload /Library/LaunchDaemons/com.infernophone.carrier-agentd.plist >/dev/null 2>&1 || true
    /bin/launchctl load -w /Library/LaunchDaemons/com.infernophone.carrier-agentd.plist >/dev/null 2>&1 || true
fi
exit 0
POSTINST
chmod 755 "$PKG/DEBIAN/postinst"

TMP="$BUILD/deb"
rm -rf "$TMP"
mkdir -p "$TMP/control" "$TMP/data"
cp "$PKG/DEBIAN/control" "$PKG/DEBIAN/postinst" "$TMP/control/"
rsync -a --exclude DEBIAN "$PKG/" "$TMP/data/"
printf "2.0\n" > "$TMP/debian-binary"
COPYFILE_DISABLE=1 tar --format ustar -C "$TMP/control" -czf "$TMP/control.tar.gz" .
COPYFILE_DISABLE=1 tar --format ustar -C "$TMP/data" -czf "$TMP/data.tar.gz" .
rm -f "$REPO/carrier-sqlite3.deb"
(cd "$TMP" && ar -qS "$REPO/carrier-sqlite3.deb" debian-binary control.tar.gz data.tar.gz)

size="$(stat -f%z "$REPO/carrier-sqlite3.deb")"
md5sum="$(md5 -q "$REPO/carrier-sqlite3.deb")"
sha256="$(shasum -a 256 "$REPO/carrier-sqlite3.deb" | awk '{print $1}')"
cat > "$REPO/Packages" <<EOF
Package: carrier-sqlite3
Name: Inferno Carrier Helper
Version: 2.0
Architecture: iphoneos-arm
Maintainer: InfernoPhone
Filename: ./carrier-sqlite3.deb
Size: $size
MD5sum: $md5sum
SHA256: $sha256
Description: SMS database, carrier broker and clipboard helpers for InfernoMac.

EOF
gzip -c "$REPO/Packages" > "$REPO/Packages.gz"

echo "carrier repo ready at $OUT"

#!/bin/bash
# One-time macOS setup for InfernoMac (Apple Silicon): builds ChefKiss Inferno following its guide, creates the
# companion Debian VM, and collects the tools the app uses. Safe to re-run; finished parts are skipped.
# Lines the app reads: STEP:<name>, FAIL:<text>, DONE
# Usage: install_mac.sh [--all-engines]    (also build the emulators for iOS 15-18, about +1 hour)
set -euo pipefail
DATA="${INFERNO_DATA:-$HOME/Library/Application Support/InfernoMac/InfernoData}"
RES="$(cd "$(dirname "$0")" && pwd)"   # the app's Resources folder
ALL_ENGINES=0; [ "${1:-}" = "--all-engines" ] && ALL_ENGINES=1
step() { echo "STEP:$1"; }
fail() { echo "FAIL:$*"; exit 1; }

[ "$(uname -m)" = arm64 ] || fail "InfernoMac needs an Apple Silicon Mac"
BREW=$(command -v brew || true)
[ -z "$BREW" ] && [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
[ -n "$BREW" ] || fail "Homebrew is required: install it from https://brew.sh, then run setup again"
eval "$("$BREW" shellenv)"
xcode-select -p >/dev/null 2>&1 || fail "Apple's command line tools are required: run  xcode-select --install  and try again"
mkdir -p "$DATA"
cd "$DATA"

step packages
brew install libtool meson ninja pkgconf dtc glib gnutls jpeg-turbo libpng libslirp libssh libusb lzo ncurses \
    nettle pixman snappy vde zstd lzfse openssl@3 cmake python@3 xz

step inferno
[ -d Inferno ] || git clone https://github.com/ChefKissInc/Inferno
(cd Inferno && git submodule update --init)
# macOS 27's SDK has no ParavirtualizedGraphics, so VMAPPLE is off; the SEP version becomes a build flag.
grep -q '^CONFIG_VMAPPLE=n' Inferno/configs/devices/aarch64-softmmu/default.mak ||
    printf '\n# macOS 27 SDK removed ParavirtualizedGraphics APIs\nCONFIG_VMAPPLE=n\n' >> Inferno/configs/devices/aarch64-softmmu/default.mak
python3 - <<'EOF'
p = "Inferno/hw/arm/apple-silicon/sep.c"
s = open(p).read()
if "#ifndef SEP_USE_VERSION_OVERRIDE" not in s:
    old = "#define SEP_USE_VERSION_OVERRIDE 14\n"
    assert old in s, "sep.c changed upstream; the per-iOS engines can't be built"
    open(p, "w").write(s.replace(old, "#ifndef SEP_USE_VERSION_OVERRIDE\n" + old + "#endif\n", 1))
EOF
ENT="$DATA/Inferno/$(cd Inferno && find . -name entitlements.plist -not -path './roms/*' | head -1)"
[ -f "$ENT" ] || fail "hypervisor entitlements.plist not found in the Inferno source"
PREFIX="$(brew --prefix)"

# build_engine <dir> <extra cflags>: configure + build one emulator, then sign it for Hypervisor.framework.
build_engine() {
    mkdir -p "Inferno/$1"
    (
        cd "Inferno/$1"
        [ -f build.ninja ] || LIBTOOL=glibtool ../configure --target-list=aarch64-softmmu,x86_64-softmmu \
            --disable-guest-agent --enable-lzfse --enable-slirp --enable-curses --enable-libssh --enable-virtfs \
            --enable-zstd --extra-cflags="-DNCURSES_WIDECHAR=1 $2 -I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib" \
            --disable-sdl --disable-gtk --enable-cocoa --enable-nettle --enable-gnutls --disable-pvg \
            --disable-werror --disable-qom-cast-debug --disable-debug-info >configure.log 2>&1 \
            || { tail -20 configure.log; exit 1; }
        ninja >ninja.log 2>&1 || { grep -m5 -A5 -E 'FAILED|error:' ninja.log; exit 1; }
        for t in aarch64 x86_64; do
            [ -f "qemu-system-$t-unsigned" ] && cp "qemu-system-$t-unsigned" "qemu-system-$t"
            codesign --force --sign - --entitlements "$ENT" "qemu-system-$t"
        done
    ) || fail "building Inferno ($1) failed"
}
build_engine build ""
if [ $ALL_ENGINES = 1 ]; then
    for N in 15 16 17 18; do
        step "inferno-ios$N"
        build_engine "build-sep$N" "-DSEP_USE_VERSION_OVERRIDE=$N"
    done
fi

step tools
[ -d img4lib ] || git clone --depth 1 https://github.com/xerub/img4lib
(
    cd img4lib
    [ -x img4 ] && exit 0
    INC="-I$(brew --prefix openssl@3)/include -I$(brew --prefix lzfse)/include"
    CF="$INC"' -Wall -W -pedantic -Wno-variadic-macros -Wno-multichar -Wno-four-char-constants -Wno-unused-parameter -O2 -I. -g -DiOS10 -DDER_MULTIBYTE_TAGS=1 -DDER_TAG_SIZE=8 -D__unused="__attribute__((unused))"'
    make CFLAGS="$CF" LDFLAGS="-L$(brew --prefix openssl@3)/lib -L$(brew --prefix lzfse)/lib" >/dev/null
) || fail "img4lib did not build"
[ -x venv/bin/python ] || python3 -m venv venv
venv/bin/pip install -q pyasn1 pyasn1-modules
cp "$RES/tools/create_apticket.py" "$RES/tools/create_septicket.py" "$RES/tools/ticket.shsh2" \
   "$RES/tools/idevicerestore.patch" "$DATA/"
if [ ! -x InfernoFSPatcher/build/inferno_fs_patcher ]; then
    rm -rf InfernoFSPatcher
    git clone --depth 1 https://git.chefkiss.dev/AppleHax/InfernoFSPatcher
    (cd InfernoFSPatcher && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null && cmake --build build >/dev/null) \
        || fail "InfernoFSPatcher did not build"
fi

step companion-image
rm -rf companion-files && cp -R "$RES/companion-files" companion-files
# UEFI firmware for the companion, straight from the Inferno (QEMU) source tree.
[ -f edk2-aarch64-code.fd ] || bunzip2 -kc Inferno/pc-bios/edk2-aarch64-code.fd.bz2 > edk2-aarch64-code.fd
[ -f companion_key ] || ssh-keygen -t ed25519 -N "" -f companion_key -q
if [ ! -f companion.qcow2 ]; then
    curl -L -f -o companion-download.qcow2 \
        https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2
    mv companion-download.qcow2 companion.qcow2
    Inferno/build/qemu-img resize companion.qcow2 24G >/dev/null
fi
mkdir -p seed
cat > seed/user-data <<EOF
#cloud-config
users:
  - name: inferno
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat companion_key.pub)
ssh_pwauth: false
EOF
printf 'instance-id: companion\nlocal-hostname: companion\n' > seed/meta-data
rm -f seed.iso && hdiutil makehybrid -quiet -o seed.iso seed -iso -joliet -default-volume-name cidata
cat > start_companion.sh <<'EOF'
#!/bin/bash
# Companion VM (arm64 Debian, hvf). Must be started before the iPhone VM.
# This folder is shared read-only into the guest as 9p tag "host" (mounted at /mnt/host).
cd "$(dirname "$0")"
exec ./Inferno/build/qemu-system-aarch64 -M virt -accel hvf -cpu host -m 2G -smp 4 \
  -bios ./edk2-aarch64-code.fd \
  -usb -device usb-ehci,id=ehci -device usb-tcp-remote,bus=ehci.0 \
  -drive file=companion.qcow2,if=virtio,discard=unmap,detect-zeroes=unmap -drive file=seed.iso,if=virtio,media=cdrom \
  -virtfs local,path="$PWD",mount_tag=host,security_model=none,readonly=on \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:32222-:22 \
  -display none -serial file:companion.log -daemonize -pidfile companion.pid
EOF
chmod +x start_companion.sh

step companion-boot
CSSH=(ssh -i "$DATA/companion_key" -p 32222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o LogLevel=ERROR -o ConnectTimeout=8 inferno@localhost)
if ! "${CSSH[@]}" true 2>/dev/null; then
    ./start_companion.sh
    for _ in $(seq 100); do "${CSSH[@]}" true 2>/dev/null && break; sleep 3; done
fi
"${CSSH[@]}" true 2>/dev/null || fail "the companion VM did not come up (see $DATA/companion.log)"

step companion-provision
if ! "${CSSH[@]}" 'test -f /var/lib/inferno-provisioned'; then
    # macOS patches the iPhone disk itself, so the companion skips the Linux APFS driver.
    "${CSSH[@]}" 'INFERNO_SKIP_APFS=1 bash -s' < "$RES/companion-files/companion_provision.sh" | tail -30
    "${CSSH[@]}" 'test -f /var/lib/inferno-provisioned' || fail "companion provisioning did not finish"
fi

step carrier-helper
mkdir -p carrier
cp "$RES/serve.sh" carrier/serve.sh
if [ ! -x carrier/carrier-sqlite3 ]; then
    # sqlite3 for iOS, re-signed with the Messages storage entitlement (see the Set Up Carrier button).
    if (mkdir -p carrier/build && cd carrier/build &&
        curl -sf -A 'Debian APT-HTTP/1.3 (1.8.2)' -o sqlite3.deb \
            https://apt.bingner.com/debs/1443.00/sqlite3_3.24.0-1_iphoneos-arm.deb &&
        ar x sqlite3.deb && tar xf data.tar.*) &&
       cp carrier/build/usr/bin/sqlite3 carrier/carrier-sqlite3 &&
       codesign -f -s - --entitlements "$RES/carrier_ents.plist" carrier/carrier-sqlite3; then
        echo "carrier helper ready"
    else
        echo "carrier helper skipped (optional; only needed for the simulated carrier)"
    fi
fi

echo DONE

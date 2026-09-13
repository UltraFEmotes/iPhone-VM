#!/bin/bash
# One-time setup inside WSL2 (Ubuntu): build Inferno and its tools, then create the companion VM.
# Follows the Inferno guide's Debian/Linux instructions. Safe to re-run; finished parts are skipped.
set -euo pipefail
source "$(dirname "$0")/common.sh"
mkdir -p "$DATA" "$DATA/VMs" "$DATA/ipsw-cache"
cd "$DATA"

step packages
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential libtool meson ninja-build pkg-config device-tree-compiler libglib2.0-dev gnutls-bin \
    libjpeg-turbo8-dev libpng-dev libslirp-dev libssh-dev libusb-1.0-0-dev liblzo2-dev libncurses-dev \
    libpixman-1-dev libsnappy-dev vde2 zstd libzstd-dev libgnutls28-dev libgmp-dev lzfse liblzfse-dev \
    libgtk-3-dev libsdl2-dev git cmake python3 python3-venv curl wget unzip libssl-dev \
    cloud-image-utils openssh-client xz-utils

step nettle
nettle_ok() {
    local v; v=$(pkg-config --modversion nettle 2>/dev/null || echo 0)
    [ "$(printf '%s\n3.10\n' "$v" | sort -V | head -1)" = "3.10" ]
}
if ! nettle_ok; then
    echo "system nettle is older than 3.10 — building 3.10.2 (per the guide)"
    wget -q -O nettle-3.10.2.tar.gz https://ftpmirror.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz
    echo "fe9ff51cb1f2abb5e65a6b8c10a92da0ab5ab6eaf26e7fc2b675c45f1fb519b5  nettle-3.10.2.tar.gz" | sha256sum -c - \
        || fail "nettle download failed its checksum — not building it"
    tar -xf nettle-3.10.2.tar.gz
    (cd nettle-3.10.2 && ./configure >/dev/null && make -j"$(nproc)" >/dev/null && sudo make install >/dev/null)
    echo -e "/usr/local/lib64\n/usr/local/lib" | sudo tee /etc/ld.so.conf.d/usr-local.conf >/dev/null
    sudo ldconfig
    rm -rf nettle-3.10.2 nettle-3.10.2.tar.gz
fi

step inferno
[ -d Inferno ] || git clone https://github.com/ChefKissInc/Inferno
(cd Inferno && git submodule update --init)
mkdir -p Inferno/build
(
    cd Inferno/build
    [ -f build.ninja ] || ../configure --target-list=aarch64-softmmu,x86_64-softmmu \
        --enable-lzfse --enable-slirp --enable-curses --enable-libssh --enable-virtfs --enable-zstd \
        --enable-nettle --enable-gnutls --enable-gtk --enable-sdl \
        --disable-werror --disable-qom-cast-debug --disable-debug-info
    ninja
)
[ -x "$QEMU_ARM" ] && [ -x "$QEMU_X86" ] || fail "Inferno build did not produce the emulators"

# Optional: one emulator per Secure Enclave version, for the experimental iOS 15-18 entries.
if [ "${1:-}" = "--all-engines" ]; then
    python3 - <<'EOF'
p = "Inferno/hw/arm/apple-silicon/sep.c"
s = open(p).read()
if "#ifndef SEP_USE_VERSION_OVERRIDE" not in s:
    old = "#define SEP_USE_VERSION_OVERRIDE 14\n"
    assert old in s, "sep.c changed upstream; the per-iOS engines can't be built"
    open(p, "w").write(s.replace(old, "#ifndef SEP_USE_VERSION_OVERRIDE\n" + old + "#endif\n", 1))
EOF
    for N in 15 16 17 18; do
        step "inferno-ios$N"
        mkdir -p "Inferno/build-sep$N"
        (
            cd "Inferno/build-sep$N"
            [ -f build.ninja ] || ../configure --target-list=aarch64-softmmu,x86_64-softmmu \
                --enable-lzfse --enable-slirp --enable-curses --enable-libssh --enable-virtfs --enable-zstd \
                --enable-nettle --enable-gnutls --enable-gtk --enable-sdl --extra-cflags="-DSEP_USE_VERSION_OVERRIDE=$N" \
                --disable-werror --disable-qom-cast-debug --disable-debug-info
            ninja
        ) || fail "building the iOS $N emulator failed"
    done
fi

step tools
[ -d img4lib ] || git clone --depth 1 https://github.com/xerub/img4lib
(cd img4lib && make -j"$(nproc)" >/dev/null) || fail "img4lib did not build"
[ -x venv/bin/python ] || python3 -m venv venv
venv/bin/pip install -q pyasn1 pyasn1-modules
cp "$SCRIPTS/tools/create_apticket.py" "$SCRIPTS/tools/create_septicket.py" "$SCRIPTS/tools/ticket.shsh2" \
   "$SCRIPTS/tools/idevicerestore.patch" "$DATA/"
rm -rf "$DATA/companion-files" && cp -r "$SCRIPTS/companion-files" "$DATA/companion-files"

step companion-image
[ -f companion_key ] || ssh-keygen -t ed25519 -N "" -f companion_key -q
if [ ! -f companion.qcow2 ]; then
    # Full-kernel Debian image (9p driver + headers for the APFS module), matching the host's CPU.
    ARCH=amd64; [ "$(uname -m)" = aarch64 ] && ARCH=arm64
    curl -L -f -o companion-download.qcow2 \
        "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-$ARCH.qcow2"
    mv companion-download.qcow2 companion.qcow2
    "$QEMU_IMG" resize companion.qcow2 20G >/dev/null
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
mounts:
  - [host, /mnt/host, 9p, "trans=virtio,version=9p2000.L,msize=512000,nofail", "0", "0"]
EOF
printf 'instance-id: companion\nlocal-hostname: companion\n' > seed/meta-data
cloud-localds seed.iso seed/user-data seed/meta-data

step companion-boot
"$SCRIPTS/companion.sh" start

step companion-provision
if ! "${CSSH[@]}" 'test -f /var/lib/inferno-provisioned'; then
    "${CSSH[@]}" 'bash -s' < "$SCRIPTS/companion-files/companion_provision.sh" | tail -40
    "${CSSH[@]}" 'test -f /var/lib/inferno-provisioned' || fail "companion provisioning did not finish"
    # The provision installs a kernel module (APFS) and USB rules; reboot to load everything cleanly.
    "$SCRIPTS/companion.sh" stop
    "$SCRIPTS/companion.sh" start
fi

echo DONE

#!/bin/bash
# One-time setup on a Linux host or inside WSL2: build Inferno and its tools, then create the companion VM.
# Follows the Inferno guide's Linux instructions on Arch and on Debian/Ubuntu. Safe to re-run; finished
# parts are skipped.
set -euo pipefail
source "$(dirname "$0")/common.sh"
mkdir -p "$DATA" "$DATA/VMs" "$DATA/ipsw-cache"
cd "$DATA"

step packages
# The Inferno guide's build dependencies, under each distro's own names.
# libattr is not optional: --enable-virtfs needs it for the 9p share the companion VM mounts.
# lzfse is missing from several distros; the step below builds it from source when it is.
PKG_KIND=$(pkg_kind)

pkg_cmd() {  # install packages without prompting
    case "$PKG_KIND" in
        apt)    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        # No -Sy: syncing without a full upgrade is how Arch installs break.
        pacman) sudo pacman -S --needed --noconfirm "$@" ;;
        dnf)    sudo dnf install -y "$@" ;;
        zypper) sudo zypper --non-interactive install --no-recommends "$@" ;;
        apk)    sudo apk add "$@" ;;
        emerge) sudo emerge --quiet --noreplace "$@" ;;
        xbps)   sudo xbps-install -Sy "$@" ;;
        *)      return 1 ;;
    esac
}

# Install what this distro has and name the rest instead of stopping: package names drift between
# releases, and a missing one is usually either already present or something the build will complain
# about far more clearly than a failed transaction would.
pkg_install() {
    pkg_cmd "$@" && return 0
    echo "the package list was rejected as a whole; trying one at a time"
    local p missing=()
    for p in "$@"; do pkg_cmd "$p" >/dev/null 2>&1 || missing+=("$p"); done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "note: not available under these names here, skipped: ${missing[*]}"
        echo "      if the Inferno build below fails, install the equivalents by hand and re-run"
    fi
}

case "$PKG_KIND" in
apt)
    sudo apt-get update
    pkg_install build-essential libtool meson ninja-build pkg-config device-tree-compiler libglib2.0-dev \
        gnutls-bin libjpeg-turbo8-dev libpng-dev libslirp-dev libssh-dev libusb-1.0-0-dev liblzo2-dev \
        libncurses-dev libpixman-1-dev libsnappy-dev vde2 zstd libzstd-dev libgnutls28-dev libgmp-dev \
        lzfse liblzfse-dev libgtk-3-dev libsdl2-dev git cmake python3 python3-venv curl wget unzip \
        libssl-dev libattr1-dev cloud-image-utils xorriso openssh-client xz-utils
    ;;
pacman)
    # Arch ships headers in the library packages themselves (glib2 is the exception), SDL 2 as
    # sdl2-compat, and venv inside python. It has no lzfse at all.
    pkg_install base-devel meson ninja dtc glib2 glib2-devel gnutls libjpeg-turbo libpng libslirp libssh \
        libusb lzo ncurses pixman snappy vde2 zstd gmp gtk3 sdl2-compat git cmake python curl wget unzip \
        openssl attr libcap-ng cloud-image-utils libisoburn openssh xz
    ;;
dnf)
    # Fedora, RHEL and the rebuilds (Rocky, Alma). RHEL has no lzfse-devel; Fedora does.
    pkg_install gcc gcc-c++ make libtool pkgconf-pkg-config meson ninja-build dtc glib2-devel \
        gnutls-devel libjpeg-turbo-devel libpng-devel libslirp-devel libssh-devel libusb1-devel \
        lzo-devel ncurses-devel pixman-devel snappy-devel vde2-devel libzstd-devel zstd gmp-devel \
        lzfse-devel gtk3-devel SDL2-devel git cmake python3 curl wget unzip openssl-devel \
        libattr-devel libcap-ng-devel cloud-utils xorriso openssh-clients xz
    ;;
zypper)
    sudo zypper --non-interactive refresh || true
    pkg_install gcc make libtool pkg-config meson ninja dtc glib2-devel libgnutls-devel libjpeg8-devel \
        libpng16-devel libslirp-devel libssh-devel libusb-1_0-devel lzo-devel ncurses-devel \
        libpixman-1-0-devel snappy-devel libvdeplug-devel libzstd-devel zstd gmp-devel lzfse-devel \
        gtk3-devel libSDL2-devel git cmake python3 curl wget unzip libopenssl-devel libattr-devel \
        libcap-ng-devel cloud-utils xorriso openssh-clients xz
    ;;
apk)
    # Alpine is musl, and its busybox tools lack the GNU options these scripts use (tail --pid,
    # df --output, du -B1, sed -u), so the GNU ones are pulled in as well.
    pkg_install build-base libtool pkgconf meson ninja dtc dtc-dev glib-dev gnutls-dev \
        libjpeg-turbo-dev libpng-dev libslirp-dev libssh-dev libusb-dev lzo-dev ncurses-dev pixman-dev \
        snappy-dev vde2-dev libzstd zstd-dev gmp-dev gtk+3.0-dev sdl2-dev git cmake python3 curl wget \
        unzip openssl-dev attr-dev libcap-ng-dev openssh-client xorriso xz linux-headers \
        bash coreutils grep sed findutils procps-ng
    ;;
emerge)
    # Gentoo builds from source, so --noreplace leaves anything already installed alone.
    pkg_install dev-build/meson dev-build/ninja sys-apps/dtc dev-libs/glib net-libs/gnutls \
        media-libs/libjpeg-turbo media-libs/libpng net-libs/libslirp net-libs/libssh dev-libs/libusb \
        dev-libs/lzo sys-libs/ncurses x11-libs/pixman app-arch/snappy net-misc/vde app-arch/zstd \
        dev-libs/gmp x11-libs/gtk+ media-libs/libsdl2 dev-vcs/git dev-build/cmake dev-lang/python \
        net-misc/curl net-misc/wget app-arch/unzip dev-libs/openssl sys-apps/attr sys-libs/libcap-ng \
        net-misc/openssh dev-libs/libisoburn app-arch/xz-utils
    ;;
xbps)
    pkg_install base-devel meson ninja dtc glib-devel gnutls-devel libjpeg-turbo-devel libpng-devel \
        libslirp-devel libssh-devel libusb-devel lzo-devel ncurses-devel pixman-devel snappy-devel \
        vde2-devel libzstd-devel gmp-devel gtk+3-devel SDL2-devel git cmake python3 curl wget unzip \
        openssl-devel attr-devel libcap-ng-devel openssh libisoburn xz
    ;;
*)
    fail "no package manager found (tried apt, pacman, dnf, zypper, apk, emerge, xbps). Install the
packages from the Inferno guide by hand, then re-run: a C toolchain, meson, ninja, cmake, git, python3,
curl, and the development files for glib2, gnutls, gmp, gtk3, SDL2, libjpeg-turbo, libpng, libslirp,
libssh, libusb, lzo, ncurses, pixman, snappy, zstd, openssl, attr and libcap-ng."
    ;;
esac

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

step lzfse
# Inferno needs lzfse to read Apple's disk images. Debian packages it; Arch doesn't, so build the same
# source the AUR package uses. Static and position-independent, so the emulator links it straight in and
# needs no extra library path at run time.
lzfse_ok() {
    printf '#include <lzfse.h>\nint main(void) { lzfse_decode_scratch_size(); return 0; }\n' |
        cc -x c - -llzfse -o /dev/null 2>/dev/null
}
if ! lzfse_ok; then
    rm -rf lzfse-src
    git clone --depth 1 https://github.com/lzfse/lzfse lzfse-src
    # lzfse still asks for cmake 2.8.6, which CMake 4 (Arch) refuses without this policy floor.
    cmake -S lzfse-src -B lzfse-src/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON >/dev/null
    cmake --build lzfse-src/build -j"$(nproc)" >/dev/null
    sudo cmake --install lzfse-src/build >/dev/null
    rm -rf lzfse-src
    lzfse_ok || fail "lzfse did not build — Inferno can't read the iOS images without it"
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
rm -f seed.iso
if command -v cloud-localds >/dev/null; then
    cloud-localds seed.iso seed/user-data seed/meta-data
elif command -v xorriso >/dev/null; then
    xorriso -as mkisofs -quiet -o seed.iso -V cidata -J -r seed/user-data seed/meta-data
elif command -v mkisofs >/dev/null; then
    mkisofs -quiet -o seed.iso -V cidata -J -r seed/user-data seed/meta-data
else
    fail "no tool to build the cloud-init seed ISO (install cloud-image-utils)"
fi

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

#!/bin/bash
# Runs inside the companion VM (piped over ssh by install.sh):
#  - libimobiledevice stack from source (per the Inferno guide), idevicerestore with the model patch
#  - reverse tethering for the iPhone VM (udev + dnsmasq + NAT)
#  - the Linux APFS driver and InfernoFSPatcher, for filesystem patching
set -e
sudo mkdir -p /mnt/host
mountpoint -q /mnt/host || sudo mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 host /mnt/host
F=/mnt/host/companion-files

pkg_available() { apt-cache show "$1" >/dev/null 2>&1; }
apt_install() { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }
apt_install_one_of() {
    local pkg
    for pkg in "$@"; do
        if pkg_available "$pkg"; then
            apt_install "$pkg"
            return 0
        fi
    done
    echo "none of these packages is available: $*" >&2
    exit 1
}

sudo apt-get update
apt_install build-essential git autoconf automake libtool pkg-config \
    libssl-dev libusb-1.0-0-dev libcurl4-openssl-dev libreadline-dev libzip-dev zlib1g-dev python3-dev cython3 udev \
    dnsmasq iptables cmake python3 xz-utils
# Windows patches the iPhone disk inside the companion with the Linux APFS driver; macOS does it natively
# (InfernoMac passes INFERNO_SKIP_APFS=1). Headers match the companion's own architecture.
if [ "${INFERNO_SKIP_APFS:-0}" != 1 ]; then
    apt_install dkms
    apt_install_one_of "linux-headers-$(uname -r)" "linux-headers-$(dpkg --print-architecture)"
    apt_install apfs-dkms
fi

export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig/
mkdir -p ~/src && cd ~/src
for p in libplist libimobiledevice-glue libusbmuxd libtatsu libimobiledevice libirecovery usbmuxd idevicerestore; do
    [ -d $p ] || git clone --depth 1 https://github.com/libimobiledevice/$p
    cd $p
    if [ $p = idevicerestore ]; then git apply /mnt/host/idevicerestore.patch || true; fi
    ./autogen.sh --without-cython >/dev/null && make -j"$(nproc)" >/dev/null && sudo make install >/dev/null
    sudo ldconfig
    cd ..
    echo "built $p"
done
getent passwd usbmux >/dev/null || {
    echo 'u usbmux 140 "usbmux user"' | sudo tee /usr/lib/sysusers.d/usbmuxd.conf >/dev/null
    sudo systemd-sysusers
}

# InfernoFSPatcher (dyld shared cache patch). It builds with -Werror; retry without it if GCC warns.
if [ "${INFERNO_SKIP_APFS:-0}" != 1 ] && [ ! -x /opt/InfernoFSPatcher/build/inferno_fs_patcher ]; then
    sudo rm -rf /opt/InfernoFSPatcher
    sudo git clone --depth 1 https://git.chefkiss.dev/AppleHax/InfernoFSPatcher /opt/InfernoFSPatcher
    cd /opt/InfernoFSPatcher
    if ! sudo cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null || ! sudo cmake --build build >/dev/null; then
        sudo sed -i 's/ -Werror//' CMakeLists.txt
        sudo rm -rf build
        sudo cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null && sudo cmake --build build >/dev/null
    fi
    cd ~
fi

# Reverse tethering (iPhone VM internet over emulated USB).
sudo install -m 644 $F/90-iphone-tether.rules /etc/udev/rules.d/90-iphone-tether.rules
sudo install -m 755 $F/iphone-tether.sh /usr/local/sbin/iphone-tether.sh
sudo install -m 644 $F/iphone-tether.service /etc/systemd/system/iphone-tether.service
sudo install -m 644 $F/iphone.conf /etc/dnsmasq.d/iphone.conf
sudo install -D -m 644 $F/ncm.conf /etc/systemd/system/usbmuxd.service.d/ncm.conf
echo -e "net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1" | sudo tee /etc/sysctl.d/99-iphone-forward.conf >/dev/null
sudo sysctl --system >/dev/null
sudo udevadm control --reload-rules
sudo systemctl daemon-reload
sudo systemctl enable dnsmasq >/dev/null 2>&1 || true
sudo systemctl restart usbmuxd || true

sudo touch /var/lib/inferno-provisioned
echo PROVISION_DONE

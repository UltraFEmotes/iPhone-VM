#!/bin/bash
# One-time setup inside WSL2 (Ubuntu): build Inferno and its tools, then create the companion VM.
# Follows the Inferno guide's Debian/Linux instructions. Safe to re-run; finished parts are skipped.
set -euo pipefail
source "$(dirname "$0")/common.sh"
mkdir -p "$DATA" "$DATA/VMs" "$DATA/ipsw-cache"
cd "$DATA"

step packages
sudo apt-get update
apt_install \
    build-essential libtool meson ninja-build pkg-config device-tree-compiler libglib2.0-dev gnutls-bin \
    libpng-dev libslirp-dev libssh-dev libusb-1.0-0-dev liblzo2-dev libncurses-dev \
    libpixman-1-dev libsnappy-dev vde2 zstd libzstd-dev libgnutls28-dev libgmp-dev \
    libgtk-3-dev libsdl2-dev git cmake python3 python3-venv curl wget unzip libssl-dev \
    cloud-image-utils openssh-client xz-utils
apt_install_one_of libjpeg-turbo8-dev libjpeg62-turbo-dev
if pkg_available liblzfse-dev; then
    apt_install liblzfse-dev
elif pkg_available lzfse-dev; then
    apt_install lzfse-dev
fi
pkg_available lzfse && apt_install lzfse || true
LZFSE_FLAG=--disable-lzfse
pkg-config --exists lzfse 2>/dev/null && LZFSE_FLAG=--enable-lzfse

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
python3 - <<'EOF'
from pathlib import Path

def patch_once(path, old, new, marker, reason):
    p = Path(path)
    s = p.read_text()
    if marker in s:
        return
    if old not in s:
        raise SystemExit(f"{path} changed upstream; cannot patch {reason}")
    p.write_text(s.replace(old, new, 1))

patch_once(
    "Inferno/hw/arm/apple-silicon/sep.c",
    "#define SEP_USE_VERSION_OVERRIDE 14\n",
    "#ifndef SEP_USE_VERSION_OVERRIDE\n#define SEP_USE_VERSION_OVERRIDE 14\n#endif\n",
    "#ifndef SEP_USE_VERSION_OVERRIDE",
    "per-iOS SEP engine selection",
)
patch_once(
    "Inferno/hw/arm/apple-silicon/t8030.c",
    """    // sbd = apple_aop_audio_create(APPLE_AOP(aop));
    // assert_nonnull(sbd);
    // object_property_add_child(OBJECT(aop), \"aop-audio\", OBJECT(sbd));
    // sysbus_realize_and_unref(sbd, &error_fatal);
""",
    """    if (t8030->aop_audio) {
        sbd = apple_aop_audio_create(APPLE_AOP(aop));
        assert_nonnull(sbd);
        object_property_add_child(OBJECT(aop), \"aop-audio\", OBJECT(sbd));
        sysbus_realize_and_unref(sbd, &error_fatal);
    }
""",
    "t8030->aop_audio",
    "AOP audio creation",
)
patch_once(
    "Inferno/hw/arm/apple-silicon/t8030.c",
    "PROP_GETTER_SETTER(bool, force_dfu);\n",
    "PROP_GETTER_SETTER(bool, force_dfu);\nPROP_GETTER_SETTER(bool, aop_audio);\n",
    "PROP_GETTER_SETTER(bool, aop_audio);",
    "AOP audio getter/setter",
)
patch_once(
    "Inferno/hw/arm/apple-silicon/t8030.c",
    """    object_class_property_add_bool(klass, \"force-dfu\", t8030_get_force_dfu,
                                   t8030_set_force_dfu);
    object_class_property_set_description(klass, \"force-dfu\", \"Force DFU\");
""",
    """    object_class_property_add_bool(klass, \"force-dfu\", t8030_get_force_dfu,
                                   t8030_set_force_dfu);
    object_class_property_set_description(klass, \"force-dfu\", \"Force DFU\");
    object_class_property_add_bool(klass, \"aop-audio\", t8030_get_aop_audio,
                                   t8030_set_aop_audio);
    object_class_property_set_description(klass, \"aop-audio\",
                                          \"Enable experimental AOP audio\");
""",
    "object_class_property_add_bool(klass, \"aop-audio\"",
    "AOP audio machine property",
)
patch_once(
    "Inferno/include/hw/arm/apple-silicon/t8030.h",
    "    bool force_dfu;\n",
    "    bool force_dfu;\n    bool aop_audio;\n",
    "bool aop_audio;",
    "AOP audio state field",
)
patch_once(
    "Inferno/hw/audio/apple-silicon/aop-audio.c",
    """    'edtC', 'acmm', 'aphc', 'lpfw', 'leap', 'aphd', 'aph ',
    'ahdc', 'pcmM', 'lpai', 'mca0', 'mca1', 'apac',
""",
    """    'edtC', 'acmm', 'aphc', 'lpfw', 'leap', 'aphd', 'aph ',
    /*
     * Do not advertise lpai yet. This endpoint reports zero IO handlers, and
     * iOS 14 can spin waiting for an input buffer on the missing lpai handler.
     */
    'ahdc', 'pcmM', 'mca0', 'mca1', 'apac',
""",
    "Do not advertise lpai yet",
    "AOP speaker-only device list",
)
patch_once(
    "Inferno/hw/audio/apple-silicon/aop-audio.c",
    """    case COMMAND_GET_DEVICE_ID:
        AOP_DPRINTF(\"AOPAudio GetDeviceID %d\",
                    ldl_le_p(payload + COMMAND_HDR_LEN));

        stl_le_p(payload_out,
                 apple_aop_devices[ldl_le_p(payload + COMMAND_HDR_LEN)]);
        break;
""",
    """    case COMMAND_GET_DEVICE_ID: {
        uint32_t device_index = ldl_le_p(payload + COMMAND_HDR_LEN);

        AOP_DPRINTF(\"AOPAudio GetDeviceID %d\",
                    device_index);

        if (device_index >= ARRAY_SIZE(apple_aop_devices)) {
            return AOP_RESULT_ERROR;
        }
        stl_le_p(payload_out, apple_aop_devices[device_index]);
        break;
    }
""",
    "uint32_t device_index = ldl_le_p(payload + COMMAND_HDR_LEN);",
    "AOP device-id bounds check",
)
patch_once(
    "Inferno/include/hw/display/apple_displaypipe_v4.h",
    "SysBusDevice *adp_v4_from_node(AppleDTNode *node, MemoryRegion *dma_mr);\n",
    """SysBusDevice *adp_v4_from_node(AppleDTNode *node, MemoryRegion *dma_mr,
                               uint32_t width, uint32_t height);
""",
    "uint32_t width, uint32_t height);",
    "display-pipe dynamic timing signature",
)
patch_once(
    "Inferno/hw/display/apple_displaypipe_v4.c",
    """// FIXME: Unhardcode.
static const uint32_t adp_v4_timing_info[] = { 828, 144, 1, 1, 1792, 1, 1, 1 };

SysBusDevice *adp_v4_from_node(AppleDTNode *node, MemoryRegion *dma_mr)
""",
    """SysBusDevice *adp_v4_from_node(AppleDTNode *node, MemoryRegion *dma_mr,
                               uint32_t width, uint32_t height)
""",
    "SysBusDevice *adp_v4_from_node(AppleDTNode *node, MemoryRegion *dma_mr,\n                               uint32_t width, uint32_t height)",
    "display-pipe dynamic timing entrypoint",
)
patch_once(
    "Inferno/hw/display/apple_displaypipe_v4.c",
    "    uint64_t *reg;\n    int i;\n",
    "    uint64_t *reg;\n    uint32_t timing_info[] = { width, 144, 1, 1, height, 1, 1, 1 };\n    int i;\n",
    "uint32_t timing_info[] = { width, 144, 1, 1, height, 1, 1, 1 };",
    "display-pipe dynamic timing data",
)
patch_once(
    "Inferno/hw/display/apple_displaypipe_v4.c",
    """    apple_dt_set_prop(node, \"display-timing-info\", sizeof(adp_v4_timing_info),
                      adp_v4_timing_info);
""",
    """    apple_dt_set_prop(node, \"display-timing-info\", sizeof(timing_info),
                      timing_info);
""",
    "sizeof(timing_info)",
    "display-pipe dynamic timing property",
)
patch_once(
    "Inferno/hw/arm/apple-silicon/t8030.c",
    """    sbd = adp_v4_from_node(
        child, MEMORY_REGION(apple_dart_iommu_mr(dart, ldl_le_p(prop->data))));
""",
    """    sbd = adp_v4_from_node(
        child, MEMORY_REGION(apple_dart_iommu_mr(dart, ldl_le_p(prop->data))),
        t8030->disp_width, t8030->disp_height);
""",
    "t8030->disp_width, t8030->disp_height);",
    "t8030 display-pipe dynamic timing call",
)
EOF
mkdir -p Inferno/build
(
    cd Inferno/build
    [ -f build.ninja ] || ../configure --target-list=aarch64-softmmu,x86_64-softmmu \
        "$LZFSE_FLAG" --enable-slirp --enable-curses --enable-libssh --enable-virtfs --enable-zstd \
        --enable-nettle --enable-gnutls --enable-gtk --enable-sdl \
        --disable-werror --disable-qom-cast-debug --disable-debug-info
    ninja -j"$(nproc)"
)
[ -x "$QEMU_ARM" ] && [ -x "$QEMU_X86" ] || fail "Inferno build did not produce the emulators"

# Optional: one emulator per Secure Enclave version, for the experimental iOS 15-18 entries.
if [ "${1:-}" = "--all-engines" ]; then
    for N in 15 16 17 18; do
        step "inferno-ios$N"
        mkdir -p "Inferno/build-sep$N"
        (
            cd "Inferno/build-sep$N"
            [ -f build.ninja ] || ../configure --target-list=aarch64-softmmu,x86_64-softmmu \
                "$LZFSE_FLAG" --enable-slirp --enable-curses --enable-libssh --enable-virtfs --enable-zstd \
                --enable-nettle --enable-gnutls --enable-gtk --enable-sdl --extra-cflags="-DSEP_USE_VERSION_OVERRIDE=$N" \
                --disable-werror --disable-qom-cast-debug --disable-debug-info
            ninja -j"$(nproc)"
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

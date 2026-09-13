#!/bin/bash
# Companion VM (x86_64 Debian): owns the iPhone VM's USB link (usbmuxd, idevicerestore, reverse tethering)
# and does the APFS filesystem patching. Must be started before the iPhone VM.
# Usage: companion.sh start|stop|status
#   EXTRA_DRIVE=<raw disk> companion.sh start   — also attach an iPhone root disk (for patching)
set -uo pipefail
source "$(dirname "$0")/common.sh"
cd "$DATA"

running() { [ -f companion.pid ] && kill -0 "$(cat companion.pid)" 2>/dev/null; }
ssh_up() { "${CSSH[@]}" true 2>/dev/null; }

case "${1:-status}" in
start)
    if running; then
        for _ in $(seq 60); do ssh_up && { echo "companion already running"; exit 0; }; sleep 3; done
        fail "companion is running but not answering ssh"
    fi
    # The companion matches the host's CPU so KVM can accelerate it: x86_64 (q35) or arm64 (virt + UEFI).
    if [ "$(uname -m)" = aarch64 ]; then
        machine=("$QEMU_ARM" -M virt -bios "$ENGINE_DIR/pc-bios/edk2-aarch64-code.fd")
    else
        machine=("$QEMU_X86" -M q35)
    fi
    if [ -w /dev/kvm ]; then
        accel=(-accel kvm -cpu host)
    else
        accel=(-accel tcg -cpu max)
        echo "note: /dev/kvm isn't available — the companion runs without acceleration (slower)"
    fi
    extra=()
    # The iPhone disk uses 4096-byte sectors (Inferno's NVMe); with the default 512 Linux can't find its GPT.
    [ -n "${EXTRA_DRIVE:-}" ] && extra=(-drive "file=$EXTRA_DRIVE,format=raw,if=none,id=iphone-root"
                                        -device "virtio-blk-pci,drive=iphone-root,logical_block_size=4096,physical_block_size=4096")
    rm -f /tmp/InfernoUSBRemote
    "${machine[@]}" "${accel[@]}" -m 2G -smp 2 \
        -usb -device usb-ehci,id=ehci -device usb-tcp-remote,bus=ehci.0 \
        -drive file=companion.qcow2,if=virtio,discard=unmap -drive file=seed.iso,if=virtio,media=cdrom \
        "${extra[@]}" \
        -virtfs local,path="$DATA",mount_tag=host,security_model=none \
        -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:32222-:22 \
        -display none -serial file:companion.log -daemonize -pidfile companion.pid \
        || fail "companion failed to start (see $DATA/companion.log)"
    # Without KVM the first boot can take several minutes.
    for _ in $(seq 200); do ssh_up && { echo "companion up"; exit 0; }; sleep 3; done
    fail "companion did not come up (see $DATA/companion.log)"
    ;;
stop)
    running || { echo "companion not running"; exit 0; }
    "${CSSH[@]}" 'sudo systemctl poweroff' 2>/dev/null || true
    for _ in $(seq 60); do running || break; sleep 1; done
    running && kill "$(cat companion.pid)" 2>/dev/null
    rm -f companion.pid /tmp/InfernoUSBRemote
    echo "companion stopped"
    ;;
status)
    running && echo running || echo stopped
    ;;
*)
    echo "usage: companion.sh start|stop|status"; exit 2
    ;;
esac

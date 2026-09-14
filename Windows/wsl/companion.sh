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
        # A running companion keeps whichever USB link it was started with; the phone would otherwise
        # dial a port nobody is listening on.
        want=$(usb_tcp_port); have=$(cat "$DATA/companion.usbmode" 2>/dev/null || true)
        if [ "$want" != "$have" ]; then
            wd=${want:+TCP port $want}; hd=${have:+TCP port $have}
            echo "note: the running companion uses ${hd:-the unix socket} for USB," \
                 "but this run asks for ${wd:-the unix socket}."
            echo "      run 'iphone-vm companion stop' first, or the phone will not find it"
        fi
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
        # On Arch (and most distros) /dev/kvm belongs to the kvm group rather than being world-writable.
        [ -e /dev/kvm ] && echo "      to fix: sudo usermod -aG kvm $USER, then log out and back in"
    fi
    # The companion is the listening end of the USB link; the phone connects to it.
    usbdev="usb-tcp-remote,bus=ehci.0"
    utcp=$(usb_tcp_port)
    if [ -n "$utcp" ]; then
        usbdev+=",conn-type=ipv4,conn-addr=127.0.0.1,conn-port=$utcp"
        echo "USB link over TCP on 127.0.0.1:$utcp"
    fi
    extra=()
    # The iPhone disk uses 4096-byte sectors (Inferno's NVMe); with the default 512 Linux can't find its GPT.
    [ -n "${EXTRA_DRIVE:-}" ] && extra=(-drive "file=$EXTRA_DRIVE,format=raw,if=none,id=iphone-root"
                                        -device "virtio-blk-pci,drive=iphone-root,logical_block_size=4096,physical_block_size=4096")
    rm -f /tmp/InfernoUSBRemote
    "${machine[@]}" "${accel[@]}" -m 2G -smp 2 \
        -usb -device usb-ehci,id=ehci -device "$usbdev" \
        -drive file=companion.qcow2,if=virtio,discard=unmap -drive file=seed.iso,if=virtio,media=cdrom \
        "${extra[@]}" \
        -virtfs local,path="$DATA",mount_tag=host,security_model=none \
        -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:32222-:22 \
        -display none -serial file:companion.log -daemonize -pidfile companion.pid \
        || fail "companion failed to start (see $DATA/companion.log)"
    echo "$utcp" > "$DATA/companion.usbmode"
    # Without KVM the first boot can take several minutes.
    for _ in $(seq 200); do ssh_up && { echo "companion up"; exit 0; }; sleep 3; done
    fail "companion did not come up (see $DATA/companion.log)"
    ;;
stop)
    running || { echo "companion not running"; exit 0; }
    "${CSSH[@]}" 'sudo systemctl poweroff' 2>/dev/null || true
    for _ in $(seq 60); do running || break; sleep 1; done
    running && kill "$(cat companion.pid)" 2>/dev/null
    rm -f companion.pid /tmp/InfernoUSBRemote "$DATA/companion.usbmode"
    echo "companion stopped"
    ;;
status)
    running && echo running || echo stopped
    ;;
*)
    echo "usage: companion.sh start|stop|status"; exit 2
    ;;
esac

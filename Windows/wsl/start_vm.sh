#!/bin/bash
# Boots one Inferno iPhone VM (same layout as InfernoMac's VMRunner). The phone screen opens as a GTK
# window, which WSLg shows on the Windows desktop; the serial console is this script's stdin/stdout.
# Usage: start_vm.sh <vm-folder> <entry.json> <jailbreak 0|1> <qmp-port, 0 = none> [restore]
set -uo pipefail
source "$(dirname "$0")/common.sh"
VM="${1%/}"; ENTRY="$2"; JB="${3:-0}"; QMP="${4:-0}"; MODE="${5:-normal}"
e() { json "$ENTRY" "$1"; }
f() { echo "$VM/$1"; }

SEPSIM=$(e usesSEPSim); [ "$SEPSIM" = true ] || SEPSIM=false
ENGINE=$(engine_for "$(e sepVersion)")
[ -x "$ENGINE" ] || fail "the emulator for iOS $(e ios) isn't built ($ENGINE)"

machine="$(e machine),trustcache=$(f trustcache),kaslr-off=true"
if [ "$SEPSIM" != true ] || [ -f "$(f root_ticket.der)" ]; then machine+=",ticket=$(f root_ticket.der)"; fi
[ "$SEPSIM" = true ] || machine+=",sep-fw=$(f sep-firmware.img4),sep-rom=$(f "$(e sepROM)")"

bootargs="$(e bootArgs)"
[ "$JB" = 1 ] && bootargs+=" launchd_unsecure_cache=1"

args=(-M "$machine" -kernel "$(f kernelcache)" -dtb "$(f devicetree.im4p)" -append "$bootargs"
      -smp "$(e cpus)" -m "$(e memory)" -serial stdio -monitor none)
[ "$QMP" != 0 ] && args+=(-qmp "tcp:127.0.0.1:$QMP,server=on,wait=off")
if [ "$MODE" = restore ]; then
    args+=(-display none -initrd "$(f ramdisk_erase.dmg)")
else
    args+=(-display gtk,zoom-to-fit=on,show-cursor=on)
fi
if [ "$SEPSIM" != true ]; then
    args+=(-drive "file=$(f sep_nvram),if=pflash,format=raw" -drive "file=$(f sep_ssc),if=pflash,format=raw")
fi
for spec in root:1:1:nvme-ns firmware:2:2:nvme-ns syscfg:3:3:nvme-ns ctrl_bits:4:4:nvme-ns \
            nvram:5:5:apple-nvram effaceable:6:6:nvme-ns panic_log:7:8:nvme-ns; do
    IFS=: read -r name nsid nstype dev <<< "$spec"
    extra=""; [ "$dev" = apple-nvram ] && extra=",id=nvram"
    args+=(-drive "file=$(f "$name"),format=raw,if=none,id=$name"
           -device "$dev,drive=$name,bus=nvme-bus.0,nsid=$nsid,nstype=$nstype$extra,logical_block_size=4096,physical_block_size=4096")
done

echo "[starting $(e deviceName) $(e ios)]"
exec "$ENGINE" "${args[@]}"

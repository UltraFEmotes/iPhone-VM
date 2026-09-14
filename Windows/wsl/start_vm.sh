#!/bin/bash
# Boots one Inferno iPhone VM (same layout as InfernoMac's VMRunner). The phone screen opens as a GTK
# window, which WSLg shows on the Windows desktop; the serial console is this script's stdin/stdout.
# Usage: start_vm.sh <vm-folder> <entry.json> <jailbreak 0|1> <qmp-port, 0 = none> [restore]
#
# The web server (headless hosting) overrides the display and serial with env vars:
#   INFERNO_DISPLAY=vnc=127.0.0.1:<disp>   phone screen on that VNC display instead of a GTK window
#   INFERNO_SERIAL=tcp:127.0.0.1:<port>    serial console on a TCP socket instead of stdin/stdout
set -uo pipefail
source "$(dirname "$0")/common.sh"
VM="${1%/}"; ENTRY="$2"; JB="${3:-0}"; QMP="${4:-0}"; MODE="${5:-normal}"
e() { json "$ENTRY" "$1"; }
f() { echo "$VM/$1"; }
vm_setting() {
    local value
    value=$(json "$VM/vm.json" "$1" 2>/dev/null || true)
    [ -n "$value" ] && echo "$value" || echo "$2"
}

SEPSIM=$(e usesSEPSim); [ "$SEPSIM" = true ] || SEPSIM=false
ENGINE=$(engine_for "$(e sepVersion)")
[ -x "$ENGINE" ] || fail "the emulator for iOS $(e ios) isn't built ($ENGINE)"

graphics_mode="${INFERNO_GRAPHICS_MODE:-$(vm_setting graphicsMode default)}"
performance_mode="${INFERNO_PERFORMANCE_MODE:-$(vm_setting performanceMode balanced)}"
audio_mode="${INFERNO_AUDIO_MODE:-$(vm_setting audioMode stable)}"

case "$graphics_mode" in
    default|software) ;;
    smooth|full-res)
        [ "$(e machine)" = t8030 ] && GRAPHICS_PROPS=",disp-width=828,disp-height=1792" || GRAPHICS_PROPS=""
        ;;
    fast-half|half-res)
        [ "$(e machine)" = t8030 ] && GRAPHICS_PROPS=",disp-width=414,disp-height=896" || GRAPHICS_PROPS=""
        ;;
    *) fail "unknown graphics mode '$graphics_mode' (use default, smooth or fast-half)" ;;
esac

case "$performance_mode" in
    balanced) ACCEL="tcg,thread=multi,tb-size=256" ;;
    fast|fast-tcg) ACCEL="tcg,thread=multi,tb-size=768,split-wx=off" ;;
    low-memory) ACCEL="tcg,thread=multi,tb-size=128" ;;
    *) fail "unknown performance mode '$performance_mode' (use balanced, fast or low-memory)" ;;
esac

case "$audio_mode" in
    stable|disabled|off|aop) ;;
    *) fail "unknown audio mode '$audio_mode' (use stable, aop or disabled)" ;;
esac

machine="$(e machine),trustcache=$(f trustcache),kaslr-off=true${GRAPHICS_PROPS:-}"
[ "$audio_mode" = aop ] && [ "$(e machine)" = t8030 ] && machine+=",aop-audio=true"
if [ "$SEPSIM" != true ] || [ -f "$(f root_ticket.der)" ]; then machine+=",ticket=$(f root_ticket.der)"; fi
[ "$SEPSIM" = true ] || machine+=",sep-fw=$(f sep-firmware.img4),sep-rom=$(f "$(e sepROM)")"

bootargs="$(e bootArgs)"
[ "$JB" = 1 ] && bootargs+=" launchd_unsecure_cache=1"

args=(-M "$machine" -kernel "$(f kernelcache)" -dtb "$(f devicetree.im4p)" -append "$bootargs"
      -smp "$(e cpus)" -m "$(e memory)" -monitor none -accel "$ACCEL")
if [ "$audio_mode" != disabled ] && [ "$audio_mode" != off ]; then
    AUDIO_BACKEND=$(qemu_audio_backend "$ENGINE")
    if [ -n "$AUDIO_BACKEND" ]; then
        args+=(-audiodev "$AUDIO_BACKEND,id=snd0")
    else
        echo "[no supported QEMU audio backend found; continuing without host audio]" >&2
    fi
fi
# Serial: a TCP socket for the web server, otherwise this script's stdin/stdout.
case "${INFERNO_SERIAL:-stdio}" in
    tcp:*) args+=(-serial "tcp:${INFERNO_SERIAL#tcp:},server=on,wait=off") ;;
    *) args+=(-serial stdio) ;;
esac
[ "$QMP" != 0 ] && args+=(-qmp "tcp:127.0.0.1:$QMP,server=on,wait=off")
# Display: a VNC display for the web server, a GTK window on a desktop, or none during restore.
if [ "$MODE" = restore ]; then
    args+=(-display none -initrd "$(f ramdisk_erase.dmg)")
elif [ -n "${INFERNO_DISPLAY:-}" ]; then
    case "$INFERNO_DISPLAY" in
        vnc=*) args+=(-vnc "${INFERNO_DISPLAY#vnc=}") ;;
        none) args+=(-display none) ;;
        *) args+=(-display "$INFERNO_DISPLAY") ;;
    esac
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

echo "[starting $(e deviceName) $(e ios); graphics=$graphics_mode performance=$performance_mode audio=$audio_mode]"
exec "$ENGINE" "${args[@]}"

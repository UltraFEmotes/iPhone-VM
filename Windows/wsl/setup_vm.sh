#!/bin/bash
# Turns a new VM folder into a restored, patched Inferno VM — the same steps as InfernoMac's SetupPipeline.
# Finished steps are recorded in <vm>/steps.done, so a re-run resumes where it stopped.
# Usage: setup_vm.sh <vm-folder under $DATA/VMs> <entry.json> <jailbreak 0|1>
set -uo pipefail
source "$(dirname "$0")/common.sh"
VM="${1%/}"; ENTRY="$2"; JB="${3:-0}"
[ -d "$VM" ] || fail "no VM folder $VM"
[ "$(dirname "$VM")" = "$DATA/VMs" ] || fail "VM folders must live in $DATA/VMs (the companion sees them there)"
e() { json "$ENTRY" "$1"; }

IPSW_URL=$(e ipswURL); IPSW_SIZE=$(e ipswSize)
IPSW="$DATA/ipsw-cache/$(basename "$IPSW_URL")"
SEPSIM=$(e usesSEPSim); [ "$SEPSIM" = true ] || SEPSIM=false
R="$VM/Restore"
DONE_FILE="$VM/steps.done"
VM_IN_COMPANION="/mnt/host/VMs/$(basename "$VM")"

run() {
    local name=$1; shift
    if grep -qx "$name" "$DONE_FILE" 2>/dev/null; then echo "SKIP:$name"; return; fi
    step "$name"
    "$@" || fail "$name failed"
    echo "$name" >> "$DONE_FILE"
}

check_space() {
    local free need=18000000000
    [ -f "$IPSW" ] && need=12000000000
    free=$(df --output=avail -B1 "$DATA" | tail -1)
    echo "free: $((free / 1000000000)) GB, need about $((need / 1000000000)) GB"
    [ "$free" -ge "$need" ] || { echo "Not enough free space"; return 1; }
}

download_ipsw() {
    size() { stat -c %s "$IPSW" 2>/dev/null || echo 0; }
    [ "$(size)" = "$IPSW_SIZE" ] && { echo "already downloaded"; return 0; }
    # One download per firmware file, even across VMs sharing the cache.
    exec 9>"$IPSW.lock"
    flock -n 9 || { echo "This firmware is already being downloaded by another setup."; return 1; }
    curl -L -f -s -C - -o "$IPSW" "$IPSW_URL" &
    local pid=$!
    while kill -0 $pid 2>/dev/null; do
        echo "PROGRESS:$(( $(size) * 100 / IPSW_SIZE ))"
        sleep 5
    done
    wait $pid || { echo "download failed (it resumes if you retry)"; return 1; }
    [ "$(size)" = "$IPSW_SIZE" ] || { echo "IPSW size $(size) != expected $IPSW_SIZE"; return 1; }
}

download_seprom() {
    [ "$SEPSIM" = true ] && { echo "not needed (simulated Secure Enclave)"; return 0; }
    [ -f "$VM/$(e sepROM)" ] || curl -L -f -s -o "$VM/$(e sepROM)" "$(e sepROMURL)"
}

extract() {
    mkdir -p "$R"
    unzip -o -q "$IPSW" BuildManifest.plist "$(e kernelcache)" "$(e deviceTree)" "$(e trustcache)" \
        "$(e eraseRamdisk)" "$(e sepFirmwarePath)" -d "$R" || return 1
    cp "$R/$(e kernelcache)" "$VM/kernelcache"
    cp "$R/$(e deviceTree)" "$VM/devicetree.im4p"
    cp "$R/$(e trustcache)" "$VM/trustcache"
    cp "$R/$(e eraseRamdisk)" "$VM/ramdisk_erase.dmg"
}

tickets() {
    local py="$DATA/venv/bin/python" manifest="$R/BuildManifest.plist" shsh="$DATA/ticket.shsh2"
    if ! "$py" "$DATA/create_apticket.py" "$(e board)" "$manifest" "$shsh" "$VM/root_ticket.der"; then
        [ "$SEPSIM" = true ] || return 1
        echo "AP ticket not created; this machine boots without one"
    fi
    [ "$SEPSIM" = true ] || "$py" "$DATA/create_septicket.py" "$(e board)" "$manifest" "$shsh" "$VM/sep_root_ticket.der"
}

sep_firmware() {
    [ "$SEPSIM" = true ] && { echo "not needed (simulated Secure Enclave)"; return 0; }
    local img4="$DATA/img4lib/img4" raw="$VM/sep-firmware.raw" version out
    version=$("$img4" -v -i "$R/$(e sepFirmwarePath)" -o "$raw" -k "$(e sepIV)$(e sepKey)") || return 1
    out=$("$img4" -A -F -o "$VM/sep-firmware.img4" -i "$raw" -M "$VM/sep_root_ticket.der" -T rsep -V "$version")
    rm -f "$raw"
    echo "$out" | grep -q none || [ -z "$out" ] || { echo "SEP repack output unexpected: $out"; return 1; }
}

disks() {
    local sizes=(root:32G firmware:8M syscfg:128K ctrl_bits:8K nvram:8K effaceable:4K panic_log:1M)
    [ "$SEPSIM" = true ] || sizes+=(sep_nvram:64K sep_ssc:128K)
    for s in "${sizes[@]}"; do
        [ -f "$VM/${s%%:*}" ] || "$QEMU_IMG" create -f raw "$VM/${s%%:*}" "${s##*:}" >/dev/null || return 1
    done
}

restore() {
    "$SCRIPTS/companion.sh" start || return 1
    local name; name=$(basename "$IPSW")
    local ticket="$DATA/ipsw-cache/$(basename "$VM")-root_ticket.der"
    cp "$VM/root_ticket.der" "$ticket"
    echo "caching the OS image in the companion (several minutes)"
    "${CSSH[@]}" "mkdir -p ~/cache/${name%.ipsw} && python3 - <<'EOF'
import zipfile, shutil, os
z = zipfile.ZipFile('/mnt/host/ipsw-cache/$name')
big = max(z.infolist(), key=lambda i: i.file_size if i.filename.endswith(('.dmg', '.dmg.aea')) else 0)
dest = os.path.expanduser('~/cache/${name%.ipsw}/' + big.filename)
if not (os.path.exists(dest) and os.path.getsize(dest) == big.file_size):
    with z.open(big) as s, open(dest, 'wb') as d: shutil.copyfileobj(s, d, 16 << 20)
print('cached', big.filename)
EOF" || return 1
    # Boot the restore ramdisk, then trigger the restore within its 120 s window.
    "$SCRIPTS/start_vm.sh" "$VM" "$ENTRY" 0 0 restore > "$VM/restore-boot.log" 2>&1 &
    local vmpid=$! ready=0
    # Show the phone's own serial console and the companion's kernel log as they happen, so the whole
    # restore is readable in one stream instead of hiding in two files. Both tails are tied to the VM's
    # pid, so they stop by themselves when it exits.
    tail --pid="$vmpid" -n +1 -F "$VM/restore-boot.log" 2>/dev/null | sed -u "s/^/  [phone] /" &
    tail --pid="$vmpid" -n 0 -F "$DATA/companion.log" 2>/dev/null | sed -u "s/^/  [companion] /" &
    for _ in $(seq 150); do
        grep -q "waiting for host to trigger start of restore" "$VM/restore-boot.log" && { ready=1; break; }
        kill -0 $vmpid 2>/dev/null || break
        sleep 2
    done
    [ $ready = 1 ] || { echo "restore ramdisk never became ready"; kill $vmpid 2>/dev/null; return 1; }
    echo "ramdisk ready, running idevicerestore"
    # idevicerestore reaches 100% as soon as the image has been sent. The phone then writes and verifies it,
    # which is emulated CPU work that prints nothing for a long time — hours on a laptop — and looks hung.
    # Report the VM's disk and CPU use meanwhile: if the disk stops growing but CPU time keeps climbing it is
    # verifying, and only when neither moves for a long while is it really stuck.
    # Report bytes the VM actually wrote (/proc/<pid>/io wchar), not the disk file's allocated size: once
    # the image file is allocated, "size" stops growing whether the phone is writing or doing nothing at
    # all, which makes a dead restore look identical to a working one. wchar counts write() syscalls, so
    # it catches buffered writes; write_bytes would not, as writeback is charged to kernel threads.
    heartbeat() {
        local pid=$1 prev=0 w cpu quiet=0
        while kill -0 "$pid" 2>/dev/null; do
            sleep 60
            w=$(awk '/^wchar:/ {print $2}' "/proc/$pid/io" 2>/dev/null); w=${w:-0}
            cpu=$(ps -o cputime= -p "$pid" 2>/dev/null | tr -d " ")
            if [ "$w" -gt "$prev" ]; then
                quiet=0
                echo "  ...restoring: phone wrote $(((w - prev) / 1000000)) MB this minute ($((w / 1000000)) MB total), VM cpu ${cpu:-?}"
            else
                quiet=$((quiet + 1))
                echo "  ...restoring: phone wrote NOTHING this minute ($quiet in a row), VM cpu ${cpu:-?}"
                [ "$quiet" = 5 ] && echo "  note: 5 minutes without a single disk write. If the [phone] log is silent too, the restore has" \
                    "stalled rather than slowed — USB is unstable in Inferno. Ctrl-C and run setup again to retry."
            fi
            prev=$w
        done
    }
    heartbeat "$vmpid" &
    local hb=$!
    local out
    out=$("${CSSH[@]}" "sudo idevicerestore --erase --restore-mode -i 0x1122334455667788 -C ~/cache \
        /mnt/host/ipsw-cache/$name -T /mnt/host/ipsw-cache/$(basename "$ticket") 2>&1" | tee /dev/stderr)
    kill "$hb" 2>/dev/null
    for _ in $(seq 60); do kill -0 $vmpid 2>/dev/null || break; sleep 1; done
    kill $vmpid 2>/dev/null
    rm -f "$ticket"
    echo "$out" | grep -qE "Restore Finished|DONE" || { echo "idevicerestore did not finish"; return 1; }
}

patch() {
    if [ "$JB" = 1 ] && [ ! -f "$DATA/strap.tar.lzma" ]; then
        local url
        url=$(curl -sL https://assets.checkra.in/loader/config.json | python3 -c 'import json,sys;print(json.load(sys.stdin)["core_bootstrap_tar"])')
        curl -sL -f -o "$DATA/strap.tar.lzma" "$url" || { echo "jailbreak bootstrap download failed"; return 1; }
    fi
    # Linux APFS write support is experimental: keep an untouched copy of the root disk.
    [ -f "$VM/root.prepatch" ] || cp --sparse=always "$VM/root" "$VM/root.prepatch"
    "$SCRIPTS/companion.sh" stop
    EXTRA_DRIVE="$VM/root" "$SCRIPTS/companion.sh" start || return 1
    # The APFS driver reports mount and write trouble to the companion's kernel log, not to the patch
    # script, so show that too while the patch runs.
    stream_companion() { tail -n 0 -F "$DATA/companion.log" 2>/dev/null | sed -u "s/^/  [companion] /"; }
    stream_companion &
    local ctail=$!
    local out
    out=$("${CSSH[@]}" "sudo bash /mnt/host/companion-files/patch_in_companion.sh '$VM_IN_COMPANION' '$JB'" 2>&1 | tee /dev/stderr)
    pkill -P "$ctail" 2>/dev/null; kill "$ctail" 2>/dev/null
    "$SCRIPTS/companion.sh" stop
    "$SCRIPTS/companion.sh" start
    echo "$out" | grep -q FS_PATCHES_DONE || { echo "filesystem patch did not complete (untouched copy kept as root.prepatch)"; return 1; }
    rm -f "$VM/root.prepatch"
}

run check-space check_space
run download-ipsw download_ipsw
run download-seprom download_seprom
run extract extract
run tickets tickets
run sep-firmware sep_firmware
run disks disks
run restore restore
run patch patch
echo DONE

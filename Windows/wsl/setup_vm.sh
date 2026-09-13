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
    for _ in $(seq 150); do
        grep -q "waiting for host to trigger start of restore" "$VM/restore-boot.log" && { ready=1; break; }
        kill -0 $vmpid 2>/dev/null || break
        sleep 2
    done
    [ $ready = 1 ] || { echo "restore ramdisk never became ready"; tail -c 1500 "$VM/restore-boot.log"; kill $vmpid 2>/dev/null; return 1; }
    echo "ramdisk ready, running idevicerestore"
    local out
    out=$("${CSSH[@]}" "sudo idevicerestore --erase --restore-mode -i 0x1122334455667788 -C ~/cache \
        /mnt/host/ipsw-cache/$name -T /mnt/host/ipsw-cache/$(basename "$ticket") 2>&1" | tee /dev/stderr)
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
    local out
    out=$("${CSSH[@]}" "sudo bash /mnt/host/companion-files/patch_in_companion.sh '$VM_IN_COMPANION' '$JB'" 2>&1 | tee /dev/stderr)
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

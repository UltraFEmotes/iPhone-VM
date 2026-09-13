#!/bin/bash
# Inferno filesystem patches for one InfernoMac VM (guide: Filesystem Patches, + optional jailbreak bootstrap).
# Runs as root (InfernoMac asks for the administrator password).
# Usage: patch_fs.sh <vm-folder> <InfernoData dir> <jailbreak: 0|1>
set -euo pipefail
VM="$1"; DATA="$2"; JB="${3:-0}"
ROOT_DISK="$VM/root"
[ -f "$ROOT_DISK" ] || { echo "no raw root disk at $ROOT_DISK"; exit 1; }

cleanup() { diskutil eject /Volumes/System >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== attaching root disk"
hdiutil attach -imagekey diskimage-class=CRawDiskImage -blocksize 4096 -noverify -noautofsck "$ROOT_DISK"
[ -d /Volumes/System/System ] || { echo "/Volumes/System not mounted"; exit 1; }
diskutil enableownership /Volumes/System
mount -urw /Volumes/System

echo "== patching dyld shared cache"
"$DATA/InfernoFSPatcher/build/inferno_fs_patcher" /Volumes/System/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e

LP=/Volumes/System/System/Library/xpc/launchd.plist
[ -f "$VM/launchd.plist.orig" ] || cp "$LP" "$VM/launchd.plist.orig"

if [ "$JB" = "1" ]; then
    # The bootstrap is checkra1n's (iOS 12–14). On newer iOS it would break the system, so skip it there.
    IOS=$(/usr/libexec/PlistBuddy -c "Print :ProductVersion" /Volumes/System/System/Library/CoreServices/SystemVersion.plist 2>/dev/null || echo "")
    if [ -z "$IOS" ] || [ "${IOS%%.*}" -gt 14 ] 2>/dev/null; then
        echo "== iOS ${IOS:-unknown}: the jailbreak bootstrap only supports iOS 12–14 — skipping it (VM stays stock)"
        JB=0
    fi
fi

if [ "$JB" = "1" ]; then
    echo "== installing jailbreak bootstrap"
    STRAP="$DATA/strap.tar.lzma"
    if [ ! -f "$STRAP" ]; then
        URL=$(curl -sL https://assets.checkra.in/loader/config.json | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin)["core_bootstrap_tar"])')
        curl -sL -o "$STRAP" "$URL"
    fi
    tar xf "$STRAP" -C /Volumes/System
fi

echo "== disabling problematic launch services"
/usr/bin/python3 - "$LP" "$JB" <<'EOF'
import plistlib, sys
path, jb = sys.argv[1], sys.argv[2] == "1"
with open(path, 'rb') as f:
    pl = plistlib.load(f)
targets = {"com.apple.voicemail.vmd", "com.apple.CommCenter", "com.apple.CommCenterMobileHelper",
           "com.apple.CommCenterRootHelper", "com.apple.locationd"}
done = set()
daemons = pl.setdefault("LaunchDaemons", {})
for entry in daemons.values():
    if isinstance(entry, dict) and entry.get("Label") in targets:
        entry["Disabled"] = True
        done.add(entry["Label"])
if jb:
    daemons["/System/Library/LaunchDaemons/bash.plist"] = {
        "EnablePressuredExit": False, "Label": "com.apple.bash", "POSIXSpawnType": "Interactive",
        "ProgramArguments": ["/bin/bash"], "RunAtLoad": True,
        "StandardErrorPath": "/dev/console", "StandardInPath": "/dev/console", "StandardOutPath": "/dev/console",
        "Umask": 0, "UserName": "root"}
with open(path, 'wb') as f:
    plistlib.dump(pl, f, fmt=plistlib.FMT_XML)
print("disabled:", sorted(done))
missing = targets - done
if missing:
    print("NOT FOUND:", sorted(missing)); sys.exit(1)
EOF

echo "FS_PATCHES_DONE"

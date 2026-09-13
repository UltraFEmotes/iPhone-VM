#!/bin/bash
# Inferno filesystem patches, done inside the companion with the Linux APFS driver (apfs-dkms, readwrite).
# The iPhone root disk is attached to the companion as an extra virtio disk (setup_vm.sh does that).
# Same patches as InfernoMac's patch_fs.sh: dyld cache, disabled launch daemons, optional jailbreak strap.
# Usage (as root): patch_in_companion.sh <vm folder under /mnt/host/VMs> <jailbreak 0|1>
set -euo pipefail
VMH="$1"; JB="${2:-0}"
MNT=/mnt/iphone-system
cleanup() { mountpoint -q "$MNT" && umount "$MNT" || true; }
trap cleanup EXIT

modprobe apfs
PART=$(blkid -t TYPE=apfs -o device | head -1)
[ -n "$PART" ] || { echo "no APFS container found on the attached disk"; exit 1; }
mkdir -p "$MNT"

# Find the System volume (the one holding the dyld cache), then remount it read-write.
SYSVOL=""
for vol in 0 1 2 3 4 5; do
    mount -t apfs -o "vol=$vol" "$PART" "$MNT" 2>/dev/null || continue
    if [ -f "$MNT/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e" ]; then SYSVOL=$vol; fi
    umount "$MNT"
    [ -n "$SYSVOL" ] && break
done
[ -n "$SYSVOL" ] || { echo "System volume not found in $PART"; exit 1; }
echo "== System volume is vol=$SYSVOL on $PART"
mount -t apfs -o "vol=$SYSVOL,readwrite" "$PART" "$MNT"

echo "== patching dyld shared cache"
/opt/InfernoFSPatcher/build/inferno_fs_patcher "$MNT/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"

LP="$MNT/System/Library/xpc/launchd.plist"
[ -f "$VMH/launchd.plist.orig" ] || cp "$LP" "$VMH/launchd.plist.orig"

if [ "$JB" = "1" ]; then
    echo "== installing jailbreak bootstrap"
    tar --lzma -xpf /mnt/host/strap.tar.lzma -C "$MNT"
fi

echo "== disabling problematic launch services"
python3 - "$LP" "$JB" <<'EOF'
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

sync
umount "$MNT"
echo "FS_PATCHES_DONE"

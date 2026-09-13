# InfernoPhone — handoff notes

> **iPhone app PAUSED (owner switched to a macOS app first).** Root cause of "stuck on spinner" was found
> in `Data/debug.log`: `-spice ...,gl=off: Invalid parameter 'gl'` → QEMU exits with -1. Inferno for iOS is
> built with `--disable-opengl`, so SPICE has no `gl` option. Fix: in
> `App/Configuration/UTMQemuConfiguration+Arguments.swift`, don't emit `"gl=\(glBackend)"` for Inferno VMs
> (e.g. give `spiceArguments` a flag used by `infernoBaseArguments`), rebuild the IPA, re-sign with the
> existing profile (steps below), reinstall. Also already applied on the phone: `DebugLog` on in the VM's
> `config.plist`, `-accel tcg,thread=multi,tb-size=256` in `inferno.json`.
>
> **The Mac-side copy of the test VM moved:** `out/iPhone11-iOS14.utm/Data/` now only holds `inferno.json`.
> Its disk + boot files were moved (renamed) into the macOS app's VM folder
> `~/Library/Application Support/InfernoMac/VMs/5DB65271-0D41-436C-A791-5B11467D5F36/`
> (`root.qcow2`, `trustcache`, `kernelcache`, `devicetree.im4p`, `sep-firmware.img4`, …). The phone still has
> its own full copy in the app's Documents.
>
> **macOS app (current work):** `InfernoPhone/Mac/` (XcodeGen: `xcodegen generate`, then build scheme
> `InfernoMac`). It drives the existing Mac Inferno build in `~/Documents/iphone/InfernoData/Inferno/build`.
> Features so far: VM list, wizard (device → iOS → jailbreak; tested versions, plus experimental behind a
> toggle), in-app setup pipeline (download → unpack → tickets → SEP → disks → restore via companion → patch,
> notifications, keeps Mac awake), VM | Terminal | Files tabs, device buttons over QMP, Phone Info
> (serial/MLB/model/region via t8030 machine props), several VMs at once. VMs live in
> `~/Library/Application Support/InfernoMac/VMs/<uuid>/`; downloaded IPSWs in `InfernoData/ipsw-cache/`
> (shared with the companion over 9p).
>
> **Versions:** iPhone 11 iOS 14.0b5 = tested. iPhone 11 iOS 15.0 / 16.0 / 17.0 / 18.0 = experimental
> (data from each IPSW's BuildManifest + Apple Wiki SEP keys). Inferno picks the SEP bypass at build time, so
> each needs its own engine: `InfernoData/Inferno/build-sep15..18/qemu-system-aarch64` (built with
> `-DSEP_USE_VERSION_OVERRIDE=N`; `hw/arm/apple-silicon/sep.c` in the main checkout now wraps the define in
> `#ifndef`, default 14). All four `build-sep15..18` engines are built and signed.
>
> **iPhone 6s Plus** (`s8000` = N66, `iPhone8,2`, *not* the plain 6s): iOS 14.0 (18A373) and 15.0 (19A346)
> as experimental entries (`usesSEPSim: true`). Its SEP is simulated, so setup skips the SEP ROM / SEP ticket /
> SEP firmware steps and the launcher omits `sep-fw`, `sep-rom` and the SEP pflash drives. Only release kernels
> ship in these IPSWs (no research kernel) — the biggest open question for booting. No Phone Info on s8000
> (it has no serial/model machine properties).
>
> **Carrier console** (Shift-Cmd-K window): assign custom numbers per VM, device online status, admin
> messages to one/all, texts and calls between numbers, traffic log (`~/Library/Application Support/InfernoMac/
> carrier.json`). Delivery *into* iOS isn't built yet (`LogOnlyDelivery`); waiting on the owner's choice:
> notification, a Carrier inbox app, or Messages. Any in-VM delivery needs a way into the guest — realistically
> the jailbreak bootstrap's root shell on the serial console (iOS 14/15 only).
>
> **VM internet works (2026-09-13):** InfernoMac starts the companion before booting a VM; the iPhone VM's
> emulated USB (`/tmp/InfernoUSBRemote`) reaches the companion, which reverse-tethers it (CDC-NCM
> `enxdeadbeef*` → `192.168.178.1`, dnsmasq DHCP/DNS with `no-resolv` + `server=10.0.2.3`, NAT out `enp0s1`).
> Gotchas fixed: (1) the companion's udev rule must fire on `add|move` (the NIC is created as `usb0` then renamed)
> — now it runs `iphone-tether.service`; (2) usbmuxd exits when idle, so start it before `idevicepair pair`
> (the **Send Trust Prompt** button does); (3) if "Don't Trust" was tapped, iOS refuses on that USB connection
> until the VM reboots — changing the companion's SystemBUID does not help. iOS takes ~2 min after boot to
> enable USB. Companion pairing identity was reset; old one backed up in `/var/lib/lockdown/backup-*`.
> **Install Zebra** button (jailbroken VMs) types Elucubratus (`apt.bingner.com ios/1700.00`) + Zebra
> (`getzbra.com/repo`) sources and `apt-get install uikittools xyz.willy.zebra` into the serial root shell — untested.
>
> **Not tested yet:** every experimental version (none has been set up end-to-end). Each download is 4.5–8 GB and
> the Mac has ~13 GB free, so test one at a time.

> **Latest status:** the app is **installed on the iPhone 17** as "UTM" (`com.infernophone.9ll7add265.UTM`,
> re-signed with the existing free-account profile, has `get-task-allow`). The test VM
> (`out/iPhone11-iOS14.utm`, 5.9 GB) was being copied into the app's Documents with
> `scripts/push_vm_to_phone.sh`. Next: open the app **from StikDebug** (JIT), tap "iPhone 11 (iOS 14)".
> Signing profile expires **2026-09-19** — re-sign and reinstall after that (steps below).

Goal: an iOS app (sideloaded IPA) that runs **ChefKiss Inferno** iPhone VMs directly on an iPhone.
Owner's devices: MacBook (Apple Silicon, macOS 27, Xcode 27), **iPhone 17** (`iPhone18,3`, iOS 27.0,
UDID `00008150-000431062E40C01C`, Developer Mode ON). Sideloading uses a **free Apple ID**
(Personal Team `9LL7ADD265`), JIT via **StikDebug** (`com.stik.stikdebug.9LL7ADD265`, v3.1.10).

---

## ⚠️ Current problem: iloader can't put the pairing file into StikDebug

**Symptom:** iloader says `Failed to vend documents: device socket io failed` when placing the
pairing file into StikDebug.

**What was found:**
- StikDebug *is* installed on the phone.
- Pushing into StikDebug's Documents over USB (AFC / house_arrest "VendDocuments") is refused by iOS
  for StikDebug. Tested with `afcclient --documents com.stik.stikdebug.9LL7ADD265` →
  `Could not get result from document sharing service!`. So this is not an iloader bug — iOS won't
  expose StikDebug's Documents folder over USB. Retrying iloader won't fix it.
- Reading `/var/db/lockdown/<UDID>.plist` on the Mac fails even with `sudo`
  (`Operation not permitted`) because of macOS privacy protection (Terminal lacks Full Disk Access).

**Workaround already done:** the pairing file was pulled from the Mac's usbmuxd service (no Full Disk
Access needed) and saved to:

```
~/Desktop/iPhone17.mobiledevicepairing
```

It contains `DeviceCertificate, HostCertificate, HostID, HostPrivateKey, RootCertificate,
RootPrivateKey, SystemBUID, EscrowBag, WiFiMACAddress, UDID`.

**What to do instead of iloader:**
1. AirDrop `~/Desktop/iPhone17.mobiledevicepairing` to the iPhone → **Save to Files**
   (or iCloud Drive / email to self if AirDrop refuses the file type).
2. Open StikDebug → **Import Pairing File** → pick it from Files.
3. Delete the Desktop copy afterwards. **This file can control the iPhone — never share it.**
4. If StikDebug later can't connect: replug the phone, tap *Trust*, then re-export the pairing file
   (the script that produced it is in "How the pairing file was made" below).

---

## ✅ IPA is built: `~/Documents/iphone/InfernoPhone/out/InfernoPhone.ipa` (139 MB, unsigned)
Contains Inferno's `qemu-aarch64-softmmu.framework`. Install with iloader / SideStore / AltStore
(they re-sign it with the Apple ID), then trust the certificate and launch via StikDebug for JIT.
The notes below are the history of how it was built, in case it needs rebuilding.

## Other thing the owner asked for: "where's the IPA"

No IPA existed yet (Xcode "Run" installs a `.app` directly, no IPA). A background build was started:
- archive: `App/scripts/build_utm.sh -k iphoneos -s iOS -a arm64 -o ../out/InfernoPhone`
- then: `App/scripts/package.sh ipa ../out/InfernoPhone.xcarchive <output dir>`
- **Gotcha:** `package.sh` requires the output directory to be **EMPTY** and names the file `UTM.ipa`.
  The running job passed `out/` (not empty), so packaging may fail. If so, rerun just the packaging:

```
cd ~/Documents/iphone/InfernoPhone/App
mkdir -p ../out/ipa && ./scripts/package.sh ipa ../out/InfernoPhone.xcarchive ../out/ipa
mv ../out/ipa/UTM.ipa ../out/InfernoPhone.ipa
```

**First attempt failed** (not a code problem): Xcode couldn't resolve Swift packages —
`unable to create file Screenshot/...` while checking out IQKeyboardManager — a corrupted package
download left over from when the disk was full. Fix = clear the package caches and rebuild. A second
attempt was started with exactly that; if `out/InfernoPhone.ipa` doesn't exist, rerun:

```
rm -rf ~/Library/Caches/org.swift.swiftpm
find ~/Library/Developer/Xcode/DerivedData ~/Documents/iphone/InfernoPhone/App -maxdepth 3 -type d -name SourcePackages -prune -exec rm -rf {} +
cd ~/Documents/iphone/InfernoPhone/App
./scripts/build_utm.sh -k iphoneos -s iOS -a arm64 -o ../out/InfernoPhone
mkdir -p ../out/ipa && ./scripts/package.sh ipa ../out/InfernoPhone.xcarchive ../out/ipa
mv ../out/ipa/UTM.ipa ../out/InfernoPhone.ipa
```
(Check the build log `out/archive.log` for `** ARCHIVE SUCCEEDED **`.)

It's an **unsigned** IPA — iloader / SideStore / AltStore re-sign it with the Apple ID on install.
Alternative: open `App/UTM.xcodeproj` in Xcode, scheme **iOS**, destination **iPhone (5)**, ⌘R.
Running from Xcode keeps the debugger attached, which also enables JIT.

---

## Next steps (in order)

1. Get StikDebug its pairing file (see above).
2. Install the app: the IPA via iloader/SideStore, **or** Xcode ⌘R.
   On the phone: Settings → General → VPN & Device Management → trust `sezzy718@icloud.com`.
3. Copy the test VM onto the phone (the app must be installed first, and file sharing is enabled
   in the app):
   ```
   ~/Documents/iphone/InfernoPhone/scripts/push_vm_to_phone.sh
   ```
   (copies `out/iPhone11-iOS14.utm`, 5.9 GB, into the app's Documents over USB — slow.)
4. Launch the app **from StikDebug** (or Xcode) so JIT is on, tap **"iPhone 11 (iOS 14)"**.
5. Watch the **Terminal** view (serial log). Unknowns on first boot:
   - guest RAM is set to 2 GB (`-m 2G` in `Data/inferno.json`) — may be too little for Inferno's
     t8030 machine, or too much for a free-account app's memory limit;
   - speed on the iPhone 17 is untested.
   - Known harmless-until-restart panics seen on the Mac: `SEP Panic: :sars/sars` and
     `t8020dart invalid lock state` → just restart the VM (Inferno maintainer guidance).

---

## What exists (all on the Mac)

| Path | What |
|---|---|
| `~/Documents/iphone/InfernoPhone/` | project repo (git). `docs/superpowers/specs/2026-09-13-inferno-ios-app-design.md` = design spec |
| `InfernoPhone/App/` | copy of UTM (Apache 2.0) = the app. Branch `infernophone`. Signing in `CodeSigning.xcconfig` (team `9LL7ADD265`, bundle prefix `com.infernophone.9ll7add265` → app ID `com.infernophone.9ll7add265.UTM`) |
| `InfernoPhone/deps/inferno-ios/` | Inferno QEMU ported to iOS (git worktree, branch `ios-port`) |
| `InfernoPhone/scripts/` | `build_inferno_ios.sh`, `package_qemu_framework.sh`, `install_on_phone.sh`, `push_vm_to_phone.sh`, `make_utm_package.py` |
| `InfernoPhone/out/iPhone11-iOS14.utm` | test VM package (restored iOS 14.0 beta 5, iPhone 11) |
| `InfernoPhone/out/utm-original/` | backup of UTM's stock `qemu-aarch64-softmmu.framework` |
| `~/Documents/iphone/UTM/sysroot-iOS-arm64` | UTM's prebuilt iOS libraries; its `Frameworks/qemu-aarch64-softmmu.framework` has been **replaced with Inferno** |
| `~/Documents/iphone/InfernoData/` | the working **Mac** Inferno setup (iPhone 11 VM + Debian companion VM, reverse-tethered internet). Start: `./start_companion.sh` then `./start_iphone.sh` |

### How the app runs Inferno
`App/Services/UTMQemuVirtualMachine.swift` → if `<vm>.utm/Data/inferno.json` exists, QEMU is started with
UTM's plumbing only (`infernoBaseArguments`: SPICE display + QMP + built-in serial terminal) plus the
arguments from that JSON (`$DATA` = the VM's Data folder). The app's VM screen and Terminal views come
from UTM's SPICE display and built-in serial terminal.

### iOS port changes made to Inferno (branch `ios-port`)
UTM's iOS JIT workaround (iOS 26+), libucontext coroutines, shared-library build exporting
`qemu_init/qemu_main_loop/qemu_cleanup`, `CONFIG_VMAPPLE=n` + `--disable-pvg` (macOS/iOS 27 SDK dropped
ParavirtualizedGraphics), spice-server 0.14.3 compatibility (`SPICE_HAS_ATTACHED_WORKER`),
`statfs` headers for iOS in `block/file-posix.c`, `mpz_inits/mpz_clears` shim over nettle mini-gmp,
link `-lhogweed -lnettle`. Extra iOS libs built into `deps/ios-arm64` (lzfse, nettle 3.10.2 w/ mini-gmp,
libtasn1 4.21.0, a `zlib.pc` pointing at the SDK's libz).

---

## Free Apple ID hit the app-ID limit — use the existing profile (manual signing)
Xcode's automatic signing failed with **"Not enough available app IDs. 1 is required, but only 0 are
available."** (a free account can register only 3 app IDs per 7 days; the UTM/UTM-Remote/UTM-SE targets
used them). Do **not** let Xcode register more. The app's own ID already has a valid profile:

- profile `iOS Team Provisioning Profile: com.infernophone.9ll7add265.UTM`
- UUID `8c1dde8e-9c3a-40ae-b377-abf883e454a9`, **expires 2026-09-19** (re-sign/reinstall after that)
- covers the iPhone 17, has `get-task-allow` (needed for StikDebug JIT)

**Xcode manual signing does NOT work here** (tried): the profile is Xcode-managed so manual mode rejects it,
and a command-line `PROVISIONING_PROFILE_SPECIFIER` also hits targets that can't take profiles
(JailbreakInterposer, Swift packages). `App/CodeSigning.xcconfig` is back on Automatic.

**What works: re-sign the finished unsigned IPA yourself** (no new app ID needed):
```
W=~/Documents/iphone/InfernoPhone/out/signing; rm -rf $W; mkdir -p $W; cd $W
unzip -q ../InfernoPhone.ipa; APP=$(ls -d Payload/*.app)
PROF="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/8c1dde8e-9c3a-40ae-b377-abf883e454a9.mobileprovision"
cp "$PROF" "$APP/embedded.mobileprovision"
security cms -D -i "$PROF" > profile.plist
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' profile.plist > ent.plist
ID="Apple Development: sezzy718@icloud.com (3YX7M8FJKU)"
find "$APP" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' \) -exec codesign -f -s "$ID" {} \;
codesign -f -s "$ID" --entitlements ent.plist "$APP"
xcrun devicectl device install app --device 00008150-000431062E40C01C "$APP"
```
(The IPA's bundle ID must be `com.infernophone.9ll7add265.UTM`, which it is.)
The owner only has **StikDebug** (no iloader/SideStore for installing), so installing goes through
`devicectl` like above; StikDebug is only used to launch the app with JIT.

## Mac VM disk was deleted (on the owner's request, to free space)
`~/Documents/iphone/InfernoData/root` (the Mac iPhone VM's 32 GB sparse disk) is **gone**, so
`InfernoData/start_iphone.sh` won't boot until it's recreated. The same restored iOS 14 install lives on
as `out/iPhone11-iOS14.utm/Data/root.qcow2`. To get the Mac VM back (needs ~9 GB free):
```
/opt/homebrew/bin/qemu-img convert -O raw ~/Documents/iphone/InfernoPhone/out/iPhone11-iOS14.utm/Data/root.qcow2 ~/Documents/iphone/InfernoData/root
```

**IPA build note:** building the IPA from the command line while Xcode has `UTM.xcodeproj` open fails with
"input file ... was modified during the build" (both share one DerivedData folder). Use a separate
`-derivedDataPath`, e.g.:
```
xcodebuild archive -archivePath ../out/InfernoPhone -scheme iOS -sdk iphoneos -arch arm64 -configuration Release CODE_SIGNING_ALLOWED=NO -derivedDataPath ../out/DerivedData
```

## Disk space warning
The Mac's disk was completely full at one point (Xcode copied 8.9 GB of iPhone support files into
`~/Library/Developer/Xcode/iOS DeviceSupport`). ~10 GB free after cleanup. Check with `df -h ~` before
big builds. Keep: the Mac VM (`InfernoData/root`), the test VM package, Xcode's DeviceSupport.

---

## How the pairing file was made
```python
import socket, plistlib, struct, os
UDID = "00008150-000431062E40C01C"
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect("/var/run/usbmuxd")
body = plistlib.dumps({"MessageType": "ReadPairRecord", "PairRecordID": UDID,
                       "ClientVersionString": "infernophone", "ProgName": "infernophone"})
s.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, 1) + body)
length = struct.unpack("<IIII", s.recv(16))[0]; data = b""
while len(data) < length - 16: data += s.recv(length - 16 - len(data))
record = plistlib.loads(plistlib.loads(data)["PairRecordData"]); record["UDID"] = UDID
out = os.path.expanduser("~/Desktop/iPhone17.mobiledevicepairing")
open(out, "wb").write(plistlib.dumps(record)); os.chmod(out, 0o600)
```

## Later (not started)
Setup wizard (device/iOS/jailbreak picker), in-app downloads + background restore + "restore complete"
notification, Mac "carrier" console (custom numbers/texts/calls/admin messages), file explorer,
send-notification-to-VM, custom phone info (serial etc.), multi-VM.

---

## InfernoWin (Windows, for the owner's friend) — built 2026-09-13, never run on Windows yet
- `Windows/InfernoWin/`: WPF app (.NET 10), builds on the Mac via `EnableWindowsTargeting`.
  Package: `dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true`, then zip
  the exe + `Windows/wsl/` + `Windows/README.txt` → `out/InfernoWin-win-x64.zip`.
- `Windows/wsl/`: bash backend the app copies to `~/.infernowin/wsl` in WSL2 (Ubuntu):
  `install.sh` (guide's Linux build, nettle 3.10 if needed, x86_64 Debian "generic" companion with
  KVM when `/dev/kvm` exists), `setup_vm.sh` (same steps as InfernoMac), `start_vm.sh` (GTK window via
  WSLg, serial on stdio, QMP on 127.0.0.1:4450+), `companion.sh`.
- FS patches run **in the companion** with Debian's `apfs-dkms` (`mount -o vol=0,readwrite`).
  Verified on a cloned iPhone disk from the Mac companion: write works, macOS reads it back fine.
  **Gotcha:** the iPhone disk must be attached with `logical_block_size=4096` or Linux sees no GPT.
  macOS `fsck_apfs -n` always reports keybag errors on iOS containers — not a useful corruption check.
- Only iOS 14.0b5 has an engine; other SEP versions need `build-sepNN` (not scripted for Linux).

## iOS 18 status (2026-09-13)
- **18.0 (22A3354) doesn't restore**: the ramdisk aborts on "multi-touch update failed with code 0x1"
  (`update_aht_block_invoke`, idevicerestore log in the companion's home). Removed from the manifest.
- **18.5 (22F76) replaces it**, still experimental. Inferno's developer: "only iOS 18.5 booting" and it
  "still has many issues" (ChefKissInc/Inferno#241); iOS 17+ also hit the SPRR bug (#216, open).
  SEP keys came from The Apple Wiki API (`api.php?...prop=revisions`); the raw page is behind a bot check.
- iOS 16+ IPSWs ship the OS as `.dmg.aea` (6.4 GB for 18.5); the precache now handles it. The companion
  disk was grown to 24 GB for this (qemu-img resize +16G; cloud-init grew the partition on boot).

## Carrier (simulated, Messages app)
Real baseband: iOS loads the Intel modem driver on `build-bb` but stops after one BAR1 read — not
feasible. Simulated instead: `MessagesDelivery` inserts into `sms.db` over the serial root shell.
iOS's sandbox refuses the SMS folder even to root, so a sqlite3 re-signed on the Mac with
`com.apple.private.security.storage.SMS` (in `InfernoData/carrier/`, served by the companion on
`192.168.178.1:8088`) is installed by the Jailbreak tab's **Set Up Carrier**. Waiting on its first run.
A modem boot also needs `/System/Library/Caches/com.apple.factorydata` (created on the current VM).

# InfernoPhone — Core iOS App (Sub-project 1) Design

Date: 2026-09-13
Status: Approved in chat, pending written-spec review
Working name: InfernoPhone (rename freely)

## Goal

A sideloaded iOS app that sets up and runs ChefKiss Inferno iPhone VMs directly on an iPhone. The user picks a
device, an iOS version, and jailbroken or not. The app downloads and prepares everything, restores in the
background, notifies on completion, and runs the VM with an easy switch between the VM screen and a live terminal.

## Scope

In scope (this spec): the core app — VM engine, built-in companion, setup pipeline, Mac helper (disk patching
only), app UI.

Out of scope (later sub-projects, each with its own spec):
- 2. Emulated cellular: the Mac as a carrier, custom phone numbers, texts and calls between VMs, admin messages.
- 3. In-VM tools: file explorer, send custom notification, custom phone info (serial number etc.).
- 4. Multi-VM: running more than one VM at a time. (The on-disk layout is already per-VM so this is additive.)
- Mac-free disk patching (replaces the Mac Helper once a spike proves in-app APFS patching works).

## Constraints and environment

- User: single user, personal use. Host device: iPhone 17 (iPhone18,3), iOS 27.0 (24A5430a), Developer Mode on,
  256 GB (~68 GB free now). Mac: Apple Silicon, macOS 27.
- Distribution: sideloaded with a **free Apple ID**. Consequences: the app must be re-signed every 7 days
  (SideStore refresh is fine); the increased-memory-limit entitlement is most likely unavailable, so the
  guest RAM must fit inside the default app memory limit (target 2 GB guest, verify on device in milestone 1).
- JIT: enabled through StikDebug (already on the device). The app never runs the VM without JIT.
- Inferno builds on macOS 27 only with `--disable-pvg` and `CONFIG_VMAPPLE=n` (macOS 27 SDK removed
  ParavirtualizedGraphics APIs). The iOS build must disable the same.
- Licensing: UTM (Apache 2.0) + Inferno (GPLv3/AGPLv3). The combined app is GPL/AGPL; acceptable for personal use.
- Firmware: IPSWs are fetched from Apple's CDN on the user's request. The Inferno guide asks that firmware
  download/patching not be automated (EULA). The user has accepted this for personal use; the app is not published.

## Supported devices and versions

Driven by a **support manifest** (JSON, bundled in the app, updatable by replacing the file). One entry per
device + iOS build. The wizard only lists entries with `status: "tested"`; `experimental` entries are hidden
unless a debug toggle is on. Target coverage: iPhone 11 (t8030) iOS 14–18 and iPhone 6s (s8000).

Each entry carries everything the pipeline needs:
- `device` (e.g. `iPhone12,1`), `board` (`n104ap`), `soc` (`t8030`), `machine` (`t8030`)
- `ios`, `build`, `ipsw_url`, `ipsw_size`, `ipsw_sha1` (from Apple's catalog)
- `sep_fw_path`, `sep_iv`, `sep_key`, `sep_rom` (file name + download URL + sha256)
- `sep_version_override` (Inferno SEP build flag: 14/15/16/17/18) — see Engine below
- `trustcache`, `kernelcache`, `devicetree`, `ramdisk_erase` paths inside the IPSW
- `boot_args`, `guest_ram_mb`, `smp`
- `jailbreak`: `{ bootstrap: bool, package_manager: "sileo"|"zebra"|null, tweaks: "tested"|"untested"|"broken" }`
- `status`: `tested` | `experimental`

The first entry is the configuration proven on the Mac: iPhone12,1, iOS 14.0 (18A5351d), SEP ROM Cebu B1,
SEP key/IV from The Apple Wiki, `sep_version_override: 14`.

## Architecture

Five units, each with one job and a narrow interface.

### 1. VM Engine
Inferno's QEMU (`qemu-system-aarch64`, target aarch64-softmmu only) built as an iOS framework using UTM's iOS
build scripts and dependency set, with UTM's JIT mechanism (TCG + JIT memory via the debugger-attached path
that StikDebug provides).

- SEP version override: Inferno picks the SEP bypass at compile time (`SEP_USE_VERSION_OVERRIDE` in
  `hw/arm/apple-silicon/sep.c`). The engine turns this into a runtime machine property (`sep-version=N`) with a
  small Inferno patch, so one app binary supports every iOS version. Fallback if the patch is impractical:
  ship one engine build per SEP version.
- Interface to the rest of the app: `start(config)`, `stop()`, a framebuffer/display surface (UTM's display
  path), a serial byte stream (terminal), button injection (Inferno maps F1–F10 to device buttons), and a
  USB endpoint exposed as a local UNIX socket (Inferno `usb-conn-type=unix`).

### 2. Built-in Companion
Replaces the Linux companion VM. Compiled into the app: `libplist`, `libimobiledevice-glue`, `libusbmuxd`,
`libtatsu`, `libimobiledevice`, `libirecovery`, `usbmuxd`, `idevicerestore` (+ the guide's
`idevicerestore.patch`).

- Needs a USB-device side that speaks Inferno's `usb-tcp-remote` protocol: a small in-app shim implements the
  host end of that socket and presents the device to the embedded `usbmuxd`/libirecovery through a custom
  transport instead of libusb. This shim is the riskiest companion component and is spiked first.
- Restore: runs `idevicerestore --erase --restore-mode -i <ECID> -T root_ticket.der`, with the OS image
  pre-extracted into its cache directory (the restore ramdisk only waits 120 s, extraction takes longer).
- Networking (reverse tethering): once booted, the guest exposes CDC-NCM over the same USB link. The companion
  handles that interface with a userspace network stack (slirp, already a QEMU dependency) giving DHCP +
  DNS + NAT, so the guest gets internet without any host network configuration. (Mac lesson: dnsmasq needed
  explicit upstream DNS; slirp provides DNS directly.)

### 3. Setup Pipeline
A resumable sequence of steps, each idempotent, recording completion in the VM's `state.json`:

1. `check_space` — refuse if free space < 15 GB (IPSW + extracted image + root growth).
2. `download_ipsw` — resumable HTTP range download from Apple's CDN; verify size + SHA1.
3. `download_sep_rom` — from the manifest URL; verify sha256.
4. `extract` — unzip needed files from the IPSW (skip the main OS dmg into the VM folder; extract it into the
   companion cache instead for the restore).
5. `make_tickets` — port of `create_apticket.py` / `create_septicket.py` (pyasn1 DER) to Swift or bundled C.
6. `repack_sep` — port of the img4lib steps: decrypt `sep-firmware.*.im4p` with manifest IV+key, repackage with
   the SEP ticket (`rsep`), assert the version tag output is `none`.
7. `create_disks` — sparse raw files: root 32G, firmware 8M, syscfg 128K, ctrl_bits 8K, nvram 8K,
   effaceable 4K, panic_log 1M, sep_nvram 64K, sep_ssc 128K.
8. `restore` — boot the engine with the erase ramdisk, trigger the companion restore, wait for "Restore
   Finished" and the VM self-exit.
9. `patch_fs` — v1: hand off to the Mac Helper (see below). Later: in-app.
10. `ready`.

Background: from step 2 onward the pipeline runs inside a `BGContinuedProcessingTask` (iOS 26+) so the user can
leave the app; the system shows progress. Downloads use a background `URLSession` as well, so they survive
suspension. While the app is foregrounded and downloading, `isIdleTimerDisabled = true` (no auto-lock).
A local notification fires on restore complete and on failure.

### 4. Mac Helper (v1 only for disk patching)
A small macOS app/CLI. Connects to the phone over USB and copies the VM's `root` image out of, and back into,
the app's Documents container via AFC (`house_arrest`, libimobiledevice). The app sets `UIFileSharingEnabled`
and `LSSupportsOpeningDocumentsInPlace`, which a free-account sideloaded app is allowed to use.

Performs exactly the guide's filesystem patches on the `root` image:
- `hdiutil attach` raw image, `diskutil enableownership`, `mount -urw`
- `InfernoFSPatcher` on the dyld shared cache (and `--unredact-logs` optional)
- disable `com.apple.voicemail.vmd`, `com.apple.CommCenter`, `com.apple.CommCenterMobileHelper`,
  `com.apple.CommCenterRootHelper`, `com.apple.locationd` in `launchd.plist` (plistlib, no hand edits)
- if jailbroken: extract the checkra1n core bootstrap into the System volume, add the `com.apple.bash`
  launch daemon, install the package manager, and record that the boot args need
  `launchd_unsecure_cache=1`
- eject, send the image back, tell the app to mark `patch_fs` done.

Copying a ~10 GB image each way over USB is slow but acceptable for v1. The Mac Helper will later grow into
the carrier console (sub-project 2).

### 5. App UI (SwiftUI)
- **Home:** list of VMs (empty on first launch) + "+" button. Nothing starts automatically.
- **Wizard:** device (tested only) → iOS version (tested only) → Jailbroken toggle (with the tier note:
  bootstrap guaranteed, package manager planned, tweaks per manifest) → Start.
- **Setup progress:** step list with progress, "keep awake" active during downloads, "You can leave the app now"
  once restore starts.
- **VM view:** top segmented control **VM | Terminal** — always one tap to switch; the VM keeps running in both.
  VM tab shows the display (touch mapped to the guest touchscreen) and an overlay with Power, Home, Vol+, Vol−,
  Ringer, and the SOS gesture. Terminal tab shows the live serial log (search, copy, auto-scroll toggle) and,
  if jailbroken, an input line wired to the serial bash.

## On-disk layout

```
Documents/VMs/<uuid>/
  vm.json          # manifest entry chosen + user options
  state.json       # pipeline progress
  ipsw/            # deleted after restore to save space
  Restore/         # extracted boot files (kernelcache, devicetree, trustcache, ramdisks)
  disks/           # root, firmware, syscfg, ctrl_bits, nvram, effaceable, panic_log, sep_nvram, sep_ssc
  tickets/         # root_ticket.der, sep_root_ticket.der, sep-firmware.*.new.img4, SEP ROM
  logs/            # serial logs, crash logs (panic text extracted)
```

## Error handling

- App killed / phone reboots: pipeline resumes from the last completed step (state.json).
- Interrupted download: resumes via HTTP range; files verified against manifest size/checksum.
- No JIT: blocking screen explaining to open StikDebug; the engine is never started without JIT.
- Guest kernel panic: save the log to `logs/`, extract the `panic(...)` line. Known transient panics
  (`SEP Panic: :sars/sars`, `t8020dart invalid lock state`) get a one-tap "Restart VM" (maintainer guidance:
  restart, no rebuild).
- Insufficient storage: checked before start and before restore.
- Restore ramdisk timeout (120 s): avoided by pre-extracting the OS image before booting the ramdisk.

## Guest-side warnings shown in the app
Do not set a passcode, do not enable Location Services, never use "Erase All Content and Settings" (from the
Inferno guide).

## Testing

- Unit tests for pure pipeline steps (ticket creation, SEP repack, manifest parsing, disk creation) using the
  real files already produced on the Mac as fixtures (`~/Documents/iphone/InfernoData`).
- Milestone 1 (engine proof): boot the existing, already-restored iOS 14 VM copied from the Mac inside the app on
  the iPhone 17 with JIT. Measures boot time and memory use.
- Milestone 2 (companion proof): in-app restore of iOS 14 end to end on the phone.
- Milestone 3: full wizard flow + Mac Helper patching + boot + networking.
- Each manifest entry is promoted to `tested` only after a full on-device run.

## Risks (ordered) and how we de-risk them

1. Inferno's QEMU fork building with UTM's iOS toolchain — spike first, before any UI work.
2. Guest RAM within a free-account app's memory limit — measured in milestone 1.
3. In-app `usb-tcp-remote` ↔ usbmuxd shim — spiked before milestone 2.
4. TCG+JIT performance on A19 for Inferno's t8030 — measured in milestone 1.
5. BGContinuedProcessingTask time limits for a multi-hour restore — measured in milestone 2; fallback is
   "keep the app open" with keep-awake.

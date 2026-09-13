# iPhone-VM

An emulated iPhone on your computer, with a real app around it: pick a device and iOS version, let it download,
restore and patch everything, then run the phone in a window with a terminal, file browser, save states and more.

It's a front end for **[ChefKiss Inferno](https://github.com/ChefKissInc/Inferno)**, the QEMU-based iPhone emulator.
All the hard emulation work is theirs. This project automates the setup their
[guide](https://chefkiss.dev/guides/inferno/) walks through and adds tools on top.

> [!WARNING]
> **Experimental.** This is a hobby project that has only been tested on one Mac. The Windows versions have not
> been run on real Windows yet. Expect things to break, keep backups, and don't use it for anything important.

## What's here

| | Platform | Status |
|---|---|---|
| **InfernoMac** (`Mac/`) | macOS on Apple Silicon | Works on the author's Mac with iPhone 11 / iOS 14.0 beta 5 |
| **InfernoWin** (`Windows/InfernoWin`, `Windows/wsl`) | Windows 10/11 with WSL2 | Builds; never run on Windows |
| **iphone-vm** (`Linux/`) | Linux (Debian/Ubuntu, x86_64 or arm64) | Command-line tool; tested on Debian, full install not yet run |
| **Native Windows build** (`Windows/ci`) | Windows without WSL | Inferno compiles for Windows (MSYS2); only a smoke test so far |

## Features (InfernoMac)

- New VM wizard: device, iOS version, optional jailbreak. Downloads the firmware from Apple, restores, and patches it,
  with a notification when it's done. It resumes if interrupted.
- The phone screen in its own window, plus device buttons (Power, Home, Volume, Ringer).
- An interactive **Console** into the jailbroken VM's root shell (arrows, Tab, Ctrl-C), plus a searchable log.
- **Save states:** instant APFS snapshots of a stopped VM that you can roll back to.
- **Files** browser, **Phone Info** (serial number, model, region), several VMs at once.
- **Jailbreak tools:** make the system writable, install Zebra or Sileo, respring, **sideload any .ipa**.
- **Internet** for the VM through the companion VM (USB reverse tethering), with a Trust prompt button.
- **Carrier console (simulated):** phone numbers per VM and texts delivered into the real Messages app. In progress.

## Supported versions

| Device | iOS | Status |
|---|---|---|
| iPhone 11 | 14.0 beta 5 (18A5351d) | tested |
| iPhone 11 | 15.0, 16.0, 17.0, 18.5 | experimental (Inferno's developers report 18.5 boots with many issues) |
| iPhone 6s Plus | 14.0, 15.0 | experimental |

## Install

### macOS (Apple Silicon)

1. Install [Homebrew](https://brew.sh) and Apple's command line tools (`xcode-select --install`).
2. Download **InfernoMac** from [Releases](../../releases), unzip it, and move it to Applications.
3. The app isn't notarized: right-click it and choose **Open** the first time, or run
   `xattr -dr com.apple.quarantine /Applications/InfernoMac.app`.
4. On first launch, **Set Up Inferno** builds the emulator and companion VM (20–40 minutes, about 20 GB).
5. Press **+** to create a VM.

### Windows

Download **InfernoWin** from [Releases](../../releases) and follow the `README.txt` inside. It needs WSL2 with Ubuntu.

### Linux

Download **iphone-vm-linux.tar.gz** from [Releases](../../releases), or use `Linux/iphone-vm` from a clone:

```
./iphone-vm install        # builds Inferno + the companion VM (asks for sudo)
./iphone-vm new iPhone12,1-18A5351d --jailbreak
./iphone-vm setup <id>     # downloads iOS from Apple, restores, patches
./iphone-vm start <id>
```

Run `./iphone-vm help` for all commands (buttons, trust prompt, snapshots…). It uses the same backend scripts as
InfernoWin.

**Headless / hosting:** `./iphone-vm web 8080 --host 0.0.0.0 --token SECRET` serves a browser UI where you install,
create, set up and run VMs, use the console and see the phone screen (noVNC: `sudo apt install novnc websockify`).
Always set a token when binding to `0.0.0.0`. The CLI and web UI share the same VMs.

### Speed

Inferno emulates the iPhone entirely in software on every platform (no hypervisor), so expect a slow phone on any
machine. Only the companion VM uses hardware acceleration (Apple's Hypervisor on the Mac, KVM on Linux, WSL2 on
Windows). How a PC compares to an Apple Silicon Mac hasn't been measured yet.

## Build from source

- Mac: `cd Mac && xcodegen generate && xcodebuild -scheme InfernoMac -skipPackagePluginValidation build`
- Windows: `cd Windows/InfernoWin && dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true`
  (this builds on macOS too)

## Credits

This project stands on other people's work:

- **[ChefKiss Inferno](https://github.com/ChefKissInc/Inferno)** by ChefKissInc and contributors: the iPhone
  emulator itself, and its [setup guide](https://chefkiss.dev/guides/inferno/). GPL-2.0.
- **[QEMU](https://www.qemu.org)**, which Inferno is built on. GPL-2.0.
- **[InfernoFSPatcher](https://git.chefkiss.dev/AppleHax/InfernoFSPatcher)** (ChefKiss): the dyld cache patches. AGPL-3.0.
- **[libimobiledevice](https://libimobiledevice.org)** (usbmuxd, idevicerestore and friends): restoring and talking to the VM.
- **[img4lib](https://github.com/xerub/img4lib)** by xerub: repacking the Secure Enclave firmware.
- The ticket scripts and `ticket.shsh2` from the Inferno guide.
- **[checkra1n](https://checkra.in)**'s bootstrap and **Elucubratus** by Sam Bingner: the jailbreak userland.
- **[Zebra](https://getzbra.com)** and **[Sileo](https://getsileo.app)**: package managers.
- **[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)** by Miguel de Icaza: the Mac console.
- **[The Apple Wiki](https://theapplewiki.com)** (firmware keys) and **[securerom.fun](https://securerom.fun)** (SEP ROM dumps).
- **Debian** cloud images for the companion VM, and **MSYS2** for the Windows build.

## Legal

This project is not affiliated with Apple or ChefKiss. iOS firmware is downloaded from Apple's own servers when you
set up a VM, and no iOS images are stored here. By using Apple's software you agree to Apple's license terms, and
you are responsible for how you use this. It is meant for personal, educational and research use.

This project's own code is MIT-licensed (see [LICENSE](LICENSE)). The components listed above keep their own
licenses. The Windows build of Inferno is GPL-2.0, and its source is at
[UltraFEmotes/Inferno](https://github.com/UltraFEmotes/Inferno/tree/windows-build).

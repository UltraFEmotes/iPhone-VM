# Third-party notices

The MIT license in [LICENSE](LICENSE) covers this repository's own code only. The components below are used by
iPhone-VM and keep their own licenses. Most are downloaded or built during setup rather than stored here.

| Component | Used for | License |
|---|---|---|
| [ChefKiss Inferno](https://github.com/ChefKissInc/Inferno) | The iPhone emulator (built from source during setup) | GPL-2.0 |
| [QEMU](https://www.qemu.org) | Inferno's base, and the companion VM | GPL-2.0 |
| Inferno for Windows (`InfernoNativeTest.zip` release asset) | Native Windows emulator build | GPL-2.0, source at [UltraFEmotes/Inferno @ windows-build](https://github.com/UltraFEmotes/Inferno/tree/windows-build) |
| [InfernoFSPatcher](https://git.chefkiss.dev/AppleHax/InfernoFSPatcher) | dyld shared cache patches | AGPL-3.0 |
| [libimobiledevice](https://libimobiledevice.org), usbmuxd, idevicerestore | Restoring and talking to the VM (built in the companion VM) | LGPL-2.1 / GPL-2.0 |
| [img4lib](https://github.com/xerub/img4lib) | Secure Enclave firmware repacking | MIT |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | The Mac console | MIT |
| Ticket scripts and `ticket.shsh2` (`Windows/wsl/tools/`) | Boot tickets, from the [Inferno guide](https://chefkiss.dev/guides/inferno/) | per their authors |
| [checkra1n](https://checkra.in) bootstrap, [Elucubratus](https://apt.bingner.com) | Jailbreak userland (downloaded during setup) | per their authors |
| [Debian](https://www.debian.org) cloud images | Companion VM | Debian's licenses |

iOS firmware is Apple's software. It is downloaded from Apple's servers during setup and is not part of this repository.

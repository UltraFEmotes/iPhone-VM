iphone-vm for Linux: an emulated iPhone, powered by ChefKiss Inferno
=====================================================================

EXPERIMENTAL. The command-line and browser workflows have been smoke-tested on Debian (arm64). The full distro,
hardware and real-VM boot matrix has not been verified yet. Please report what happens.

Needs
-----
- Arch, Debian 12+/Ubuntu 22.04+, Fedora/RHEL/Rocky/Alma, openSUSE, Alpine, Gentoo or Void.
  'install' picks the package manager (pacman, apt, dnf, zypper, apk, emerge, xbps) and, if one of its
  package names does not exist on your release, says which it skipped instead of stopping.
- x86_64 or arm64, a desktop session (the phone opens in a GTK window) and sudo
- /dev/kvm makes the companion VM fast, so be in the "kvm" group: sudo usermod -aG kvm $USER, then log back in
  (the iPhone itself is always software-emulated, so it's slow everywhere)
- About 40 GB free, and a few hours for the first setup

Per-distro notes
----------------
Arch:    no AUR helper needed. lzfse isn't packaged, so install builds it from source into /usr/local
         (static, the same source the AUR package uses). Packages are installed without -Sy, because
         syncing without a full upgrade is how Arch installs break - if a download fails, your sync
         database is stale: run 'sudo pacman -Syu' and start install again.
Fedora,
openSUSE: lzfse is packaged (lzfse-devel), so it is used as-is. On RHEL and the rebuilds it isn't, and
         install builds it from source like on Arch.
Alpine:   musl, and the busybox tools lack GNU options these scripts need, so install also pulls in
         bash, coreutils, GNU grep/sed/findutils and procps-ng. The least tested of the lot.
Gentoo:   emerge --noreplace, so anything already installed is left alone; expect a long compile.

The USB link between the phone and the companion runs over TCP on 127.0.0.1:7250. It used to use a unix
socket (/tmp/InfernoUSBRemote), but bulk transfers stall there and the restore dies partway through ASR
with the phone receiving nothing. INFERNO_USB_TCP=0 goes back to the unix socket, or set it to another
port. A running companion keeps the link it started with, so stop it before changing this.

Quick start
-----------
    tar xzf iphone-vm-linux.tar.gz && cd iphone-vm
    ./iphone-vm install                 # builds Inferno + the companion VM (20-60 min, asks for sudo)
    ./iphone-vm versions                # what you can create
    ./iphone-vm new iPhone12,1-18A5351d --jailbreak
    ./iphone-vm config <id> --graphics smooth --performance fast --audio stable
    ./iphone-vm setup <id>              # downloads iOS from Apple, restores and patches it
    ./iphone-vm start <id>              # this terminal becomes the phone's serial console

Commands
--------
    install [--all-engines]    one-time setup (--all-engines: also build the iOS 15-18 emulators, +1 hour)
    versions [--all]           supported devices/iOS versions (--all includes experimental ones)
    new <version> [--name N] [--jailbreak]
    config <vm> [--graphics default|smooth|fast-half] [--performance balanced|fast|low-memory] [--audio stable|aop|disabled]
    list                       your VMs
    setup <vm>                 resumes where it stopped if interrupted
    start <vm> / stop <vm>
    press <vm> power|home|volup|voldown|ringer [hold-ms]
    trust <vm>                 "Trust This Computer?" prompt, needed once for the phone's internet
    snapshot <vm> save|restore|delete <name>   /   snapshot <vm> list
    companion start|stop|status
    delete <vm> [--yes]

<vm> is a VM's name or the start of its ID. Data lives in ~/.local/share/iphone-vm (set INFERNO_DATA to change it).

The profiles are experimental and apply on the next start. Smooth Full-Res keeps the native 828x1792 framebuffer,
Fast Half-Res uses 414x896 to reduce display-copy work, Fast TCG enlarges the translation cache, and AOP audio
enables the speaker-only AOP path when the Linux QEMU build exposes it. Stable audio uses the first available host
backend (PipeWire, PulseAudio, ALSA, SDL or OSS).

Inside a jailbroken VM the console is a root shell: try  mount -uw /  then apt.

When a restore gets stuck
-------------------------
During 'setup' the phone's own console is printed with a [phone] prefix and the companion's with
[companion], and a heartbeat reports how many MB the phone actually wrote each minute. idevicerestore
reaching 100% only means the image was sent; the phone writes and verifies it afterwards. Judge it by
the heartbeat, not the percentage:

    wrote N MB this minute        working
    wrote NOTHING, cpu climbing   verifying (no disk writes in this phase) - let it run
    wrote NOTHING for 5+ minutes  stalled; the note in the log says so. Ctrl-C and run setup again.

The restore step is not resumable, so a stalled attempt means redoing the whole transfer. If it stalls,
check that the USB link is on TCP (it is by default; see above) - over the unix socket it stalls almost
every time. The phone screen is shown during the restore too, so you can watch the progress bar
(INFERNO_DISPLAY=none turns it off; headless machines get nothing anyway).

Finished steps are remembered in <vm>/steps.done, so a failure in a later step (like 'patch') only
repeats that step, not the hours-long restore.

Headless / hosting (browser UI)
-------------------------------
    ./iphone-vm web 8080                          # local only: http://localhost:8080
    ./iphone-vm web 8080 --host 0.0.0.0 --token SECRET   # reachable on your network

Then open http://<server>:8080/?token=SECRET in any browser to install, create, set up and run VMs, use
the console, and see the phone screen. Everything (install, new, setup, start) also works from the command
line above — the web UI and CLI share the same VMs.

The phone screen in the browser needs noVNC and websockify (Arch, from the AUR: yay -S novnc
python-websockify; Debian/Ubuntu: sudo apt install novnc websockify)
Without a token, --host 0.0.0.0 lets anyone on the network control your VMs, so always set one for hosting.
The screen uses one extra port per running VM starting at 6080 (set INFERNO_VNC_WEB_BASE to change), which
must also be reachable; the web UI links to them automatically.

Credits and licenses: see README.md and THIRD_PARTY_NOTICES.md in the repository.
https://github.com/UltraFEmotes/iPhone-VM

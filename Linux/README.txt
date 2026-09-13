iphone-vm for Linux: an emulated iPhone, powered by ChefKiss Inferno
=====================================================================

EXPERIMENTAL. The command-line tool has been tested on Debian (arm64). The full install, setup and boot haven't
been run end-to-end on Linux yet. Please report what happens.

Needs
-----
- Debian 12+ or Ubuntu 22.04+ (other distros: install the packages from the Inferno guide by hand)
- x86_64 or arm64, a desktop session (the phone opens in a GTK window) and sudo
- /dev/kvm makes the companion VM fast (the iPhone itself is always software-emulated, so it's slow everywhere)
- About 40 GB free, and a few hours for the first setup

Quick start
-----------
    tar xzf iphone-vm-linux.tar.gz && cd iphone-vm
    ./iphone-vm install                 # builds Inferno + the companion VM (20-60 min, asks for sudo)
    ./iphone-vm versions                # what you can create
    ./iphone-vm new iPhone12,1-18A5351d --jailbreak
    ./iphone-vm setup <id>              # downloads iOS from Apple, restores and patches it
    ./iphone-vm start <id>              # this terminal becomes the phone's serial console

Commands
--------
    install [--all-engines]    one-time setup (--all-engines: also build the iOS 15-18 emulators, +1 hour)
    versions [--all]           supported devices/iOS versions (--all includes experimental ones)
    new <version> [--name N] [--jailbreak]
    list                       your VMs
    setup <vm>                 resumes where it stopped if interrupted
    start <vm> / stop <vm>
    press <vm> power|home|volup|voldown|ringer [hold-ms]
    trust <vm>                 "Trust This Computer?" prompt, needed once for the phone's internet
    snapshot <vm> save|restore|delete <name>   /   snapshot <vm> list
    companion start|stop|status
    delete <vm> [--yes]

<vm> is a VM's name or the start of its ID. Data lives in ~/.local/share/iphone-vm (set INFERNO_DATA to change it).

Inside a jailbroken VM the console is a root shell: try  mount -uw /  then apt.

Headless / hosting (browser UI)
-------------------------------
    ./iphone-vm web 8080                          # local only: http://localhost:8080
    ./iphone-vm web 8080 --host 0.0.0.0 --token SECRET   # reachable on your network

Then open http://<server>:8080/?token=SECRET in any browser to install, create, set up and run VMs, use
the console, and see the phone screen. Everything (install, new, setup, start) also works from the command
line above — the web UI and CLI share the same VMs.

The phone screen in the browser needs noVNC:  sudo apt install novnc websockify
Without a token, --host 0.0.0.0 lets anyone on the network control your VMs, so always set one for hosting.
The screen uses one extra port per running VM starting at 6080 (set INFERNO_VNC_WEB_BASE to change), which
must also be reachable; the web UI links to them automatically.

Credits and licenses: see README.md and THIRD_PARTY_NOTICES.md in the repository.
https://github.com/UltraFEmotes/iPhone-VM

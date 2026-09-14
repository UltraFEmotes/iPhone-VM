# Shared settings for the Linux/WSL2 backend (Arch and Debian/Ubuntu hosts). Sourced by the other scripts.
# The Windows app runs these through wsl.exe and reads these lines from their output:
#   STEP:<name>   a step started        SKIP:<name>   step already done (resumed setup)
#   PROGRESS:<n>  percent of the step   FAIL:<text>   stopped with an error
#   DONE          everything finished

DATA="${INFERNO_DATA:-$HOME/InfernoData}"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$DATA/Inferno/build"
QEMU_ARM="$ENGINE_DIR/qemu-system-aarch64"
QEMU_X86="$ENGINE_DIR/qemu-system-x86_64"
QEMU_IMG="$ENGINE_DIR/qemu-img"
CSSH=(ssh -i "$DATA/companion_key" -p 32222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o LogLevel=ERROR -o ServerAliveInterval=30 -o ConnectTimeout=8 inferno@localhost)

# nettle 3.10 and lzfse may be built into /usr/local (Ubuntu's nettle is older; Arch has no lzfse package).
export PKG_CONFIG_PATH="/usr/local/lib64/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# Which package manager installs the build dependencies: pacman (Arch), apt (Debian/Ubuntu, including
# WSL2), or "" when this host uses something else and the packages have to be installed by hand.
pkg_kind() {
    local id="" like=""
    if [ -r /etc/os-release ]; then
        id=$(. /etc/os-release && echo "${ID:-}")
        like=$(. /etc/os-release && echo "${ID_LIKE:-}")
    fi
    case " $id $like " in
        *" arch "*|*" archlinux "*) echo pacman; return ;;
        *" debian "*|*" ubuntu "*) echo apt; return ;;
        *" fedora "*|*" rhel "*|*" centos "*) echo dnf; return ;;
        *" suse "*|*" opensuse "*) echo zypper; return ;;
        *" alpine "*) echo apk; return ;;
        *" gentoo "*) echo emerge; return ;;
        *" void "*) echo xbps; return ;;
    esac
    local c
    for c in pacman apt-get dnf zypper apk emerge xbps-install; do
        if command -v "$c" >/dev/null 2>&1; then
            case "$c" in
                apt-get) echo apt ;;
                xbps-install) echo xbps ;;
                *) echo "$c" ;;
            esac
            return
        fi
    done
    echo ""
}

# The phone<->companion USB link runs over TCP on 127.0.0.1. It used to use the unix socket
# (/tmp/InfernoUSBRemote), but bulk transfers stall there: the restore dies partway through ASR with the
# phone silently receiving nothing. INFERNO_USB_TCP=0 goes back to the unix socket, or set it to a port.
# Prints the port when TCP is in use and nothing when it is not, so both VMs agree on one setting.
usb_tcp_port() {
    case "${INFERNO_USB_TCP:-1}" in
        0|no|false|unix) echo "" ;;
        1|yes|true) echo 7250 ;;
        *) echo "$INFERNO_USB_TCP" ;;
    esac
}

# How to install noVNC and websockify here (the web UI needs them to show the phone screen).
novnc_hint() {
    case "$(pkg_kind)" in
        pacman) echo "AUR: yay -S novnc python-websockify" ;;
        apt) echo "sudo apt install novnc websockify" ;;
        dnf) echo "sudo dnf install novnc python3-websockify" ;;
        zypper) echo "sudo zypper install novnc python3-websockify" ;;
        apk) echo "sudo apk add novnc py3-websockify" ;;
        emerge) echo "sudo emerge www-apps/novnc net-misc/websockify" ;;
        xbps) echo "sudo xbps-install novnc python3-websockify" ;;
        *) echo "install novnc and websockify" ;;
    esac
}

step() { echo "STEP:$1"; }
fail() { echo "FAIL:$*"; exit 1; }

# json <file> <dotted.key> — prints one value from a JSON file ("" when missing; booleans as true/false).
json() {
    python3 - "$1" "$2" <<'EOF'
import json, sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))
EOF
}

# The engine is built per Secure Enclave version; iOS 14 uses the default build.
engine_for() {
    local v="${1:-14}"
    if [ -z "$v" ] || [ "$v" = 14 ]; then echo "$QEMU_ARM"; else echo "$DATA/Inferno/build-sep$v/qemu-system-aarch64"; fi
}

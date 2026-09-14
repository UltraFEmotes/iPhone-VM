# Shared settings for the InfernoWin WSL2 backend. Sourced by the other scripts.
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

# nettle 3.10 may be built into /usr/local (Ubuntu ships an older one).
export PKG_CONFIG_PATH="/usr/local/lib64/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

step() { echo "STEP:$1"; }
fail() { echo "FAIL:$*"; exit 1; }

pkg_available() { apt-cache show "$1" >/dev/null 2>&1; }
apt_install() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}
apt_install_one_of() {
    local pkg
    for pkg in "$@"; do
        if pkg_available "$pkg"; then
            apt_install "$pkg"
            return 0
        fi
    done
    fail "none of these packages is available: $*"
}

# Pick a backend supported by the engine and the current Linux audio session.
qemu_audio_backend() {
    local qemu="$1" help backend
    help=$("$qemu" -audiodev help 2>&1 || true)
    for backend in pipewire pa alsa sdl oss; do
        if grep -Eq "(^|[[:space:],])$backend([[:space:],:]|$)" <<< "$help"; then
            echo "$backend"
            return 0
        fi
    done
}

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

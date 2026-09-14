#!/usr/bin/env bash
#
# pmoiu — PostmarketOS/Mobile Linux in Ubuntu/Debian/Fedora/Arch
# Fixed and updated for headless D-Bus, websockify, and package tolerance.

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
CONFIG_DIR="/etc/pmoiu"
CONFIG_FILE="$CONFIG_DIR/config"
PMOS_BIN="/usr/local/bin/pmos"
VNC_PORT=5900
NOVNC_PORT=6080
RDP_PORT=3389

# --------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "pmoiu needs root to install packages. Re-run as: sudo $0" >&2
        exit 1
    fi
}

as_user() {
    sudo -u "$REAL_USER" -H bash -c "$*"
}

choose() {
    local __resultvar=$1; shift
    local opt
    PS3="Choice: "
    select opt in "$@"; do
        if [[ -n "${opt:-}" ]]; then
            printf -v "$__resultvar" '%s' "$opt"
            break
        else
            echo "Invalid choice, try again."
        fi
    done
}

detect_pkgmgr() {
    if command -v apt-get &>/dev/null; then
        PKG_MGR=apt
    elif command -v dnf &>/dev/null; then
        PKG_MGR=dnf
    elif command -v pacman &>/dev/null; then
        PKG_MGR=pacman
    else
        echo "Unsupported package manager (needs apt, dnf, or pacman)." >&2
        exit 1
    fi
}

pkg_update() {
    case "$PKG_MGR" in
        apt)    apt-get update ;;
        dnf)    dnf makecache ;;
        pacman) pacman -Sy ;;
    esac
}

pkg_available() {
    case "$PKG_MGR" in
        apt)    apt-cache show "$1" &>/dev/null ;;
        dnf)    dnf info "$1" &>/dev/null ;;
        pacman) pacman -Si "$1" &>/dev/null ;;
    esac
}

pkg_install() {
    case "$PKG_MGR" in
        apt)    apt-get install -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        pacman) pacman -S --needed --noconfirm "$@" ;;
    esac
}

# Installs packages that exist, skipping unavailable optional ones gracefully
pkg_install_safe() {
    local valid_pkgs=()
    for pkg in "$@"; do
        if pkg_available "$pkg"; then
            valid_pkgs+=("$pkg")
        else
            echo "Note: Package '$pkg' not found in repos, skipping..."
        fi
    done
    if [[ ${#valid_pkgs[@]} -gt 0 ]]; then
        pkg_install "${valid_pkgs[@]}"
    fi
}

# --------------------------------------------------------------------
# 1. Setup & Environment Detection
# --------------------------------------------------------------------

require_root
detect_pkgmgr

echo "=== pmoiu — Setup Headless Mobile Shell ($PKG_MGR) ==="
echo
echo "Which mobile shell do you want?"
choose DESKTOP "phosh" "plasma-mobile"

echo
echo "Which remote-access interface do you want?"
choose INTERFACE "novnc" "kasmvnc" "rdp"

# --------------------------------------------------------------------
# 2. Compatibility Enforcement
# --------------------------------------------------------------------

if [[ "$INTERFACE" == "rdp" ]]; then
    if ! pkg_available krdp; then
        echo
        echo "NOTICE: 'krdp' is not available in your distro's repository (requires Plasma 6)."
        echo "Switching interface to 'novnc' (WayVNC + Websockify) which works out of the box."
        INTERFACE="novnc"
    fi
fi

if [[ "$DESKTOP" == "plasma-mobile" && "$INTERFACE" != "rdp" ]]; then
    echo
    echo "NOTICE: KWin (Plasma) does not natively support wlroots screencopy."
    echo "Phosh + noVNC is the most stable headless combination."
    choose FIX "Switch shell to phosh (Recommended)" "Keep plasma-mobile"
    if [[ "$FIX" =~ "phosh" ]]; then
        DESKTOP="phosh"
    fi
fi

echo
echo "Configuring: $DESKTOP + $INTERFACE"
echo

# --------------------------------------------------------------------
# 3. Base Dependencies & D-Bus Tools
# --------------------------------------------------------------------

pkg_update
# Core tools + D-Bus session wrappers + websockify for noVNC
pkg_install_safe curl wget gnupg openssl python3 dbus dbus-x11 dbus-user-session websockify novnc

# --------------------------------------------------------------------
# 4. Install Desktop Shell
# --------------------------------------------------------------------

case "$DESKTOP" in
    plasma-mobile)
        pkg_install_safe plasma-mobile kwin-wayland-backend-virtual kwin-wayland kwin
        ;;
    phosh)
        # squeekboard is optional; phosh + phoc is the core
        pkg_install_safe phosh phosh-core phoc squeekboard
        ;;
esac

# --------------------------------------------------------------------
# 5. Install Remote Interface
# --------------------------------------------------------------------

install_novnc() {
    pkg_install_safe wayvnc
    
    read -rsp "Set a password for VNC/noVNC (default: none): " VNC_PASS || true
    echo
    
    as_user "mkdir -p '$REAL_HOME/.config/wayvnc'"
    if [[ -n "$VNC_PASS" ]]; then
        as_user "cat > '$REAL_HOME/.config/wayvnc/config' <<CFG
address=0.0.0.0
enable_auth=true
username=$REAL_USER
password=$VNC_PASS
CFG"
    else
        as_user "cat > '$REAL_HOME/.config/wayvnc/config' <<CFG
address=0.0.0.0
enable_auth=false
CFG"
    fi
    as_user "chmod 600 '$REAL_HOME/.config/wayvnc/config'"
}

install_kasmvnc() {
    if ! command -v kasmvncserver &>/dev/null; then
        case "$PKG_MGR" in
            apt)
                local codename arch asset_url
                codename=$(lsb_release -cs 2>/dev/null || echo "jammy")
                arch=$(dpkg --print-architecture)
                asset_url=$(curl -fsSL https://api.github.com/repos/kasmtech/KasmVNC/releases/latest \
                    | grep -oP '"browser_download_url":\s*"\K[^"]*\.deb' \
                    | grep -i "$arch" | head -n1 || true)
                if [[ -n "$asset_url" ]]; then
                    wget -O /tmp/kasmvncserver.deb "$asset_url"
                    apt-get install -y /tmp/kasmvncserver.deb || true
                fi
                ;;
            *)
                echo "Please install KasmVNC manually for your distribution."
                ;;
        esac
    fi

    if command -v kasmvncpasswd &>/dev/null; then
        echo "Set the KasmVNC password for $REAL_USER:"
        sudo -u "$REAL_USER" -i kasmvncpasswd -u "$REAL_USER" || true
    fi
}

install_rdp() {
    pkg_install_safe krdp
    local krdp_dir="$REAL_HOME/.local/share/krdpserver"
    as_user "mkdir -p '$krdp_dir'"
    as_user "openssl req -nodes -new -x509 -keyout '$krdp_dir/krdp.key' -out '$krdp_dir/krdp.crt' -days 3650 -batch 2>/dev/null"
    if command -v kwriteconfig6 &>/dev/null; then
        as_user "kwriteconfig6 --file krdpserverrc --group General --key Certificate '$krdp_dir/krdp.crt'"
        as_user "kwriteconfig6 --file krdpserverrc --group General --key CertificateKey '$krdp_dir/krdp.key'"
        as_user "kwriteconfig6 --file krdpserverrc --group General --key SystemUserEnabled true"
    fi
}

case "$INTERFACE" in
    novnc)   install_novnc ;;
    kasmvnc) install_kasmvnc ;;
    rdp)     install_rdp ;;
esac

# --------------------------------------------------------------------
# 6. Save Configuration
# --------------------------------------------------------------------

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
DESKTOP=$DESKTOP
INTERFACE=$INTERFACE
PMOS_USER=$REAL_USER
VNC_PORT=$VNC_PORT
NOVNC_PORT=$NOVNC_PORT
RDP_PORT=$RDP_PORT
EOF

# --------------------------------------------------------------------
# 7. Write `/usr/local/bin/pmos` Launcher
# --------------------------------------------------------------------

cat > "$PMOS_BIN" <<'PMOS_SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
source /etc/pmoiu/config

# Setup user runtime directory if missing (common over SSH)
if [[ -z "${XDG_RUNTIME_DIR:-}" || ! -d "$XDG_RUNTIME_DIR" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    if [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
        export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
        mkdir -p "$XDG_RUNTIME_DIR"
        chmod 0700 "$XDG_RUNTIME_DIR"
    fi
fi

PIDS=()
cleanup() {
    echo -e "\nStopping pmos session..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    exit 0
}
trap cleanup INT TERM

start_phosh() {
    export WLR_BACKENDS=headless
    export WLR_LIBINPUT_NO_DEVICES=1
    export WAYLAND_DISPLAY=wayland-pmos
    
    echo "Starting Phosh inside a D-Bus session..."
    dbus-run-session phoc -E phosh &
    PIDS+=($!)
    
    # Wait for Wayland socket
    local timeout=15
    while [[ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" && $timeout -gt 0 ]]; do
        sleep 1
        timeout=$((timeout - 1))
    done
    
    if [[ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
        echo "Error: phoc socket failed to initialize."
        cleanup
    fi
}

start_plasma_mobile() {
    export XDG_SESSION_TYPE=wayland
    export QT_QPA_PLATFORM=wayland
    export KWIN_WAYLAND_BACKEND=virtual
    export WAYLAND_DISPLAY=wayland-pmos

    echo "Starting Plasma Mobile virtual compositor..."
    if command -v kwin_wayland &>/dev/null; then
        dbus-run-session kwin_wayland --virtual --socket "$WAYLAND_DISPLAY" --exec startplasma-mobile &
        PIDS+=($!)
    else
        echo "Error: kwin_wayland binary not found."
        cleanup
    fi
    sleep 3
}

start_novnc() {
    echo "Starting wayvnc on Wayland display '$WAYLAND_DISPLAY'..."
    wayvnc -s "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" -C "$HOME/.config/wayvnc/config" 0.0.0.0 "$VNC_PORT" &
    PIDS+=($!)

    # Find noVNC web assets location
    local novnc_web=""
    for dir in "/usr/share/novnc" "/usr/share/novnc-core" "/usr/local/share/novnc"; do
        if [[ -d "$dir" ]]; then
            novnc_web="$dir"
            break
        fi
    done

    echo "Starting websockify bridge (Port $NOVNC_PORT -> $VNC_PORT)..."
    if [[ -n "$novnc_web" ]]; then
        websockify --web "$novnc_web" "$NOVNC_PORT" "127.0.0.1:$VNC_PORT" &
    else
        websockify "$NOVNC_PORT" "127.0.0.1:$VNC_PORT" &
    fi
    PIDS+=($!)

    IP=$(hostname -I | awk '{print $1}')
    echo "=========================================================="
    echo " Access UI in Browser: http://$IP:$NOVNC_PORT/vnc.html"
    echo " Or Direct VNC:        $IP:$VNC_PORT"
    echo "=========================================================="
}

start_kasmvnc() {
    echo "Starting KasmVNC..."
    kasmvncserver :1 -select-de manual &
    PIDS+=($!)
}

start_rdp() {
    echo "Starting krdpserver..."
    krdpserver &
    PIDS+=($!)
}

echo "=== Launching $DESKTOP with $INTERFACE ==="

case "$DESKTOP" in
    phosh)         start_phosh ;;
    plasma-mobile) start_plasma_mobile ;;
esac

case "$INTERFACE" in
    novnc)   start_novnc ;;
    kasmvnc) start_kasmvnc ;;
    rdp)     start_rdp ;;
esac

echo "Session active. Press [Ctrl+C] to exit."
wait
PMOS_SCRIPT

chmod +x "$PMOS_BIN"

echo
echo "=== Installation Finished ==="
echo "You can now run: pmos (no sudo needed)"

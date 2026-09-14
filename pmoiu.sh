#!/usr/bin/env bash
#
# pmoiu — Headless Mobile Shell Installer
# Tested on: Ubuntu 24.04 LTS, GitHub Codespaces, plain SSH
#
# Supported combinations on Ubuntu 24.04:
#
#   phosh + novnc
#     phoc (wlroots compositor, headless backend) +
#     wayvnc (attaches to wlroots screencopy) +
#     websockify + noVNC web client
#     → Works reliably. Recommended choice.
#
#   plasma-desktop + novnc  (X11 path, not "plasma-mobile")
#     Xvfb (fake framebuffer) + kwin_x11 + plasmashell +
#     x11vnc (captures the Xvfb framebuffer) +
#     websockify + noVNC web client
#     → Works on Ubuntu 24.04 without any PPA.
#     → "plasma-mobile" the package doesn't exist in Ubuntu 24.04
#       repos so we use standard Plasma desktop instead.
#
# What was removed and why:
#   squeekboard  — not packaged for Ubuntu (Fedora / postmarketOS only)
#   krdp         — requires Plasma 6; Ubuntu 24.04 ships Plasma 5
#   kasmvnc      — GitHub .deb may not match noble; left as manual option
#   wlroots VNC on KWin — KWin doesn't implement screencopy; broken
#
# Usage:  sudo ./pmoiu

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
CONFIG_DIR="/etc/pmoiu"
CONFIG_FILE="$CONFIG_DIR/config"
PMOS_BIN="/usr/local/bin/pmos"
VNC_PORT=5900
NOVNC_PORT=6080

# ────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────

die()        { echo "ERROR: $*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0"; }

as_user() {
    # Run a command as the non-root invoking user
    sudo -u "$REAL_USER" -H bash -c "$*"
}

choose() {
    # choose VARNAME "opt1" "opt2" ...
    local __var=$1; shift
    local opt
    PS3="Choice: "
    select opt in "$@"; do
        [[ -n "${opt:-}" ]] && { printf -v "$__var" '%s' "$opt"; break; }
        echo "Invalid selection, try again."
    done
}

apt_has() {
    # Returns 0 if apt knows about the package (even if not installed)
    apt-cache show "$1" &>/dev/null
}

apt_get() {
    # Hard install — dies on failure
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

apt_get_optional() {
    # Soft install — skips packages not found in repos, never dies
    local pkg ok=()
    for pkg in "$@"; do
        if apt_has "$pkg"; then
            ok+=("$pkg")
        else
            echo "  [skip] '$pkg' is not in the Ubuntu 24.04 repos — omitting"
        fi
    done
    if [[ ${#ok[@]} -gt 0 ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${ok[@]}"
    fi
}

# ────────────────────────────────────────────────────────────────────
# 0. Sanity checks
# ────────────────────────────────────────────────────────────────────

require_root

# This script is written specifically for apt/Ubuntu/Debian
if ! command -v apt-get &>/dev/null; then
    die "This script requires apt-get (Ubuntu / Debian). \
For Fedora use dnf; for Arch use pacman — see the comments at the top."
fi

UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "unknown")
echo "Detected Ubuntu $UBUNTU_VER"

# ────────────────────────────────────────────────────────────────────
# 1. Choose what to install
# ────────────────────────────────────────────────────────────────────

echo
echo "=== pmoiu — Headless Mobile Shell Installer ==="
echo
echo "Which mobile shell do you want?"
echo "  phosh         — Phosh/phoc (wlroots, native Wayland VNC, recommended)"
echo "  plasma-desktop — KDE Plasma via Xvfb+x11vnc (no krdp needed)"
echo
choose DESKTOP "phosh" "plasma-desktop"

echo
echo "Remote access interface:"
echo "  novnc — browser-based VNC client (works for both shells above)"
echo
# Only one real option but keep the select in case we extend later
choose INTERFACE "novnc"

echo
echo "Will install: $DESKTOP + $INTERFACE"
echo

# ────────────────────────────────────────────────────────────────────
# 2. VNC password
# ────────────────────────────────────────────────────────────────────

VNC_PASS=""
while true; do
    read -rsp "VNC password (min 6 chars, or press Enter for no auth): " VNC_PASS
    echo
    if [[ -z "$VNC_PASS" ]]; then
        echo "Warning: no password set — anyone who can reach the port can connect."
        break
    elif [[ ${#VNC_PASS} -ge 6 ]]; then
        break
    else
        echo "Password must be at least 6 characters, try again."
    fi
done

# ────────────────────────────────────────────────────────────────────
# 3. Refresh package lists
# ────────────────────────────────────────────────────────────────────

echo
echo "--- Updating package lists ---"
apt-get update -qq

# Enable universe repo (needed for phosh, phoc, wayvnc, etc.)
if ! grep -rq "^deb .*universe" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    echo "Enabling Ubuntu universe repository..."
    apt_get software-properties-common
    add-apt-repository -y universe
    apt-get update -qq
fi

# ────────────────────────────────────────────────────────────────────
# 4. Base dependencies always installed
# ────────────────────────────────────────────────────────────────────

echo
echo "--- Installing base dependencies ---"
apt_get \
    dbus \
    dbus-x11 \
    xauth \
    x11-utils \
    curl \
    wget \
    openssl \
    ca-certificates \
    python3 \
    lsb-release \
    iproute2

# websockify bridges WebSocket (browser) → raw TCP (VNC).
# python3 -m http.server does NOT do this — it only serves static files.
# Without websockify the noVNC page loads but can never connect.
apt_get websockify

# noVNC web assets (the browser-side JS/HTML VNC client)
apt_get novnc

# Confirm assets landed somewhere we can find them
NOVNC_DIR=""
for candidate in /usr/share/novnc /usr/share/novnc-core /usr/lib/novnc; do
    if [[ -f "$candidate/vnc.html" || -f "$candidate/vnc_lite.html" ]]; then
        NOVNC_DIR="$candidate"
        break
    fi
done

if [[ -z "$NOVNC_DIR" ]]; then
    echo "apt novnc package installed but web assets not found in expected"
    echo "locations. Downloading directly from GitHub as fallback..."
    NOVNC_DIR="/opt/novnc"
    mkdir -p "$NOVNC_DIR"
    NOVNC_TAG=$(curl -fsSL https://api.github.com/repos/novnc/noVNC/releases/latest \
                | grep -oP '"tag_name":\s*"\K[^"]+')
    wget -q --show-progress \
        "https://github.com/novnc/noVNC/archive/refs/tags/${NOVNC_TAG}.tar.gz" \
        -O /tmp/novnc.tar.gz
    tar -xzf /tmp/novnc.tar.gz -C "$NOVNC_DIR" --strip-components=1
    rm -f /tmp/novnc.tar.gz
fi

# Pick the right HTML entry point (package name differs between releases)
NOVNC_HTML=""
for f in "$NOVNC_DIR/vnc.html" "$NOVNC_DIR/vnc_lite.html"; do
    [[ -f "$f" ]] && { NOVNC_HTML="$f"; break; }
done
[[ -n "$NOVNC_HTML" ]] || die "noVNC HTML not found under $NOVNC_DIR"
echo "noVNC assets: $NOVNC_DIR (entry: $(basename "$NOVNC_HTML"))"

# ────────────────────────────────────────────────────────────────────
# 5. Install the chosen shell
# ────────────────────────────────────────────────────────────────────

echo
echo "--- Installing $DESKTOP ---"

case "$DESKTOP" in

    phosh)
        # phosh and phoc are in Ubuntu 24.04 universe.
        # squeekboard (on-screen keyboard) is NOT in Ubuntu — Fedora/
        # postmarketOS only. We skip it explicitly rather than failing.
        # The shell is fully usable via mouse/touchscreen without it;
        # for a headless VNC session a physical keyboard works fine.
        apt_get phosh phoc

        # Nice-to-have extras — all optional, failure is non-fatal
        apt_get_optional \
            fonts-cantarell \
            adwaita-icon-theme \
            gnome-themes-extra \
            gsettings-desktop-schemas \
            xdg-user-dirs

        echo
        echo "Note: squeekboard (on-screen keyboard) is not packaged for"
        echo "Ubuntu. Use a hardware keyboard or a VNC client with"
        echo "built-in keyboard support (e.g. RVNC Viewer, RealVNC)."
        ;;

    plasma-desktop)
        # krdp (KWin's built-in RDP server) needs Plasma 6. Ubuntu 24.04
        # ships Plasma 5. krdp does not exist in the Ubuntu 24.04 repos.
        #
        # wlroots VNC (wayvnc) does NOT work on KWin — KWin does not
        # implement the wlroots screencopy protocol.
        #
        # Solution: run Plasma in a plain X11 session under Xvfb (a fake
        # framebuffer), then capture that with x11vnc. This needs zero
        # PPAs and works on Ubuntu 24.04 today.
        apt_get \
            xvfb \
            x11vnc \
            kwin-x11 \
            plasma-workspace \
            plasma-desktop \
            dbus-x11 \
            fonts-noto-core

        apt_get_optional \
            plasma-mobile \
            kde-standard
        ;;
esac

# ────────────────────────────────────────────────────────────────────
# 6. Configure VNC authentication
# ────────────────────────────────────────────────────────────────────

echo
echo "--- Configuring VNC authentication ---"

case "$DESKTOP" in
    phosh)
        # wayvnc reads a plain text config file
        WAYVNC_CFG="$REAL_HOME/.config/wayvnc/config"
        as_user "mkdir -p '$(dirname "$WAYVNC_CFG")'"
        if [[ -n "$VNC_PASS" ]]; then
            as_user "cat > '$WAYVNC_CFG' <<CFG
address=0.0.0.0
enable_auth=true
username=$REAL_USER
password=$VNC_PASS
CFG"
        else
            as_user "cat > '$WAYVNC_CFG' <<CFG
address=0.0.0.0
enable_auth=false
CFG"
        fi
        as_user "chmod 600 '$WAYVNC_CFG'"
        echo "wayvnc config: $WAYVNC_CFG"
        ;;

    plasma-desktop)
        # x11vnc reads a hashed password file created by x11vnc -storepasswd
        X11VNC_PASSFILE="$REAL_HOME/.vnc/x11vncpass"
        as_user "mkdir -p '$REAL_HOME/.vnc'"
        if [[ -n "$VNC_PASS" ]]; then
            x11vnc -storepasswd "$VNC_PASS" "$X11VNC_PASSFILE"
            as_user "chmod 600 '$X11VNC_PASSFILE'"
            echo "x11vnc password file: $X11VNC_PASSFILE"
        else
            echo "No x11vnc password set (unauthenticated)."
        fi
        ;;
esac

# ────────────────────────────────────────────────────────────────────
# 7. Save config for the pmos launcher
# ────────────────────────────────────────────────────────────────────

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
DESKTOP=$DESKTOP
INTERFACE=$INTERFACE
PMOS_USER=$REAL_USER
PMOS_HOME=$REAL_HOME
VNC_PORT=$VNC_PORT
NOVNC_PORT=$NOVNC_PORT
NOVNC_DIR=$NOVNC_DIR
NOVNC_HTML=$(basename "$NOVNC_HTML")
EOF
echo "Config saved: $CONFIG_FILE"

# ────────────────────────────────────────────────────────────────────
# 8. Write the pmos launcher
# ────────────────────────────────────────────────────────────────────

cat > "$PMOS_BIN" <<'LAUNCHER'
#!/usr/bin/env bash
# pmos — start the headless mobile session configured by pmoiu
# Run as your normal user (no sudo).

set -uo pipefail
source /etc/pmoiu/config

# ── Runtime directory ──────────────────────────────────────────────
# SSH sessions and GitHub Codespaces have no systemd --user session,
# so XDG_RUNTIME_DIR may be absent or point to a non-existent path.
# We create a private tmp directory that every child process can use.
RUNTIME_UID=$(id -u)
RUNTIME_DIR="/tmp/pmos-runtime-$RUNTIME_UID"
mkdir -p "$RUNTIME_DIR"
chmod 0700 "$RUNTIME_DIR"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"

PIDS=()

cleanup() {
    echo
    echo "[pmos] Shutting down..."
    local pid
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    # x11vnc backgrounds itself; kill by name as a backstop
    pkill -x x11vnc   2>/dev/null || true
    pkill -x wayvnc   2>/dev/null || true
    pkill -x websockify 2>/dev/null || true
    rm -f /tmp/.X99-lock
    exit 0
}
trap cleanup INT TERM EXIT

wait_for_socket() {
    # wait_for_socket /path/to/socket [timeout]
    local sock=$1 timeout=${2:-25} elapsed=0
    echo "[pmos] Waiting for $sock ..."
    while [[ ! -S "$sock" ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $timeout ]]; then
            echo "[pmos] Timed out waiting for $sock"
            return 1
        fi
    done
    echo "[pmos] $sock is ready"
}

# ══════════════════════════════════════════════════════════════════
# Phosh path
# Compositor: phoc (wlroots, headless backend)
# VNC:        wayvnc (wlroots screencopy — works on phoc)
# ══════════════════════════════════════════════════════════════════

start_phosh_session() {
    echo "[pmos] Starting phoc + phosh (headless Wayland)..."

    # phoc needs a D-Bus session. dbus-run-session creates one for
    # the lifetime of its child process and exports DBUS_SESSION_BUS_ADDRESS.
    # We also set WLR_BACKENDS=headless so phoc doesn't try to open /dev/dri.
    # WLR_LIBINPUT_NO_DEVICES=1 suppresses the "no input devices" error.
    dbus-run-session -- env \
        WLR_BACKENDS=headless \
        WLR_LIBINPUT_NO_DEVICES=1 \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        XDG_SESSION_TYPE=wayland \
        WAYLAND_DISPLAY=wayland-0 \
        phoc -E phosh \
        &>/tmp/pmos-phosh.log &
    PIDS+=($!)

    wait_for_socket "$XDG_RUNTIME_DIR/wayland-0" 25 || {
        echo "[pmos] phoc failed to start. Log:"
        tail -20 /tmp/pmos-phosh.log
        exit 1
    }

    export WAYLAND_DISPLAY=wayland-0
}

start_wayvnc() {
    echo "[pmos] Starting wayvnc on $WAYLAND_DISPLAY port $VNC_PORT..."
    env \
        WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    wayvnc \
        --config="$HOME/.config/wayvnc/config" \
        0.0.0.0 "$VNC_PORT" \
        &>/tmp/pmos-wayvnc.log &
    PIDS+=($!)
    sleep 2

    # Confirm it's listening
    if ! ss -tlnp 2>/dev/null | grep -q ":$VNC_PORT " && \
       ! netstat -tlnp 2>/dev/null | grep -q ":$VNC_PORT "; then
        echo "[pmos] Warning: wayvnc may not have bound to port $VNC_PORT"
        echo "       Check /tmp/pmos-wayvnc.log for details"
    fi
}

# ══════════════════════════════════════════════════════════════════
# Plasma Desktop path  (Xvfb + kwin_x11 + plasmashell + x11vnc)
#
# Why Xvfb instead of Wayland?
#   krdp (KWin's RDP server) needs Plasma 6 — not in Ubuntu 24.04.
#   wayvnc needs wlroots screencopy — KWin doesn't implement it.
#   Xvfb gives us a real framebuffer that x11vnc can capture with
#   zero extra dependencies or PPAs.
# ══════════════════════════════════════════════════════════════════

XDISPLAY=":99"

start_plasma_session() {
    # Remove stale lock from a previous run
    rm -f "/tmp/.X${XDISPLAY#:}-lock"

    echo "[pmos] Starting Xvfb on DISPLAY=$XDISPLAY (1080×1920)..."
    Xvfb "$XDISPLAY" -screen 0 1080x1920x24 -ac &
    PIDS+=($!)
    sleep 2

    export DISPLAY="$XDISPLAY"

    echo "[pmos] Starting kwin_x11 inside a D-Bus session..."
    dbus-run-session -- env \
        DISPLAY="$XDISPLAY" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        XDG_SESSION_TYPE=x11 \
        kwin_x11 \
        &>/tmp/pmos-kwin.log &
    PIDS+=($!)
    sleep 3

    echo "[pmos] Starting plasmashell..."
    dbus-run-session -- env \
        DISPLAY="$XDISPLAY" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        XDG_SESSION_TYPE=x11 \
        plasmashell \
        &>/tmp/pmos-plasmashell.log &
    PIDS+=($!)
    sleep 4

    # Launch plasma-mobile on top if available
    if command -v plasma-mobile &>/dev/null; then
        echo "[pmos] Launching plasma-mobile shell layer..."
        dbus-run-session -- env \
            DISPLAY="$XDISPLAY" \
            XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        plasma-mobile \
            &>/tmp/pmos-plasma-mobile.log &
        PIDS+=($!)
        sleep 2
    fi

    echo "[pmos] Plasma session running on DISPLAY=$XDISPLAY"
}

start_x11vnc() {
    local passfile="$HOME/.vnc/x11vncpass"
    local auth_args

    if [[ -f "$passfile" ]]; then
        auth_args="-rfbauth $passfile"
    else
        auth_args="-nopw"
        echo "[pmos] No x11vnc password file found — running unauthenticated"
    fi

    echo "[pmos] Starting x11vnc on DISPLAY=$XDISPLAY port $VNC_PORT..."
    # shellcheck disable=SC2086
    x11vnc \
        -display "$XDISPLAY" \
        -rfbport "$VNC_PORT" \
        $auth_args \
        -forever \
        -shared \
        -noxdamage \
        -noscr \
        -o /tmp/pmos-x11vnc.log \
        &
    PIDS+=($!)
    sleep 2
}

# ══════════════════════════════════════════════════════════════════
# websockify + noVNC (shared by both paths)
# ══════════════════════════════════════════════════════════════════

start_novnc() {
    # Resolve web assets directory (recorded at install time, but verify)
    local web_dir="${NOVNC_DIR:-}"
    local html_file="${NOVNC_HTML:-vnc.html}"

    if [[ -z "$web_dir" || ! -f "$web_dir/$html_file" ]]; then
        # Search common locations
        local d
        for d in /usr/share/novnc /usr/lib/novnc /opt/novnc /usr/share/novnc-core; do
            if [[ -f "$d/vnc.html" || -f "$d/vnc_lite.html" ]]; then
                web_dir="$d"
                html_file=$(ls "$d/vnc.html" "$d/vnc_lite.html" 2>/dev/null | head -1 | xargs basename)
                break
            fi
        done
    fi

    if [[ -z "$web_dir" ]]; then
        echo "[pmos] ERROR: noVNC web assets not found."
        echo "       Install with: apt-get install novnc"
        echo "       Then rerun: pmos"
        exit 1
    fi

    echo "[pmos] Starting websockify: port $NOVNC_PORT → 127.0.0.1:$VNC_PORT"
    echo "       Serving noVNC assets from $web_dir"

    websockify \
        --web "$web_dir" \
        --heartbeat 30 \
        "$NOVNC_PORT" \
        "127.0.0.1:$VNC_PORT" \
        &>/tmp/pmos-websockify.log &
    PIDS+=($!)
    sleep 2

    # Print access instructions
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{print $7}' | head -1)
    ip="${ip:-127.0.0.1}"

    echo
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│              pmos session is running                │"
    echo "├─────────────────────────────────────────────────────┤"
    printf "│  Browser URL : http://%-30s│\n" "$ip:$NOVNC_PORT/$html_file"
    printf "│  Raw VNC     : %-36s│\n" "$ip:$VNC_PORT"
    echo "├─────────────────────────────────────────────────────┤"
    echo "│  SSH tunnel (keeps traffic off the open internet):  │"
    printf "│  ssh -L %s:127.0.0.1:%s user@%-14s│\n" \
        "$NOVNC_PORT" "$NOVNC_PORT" "$ip"
    echo "│  Then open: http://127.0.0.1:$NOVNC_PORT/$html_file"
    echo "├─────────────────────────────────────────────────────┤"
    echo "│  Logs:                                              │"
    case "$DESKTOP" in
        phosh)          echo "│  /tmp/pmos-phosh.log  /tmp/pmos-wayvnc.log          │" ;;
        plasma-desktop) echo "│  /tmp/pmos-kwin.log   /tmp/pmos-x11vnc.log          │" ;;
    esac
    echo "│  /tmp/pmos-websockify.log                           │"
    echo "└─────────────────────────────────────────────────────┘"
}

# ── Main ──────────────────────────────────────────────────────────

echo "=== pmos: starting $DESKTOP + $INTERFACE ==="
echo

case "$DESKTOP" in
    phosh)
        start_phosh_session
        start_wayvnc
        ;;
    plasma-desktop)
        start_plasma_session
        start_x11vnc
        ;;
esac

# Both paths end with websockify + noVNC
start_novnc

echo
echo "[pmos] Press Ctrl+C to stop the session."
wait
LAUNCHER

chmod +x "$PMOS_BIN"

# ────────────────────────────────────────────────────────────────────
# Done
# ────────────────────────────────────────────────────────────────────

echo
echo "┌─────────────────────────────────────────────────────┐"
echo "│              pmoiu install complete                 │"
echo "├─────────────────────────────────────────────────────┤"
printf "│  Shell     : %-38s│\n" "$DESKTOP"
printf "│  Interface : %-38s│\n" "$INTERFACE (noVNC via websockify)"
printf "│  User      : %-38s│\n" "$REAL_USER"
echo "├─────────────────────────────────────────────────────┤"
echo "│  To start the session (no sudo needed):             │"
echo "│    pmos                                             │"
echo "│  To change settings re-run:                         │"
echo "│    sudo ./pmoiu                                     │"
echo "└─────────────────────────────────────────────────────┘"

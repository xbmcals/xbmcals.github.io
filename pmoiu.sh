#!/usr/bin/env bash
#
# pmoiu — PostmarketOS in Ubuntu (installer)
#
# Installs a mobile Linux shell (Plasma Mobile or Phosh) plus a
# remote-access backend (KasmVNC, noVNC, or RDP), and drops a "pmos"
# launcher in /usr/local/bin that starts the session + server
# headlessly (no physical display needed — works fine over plain SSH).
#
# Despite the name this also runs on Debian, Fedora, and Arch — it
# detects apt/dnf/pacman and adjusts package names accordingly. Ubuntu
# and Debian get the most testing; plasma-mobile and phosh are niche
# packages on Fedora/Arch (often COPR/AUR rather than the main repos),
# so on those distros the script tells you plainly if a package isn't
# found instead of guessing a name that doesn't exist.
#
# ---------------------------------------------------------------------
# READ THIS FIRST — compatibility reality check
# ---------------------------------------------------------------------
# Plasma Mobile runs on KWin. KWin does NOT implement the wlroots
# screencopy/virtual-input protocols that wayvnc and KasmVNC's Wayland
# capture rely on (there's an open KDE feature request to add the
# replacement protocol, ext-image-copy-capture-v1, but it isn't
# shipped yet). The only remote-access method that reliably works with
# Plasma Mobile today is RDP, via KWin's own KRDP server.
#
# Phosh runs on phoc, a wlroots-based compositor, so wayvnc/KasmVNC/
# noVNC all work fine there. Phosh has nothing equivalent to KRDP, so
# there's no solid native RDP path for it.
#
# This script will NOT silently let you pick a combo that's known not
# to work — it warns you and offers to switch to the supported option.
# ---------------------------------------------------------------------

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
CONFIG_DIR="/etc/pmoiu"
CONFIG_FILE="$CONFIG_DIR/config"
PMOS_BIN="/usr/local/bin/pmos"
NOVNC_SHARE_DIR="/usr/share/novnc"
VNC_PORT=5900
NOVNC_PORT=6080
RDP_PORT=3389

# --------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "pmoiu needs root to install packages. Re-run as: sudo" >&2
        exit 1
    fi
}

as_user() {
    # run a command as the real (non-root) user who invoked sudo
    sudo -u "$REAL_USER" -H bash -c "$*"
}

choose() {
    # choose RESULT_VAR "option1" "option2" ...
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
        echo "Couldn't find apt, dnf, or pacman. Unsupported distro." >&2
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

pkg_install() {
    # pkg_install pkg1 pkg2 ... — returns non-zero if any package is
    # genuinely missing from the repos (as opposed to already installed).
    case "$PKG_MGR" in
        apt)    apt-get install -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        pacman) pacman -S --needed --noconfirm "$@" ;;
    esac
}

pkg_available() {
    # pkg_available pkgname — true if the repos actually have it
    case "$PKG_MGR" in
        apt)    apt-cache show "$1" &>/dev/null ;;
        dnf)    dnf info "$1" &>/dev/null ;;
        pacman) pacman -Si "$1" &>/dev/null ;;
    esac
}

# --------------------------------------------------------------------
# 1. ask what to install
# --------------------------------------------------------------------

require_root
detect_pkgmgr

echo "=== pmoiu — install a mobile shell ($PKG_MGR detected) ==="
echo
echo "Which mobile shell do you want?"
choose DESKTOP "plasma-mobile" "phosh"

echo
echo "Which remote-access method do you want to interface it with?"
choose INTERFACE "kasmvnc" "novnc" "rdp"

# --------------------------------------------------------------------
# 2. compatibility check — see the header comment for why
# --------------------------------------------------------------------

if [[ "$DESKTOP" == "plasma-mobile" && "$INTERFACE" != "rdp" ]]; then
    cat <<EOF

WARNING: Plasma Mobile's compositor (KWin) does not support the
wlroots screencopy protocol that $INTERFACE depends on. $INTERFACE
will very likely fail to capture anything on Plasma Mobile — it will
start, then error out with something like "compositor doesn't
support screencopy". RDP (via KWin's own KRDP server) is the only
combo that's actually known to work.

EOF
    choose FIX "Switch to rdp (recommended)" "Continue with $INTERFACE anyway (known broken)" "Abort"
    case "$FIX" in
        "Switch to rdp"*) INTERFACE="rdp" ;;
        "Continue"*) : ;;
        "Abort") exit 1 ;;
    esac
fi

if [[ "$DESKTOP" == "phosh" && "$INTERFACE" == "rdp" ]]; then
    cat <<EOF

WARNING: Phosh/phoc has no built-in RDP server (nothing equivalent to
KWin's KRDP). There's no well-supported RDP path for it. Falling back
to noVNC (wayvnc + a browser client), which does work on phoc.

EOF
    INTERFACE="novnc"
fi

echo
echo "Installing: $DESKTOP  +  $INTERFACE"
echo

# --------------------------------------------------------------------
# 3. credentials (asked up front so the install can run unattended after this)
# --------------------------------------------------------------------

VNC_USER="$REAL_USER"
VNC_PASS=""
if [[ "$INTERFACE" == "novnc" ]]; then
    read -rsp "Set a password for the VNC/noVNC connection: " VNC_PASS; echo
fi

# --------------------------------------------------------------------
# 4. base tools
# --------------------------------------------------------------------

pkg_update
pkg_install curl wget gnupg openssl python3

# --------------------------------------------------------------------
# 5. install the desktop shell
# --------------------------------------------------------------------
#
# Package names/availability here are solid on Ubuntu/Debian. On
# Fedora and Arch, plasma-mobile and phosh are niche — if pkg_install
# fails, that almost always means the distro doesn't carry it in its
# main repos and you'll need a COPR (Fedora) or the AUR (Arch)
# instead. The script tells you rather than pretending it worked.

install_desktop() {
    case "$DESKTOP" in
        plasma-mobile)
            case "$PKG_MGR" in
                apt)    pkg_install plasma-mobile kwin-wayland-backend-virtual || return 1 ;;
                dnf)    pkg_install plasma-mobile kwin || return 1 ;;
                pacman) pkg_install plasma-mobile kwin || return 1 ;;
            esac
            ;;
        phosh)
            case "$PKG_MGR" in
                apt)        pkg_install phosh phosh-core phoc squeekboard || return 1 ;;
                dnf|pacman) pkg_install phosh phoc squeekboard || return 1 ;;
            esac
            ;;
    esac
    return 0
}
if ! install_desktop; then
    cat <<EOF

Couldn't install $DESKTOP via $PKG_MGR — it isn't in the standard
repos for this distro/release. On Fedora, look for a plasma-mobile or
phosh COPR. On Arch, check the AUR (e.g. 'yay -S plasma-mobile' or
'yay -S phosh'). On Ubuntu/Debian, check you're on a release recent
enough to carry it (see https://packages.ubuntu.com or
https://packages.debian.org).
EOF
    exit 1
fi

# --------------------------------------------------------------------
# 6. install the remote-access backend
# --------------------------------------------------------------------

install_kasmvnc() {
    if command -v kasmvncserver &>/dev/null; then
        echo "kasmvncserver already installed."
        return
    fi
    case "$PKG_MGR" in
        apt)
            local codename arch asset_url
            codename=$(lsb_release -cs)
            arch=$(dpkg --print-architecture)
            echo "Looking up the latest KasmVNC .deb for $codename/$arch..."
            asset_url=$(curl -fsSL https://api.github.com/repos/kasmtech/KasmVNC/releases/latest \
                | grep -oP '"browser_download_url":\s*"\K[^"]*\.deb' \
                | grep -i "$codename" | grep -i "$arch" | head -n1 || true)
            if [[ -z "$asset_url" ]]; then
                echo "Couldn't auto-detect a matching .deb on the KasmVNC releases"
                echo "page (https://github.com/kasmtech/KasmVNC/releases). Grab one"
                echo "manually and install with 'dpkg -i', then re-run pmoiu."
                exit 1
            fi
            wget -O /tmp/kasmvncserver.deb "$asset_url"
            apt-get install -y /tmp/kasmvncserver.deb
            ;;
        dnf)
            local arch asset_url
            arch=$(uname -m)
            echo "Looking up the latest KasmVNC .rpm for $arch..."
            asset_url=$(curl -fsSL https://api.github.com/repos/kasmtech/KasmVNC/releases/latest \
                | grep -oP '"browser_download_url":\s*"\K[^"]*\.rpm' \
                | grep -i "$arch" | head -n1 || true)
            if [[ -z "$asset_url" ]]; then
                echo "Couldn't auto-detect a matching .rpm on the KasmVNC releases"
                echo "page (https://github.com/kasmtech/KasmVNC/releases). Grab one"
                echo "manually and install with 'dnf install ./file.rpm', then"
                echo "re-run pmoiu."
                exit 1
            fi
            wget -O /tmp/kasmvncserver.rpm "$asset_url"
            dnf install -y /tmp/kasmvncserver.rpm
            ;;
        pacman)
            echo "KasmVNC isn't in the official Arch repos — it's on the AUR as"
            echo "'kasmvnc' or 'kasmvnc-bin'. Install it yourself first (e.g."
            echo "'yay -S kasmvnc-bin'), then re-run pmoiu."
            exit 1
            ;;
    esac
    echo
    echo "Set the KasmVNC password for $VNC_USER now:"
    as_user "kasmvncpasswd"
}

install_novnc() {
    pkg_install wayvnc novnc
    as_user "mkdir -p '$REAL_HOME/.config/wayvnc'"
    as_user "cat > '$REAL_HOME/.config/wayvnc/config' <<CFG
address=0.0.0.0
enable_auth=true
username=$VNC_USER
password=$VNC_PASS
CFG"
    as_user "chmod 600 '$REAL_HOME/.config/wayvnc/config'"
}

install_rdp() {
    case "$PKG_MGR" in
        apt)
            if ! pkg_available krdp; then
                cat <<EOF

krdp isn't in this Ubuntu/Debian release's repos. It needs Plasma 6,
and Ubuntu 24.04/22.04 (and Debian bookworm) ship Plasma 5 by
default. krdp only lands starting with Ubuntu 25.04 (or Debian
trixie+). Two ways forward:

EOF
                choose PPA_FIX \
                    "Add the Kubuntu Backports PPA to get Plasma 6 + krdp (Ubuntu only — upgrades your whole KDE/Plasma stack, can take a while)" \
                    "Skip RDP — use novnc instead (works today, no stack upgrade)" \
                    "Abort"
                case "$PPA_FIX" in
                    "Add the Kubuntu"*)
                        if ! command -v lsb_release &>/dev/null || [[ "$(lsb_release -is)" != "Ubuntu" ]]; then
                            echo "This PPA is Ubuntu-only. On Debian, add the KDE backports"
                            echo "suite for your release, or install Debian trixie+/sid,"
                            echo "then re-run pmoiu."
                            exit 1
                        fi
                        pkg_install software-properties-common
                        add-apt-repository -y ppa:kubuntu-ppa/backports
                        apt-get update
                        echo "Upgrading Plasma packages — this can take a while..."
                        apt-get full-upgrade -y
                        ;;
                    "Skip RDP"*)
                        INTERFACE=novnc
                        install_novnc
                        return
                        ;;
                    "Abort") exit 1 ;;
                esac
            fi
            pkg_install krdp
            ;;
        dnf|pacman)
            # krdp is a normal, current package on Fedora and Arch since
            # they ship Plasma 6 already.
            pkg_install krdp
            ;;
    esac

    local krdp_dir="$REAL_HOME/.local/share/krdpserver"
    as_user "mkdir -p '$krdp_dir'"
    as_user "openssl req -nodes -new -x509 \
        -keyout '$krdp_dir/krdp.key' -out '$krdp_dir/krdp.crt' \
        -days 3650 -batch"
    as_user "kwriteconfig6 --file krdpserverrc --group General --key Certificate '$krdp_dir/krdp.crt'"
    as_user "kwriteconfig6 --file krdpserverrc --group General --key CertificateKey '$krdp_dir/krdp.key'"
    as_user "kwriteconfig6 --file krdpserverrc --group General --key SystemUserEnabled true"
    echo
    echo "RDP is set to authenticate with your normal Linux username/password"
    echo "($VNC_USER) via SystemUserEnabled — no separate RDP password to set."
}

case "$INTERFACE" in
    kasmvnc) install_kasmvnc ;;
    novnc)   install_novnc ;;
    rdp)     install_rdp ;;
esac

# --------------------------------------------------------------------
# 7. write config for pmos to read later
# --------------------------------------------------------------------

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
DESKTOP=$DESKTOP
INTERFACE=$INTERFACE
PMOS_USER=$REAL_USER
VNC_PORT=$VNC_PORT
NOVNC_PORT=$NOVNC_PORT
RDP_PORT=$RDP_PORT
WAYLAND_SOCKET_NAME=wayland-pmos
EOF

# --------------------------------------------------------------------
# 8. generate /usr/local/bin/pmos
# --------------------------------------------------------------------

cat > "$PMOS_BIN" <<'PMOS_SCRIPT'
#!/usr/bin/env bash
#
# pmos — start the mobile session + remote-access server set up by pmoiu.
# Generated by pmoiu — edit /etc/pmoiu/config to change desktop/interface,
# or just re-run pmoiu.

set -uo pipefail
source /etc/pmoiu/config

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
PIDS=()

cleanup() {
    echo
    echo "Stopping pmos..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    exit 0
}
trap cleanup INT TERM

wait_for_wayland_socket() {
    # Snapshot existing sockets, then wait for a NEW one to appear so we
    # don't accidentally grab an unrelated compositor's socket.
    local before after new_sock timeout=20
    before=$(ls "$RUNTIME_DIR"/wayland-*.lock 2>/dev/null || true)
    while (( timeout > 0 )); do
        after=$(ls "$RUNTIME_DIR"/wayland-*.lock 2>/dev/null || true)
        new_sock=$(comm -13 <(echo "$before" | sort) <(echo "$after" | sort) | head -n1)
        if [[ -n "$new_sock" ]]; then
            basename "$new_sock" .lock
            return 0
        fi
        sleep 1
        timeout=$((timeout - 1))
    done
    echo "" # signal failure with empty output
}

start_plasma_mobile() {
    export XDG_SESSION_TYPE=wayland
    export QT_QPA_PLATFORM=wayland
    # kwin_wayland's --virtual backend is what makes this work without a
    # physical display. NOTE: startplasmamobile is a wrapper script; on
    # some package versions it hardcodes "kwin_wayland --drm" instead of
    # respecting this env var. If the session fails to come up, check
    # `cat $(command -v startplasmamobile)` and swap --drm for --virtual
    # by hand, or invoke kwin_wayland yourself with the mobile shell as
    # its -e/exec argument.
    export KWIN_WAYLAND_BACKEND=virtual
    startplasmamobile &
    PIDS+=($!)
    WAYLAND_DISPLAY=$(wait_for_wayland_socket)
    if [[ -z "$WAYLAND_DISPLAY" ]]; then
        echo "Plasma Mobile's Wayland socket never appeared. See the note"
        echo "above about startplasmamobile's hardcoded backend flag."
        cleanup
    fi
    export WAYLAND_DISPLAY
}

start_phosh() {
    export WLR_BACKENDS=headless
    export WLR_LIBINPUT_NO_DEVICES=1
    export WAYLAND_DISPLAY="$WAYLAND_SOCKET_NAME"
    # -E tells phoc what to run as the shell client. If your distro's
    # phoc.ini is somewhere non-default, add: -C /etc/phosh/phoc.ini
    phoc -E phosh &
    PIDS+=($!)
    sleep 3
    if [[ ! -S "$RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
        echo "phoc's Wayland socket never appeared — check 'journalctl' or"
        echo "run 'phoc -E phosh' in the foreground to see the real error."
        cleanup
    fi
}

start_kasmvnc() {
    echo "Starting KasmVNC..."
    kasmvncserver :1 -select-de manual 2>&1 &
    PIDS+=($!)
    echo "Connect with a VNC client to <this-host>:$((VNC_PORT))"
    echo "(If KasmVNC can't attach to the Wayland session, use novnc/rdp instead.)"
}

start_novnc() {
    echo "Starting wayvnc..."
    wayvnc -w -C "$HOME/.config/wayvnc/config" 0.0.0.0 "$VNC_PORT" &
    PIDS+=($!)
    echo "Serving the noVNC web client on port $NOVNC_PORT..."
    ( cd /usr/share/novnc && python3 -m http.server "$NOVNC_PORT" ) &
    PIDS+=($!)
    IP=$(hostname -I | awk '{print $1}')
    echo
    echo "Open in a browser: http://$IP:$NOVNC_PORT/vnc.html?host=$IP&port=$VNC_PORT"
    echo "(Prefer tunneling this over SSH rather than exposing it directly.)"
}

start_rdp() {
    echo "Starting krdpserver..."
    krdpserver &
    PIDS+=($!)
    IP=$(hostname -I | awk '{print $1}')
    echo "Connect with an RDP client (Remmina, xfreerdp, mstsc) to $IP:$RDP_PORT"
    echo "Log in with your normal Linux username ($PMOS_USER) and password."
}

echo "=== pmos: starting $DESKTOP + $INTERFACE ==="

case "$DESKTOP" in
    plasma-mobile) start_plasma_mobile ;;
    phosh)         start_phosh ;;
esac

case "$INTERFACE" in
    kasmvnc) start_kasmvnc ;;
    novnc)   start_novnc ;;
    rdp)     start_rdp ;;
esac

echo
echo "pmos is running. Press Ctrl+C to stop everything."
wait
PMOS_SCRIPT

chmod +x "$PMOS_BIN"

echo
echo "=== Done ==="
echo "Installed: $DESKTOP + $INTERFACE"
echo "Run 'pmos' (as $REAL_USER, no sudo needed) to start the session."
if [[ "$INTERFACE" == "rdp" || "$DESKTOP" == "plasma-mobile" ]]; then
    echo "Make sure port $RDP_PORT/tcp is reachable (or tunnel it over SSH)."
fi
if [[ "$INTERFACE" == "novnc" ]]; then
    echo "Make sure ports $VNC_PORT and $NOVNC_PORT/tcp are reachable (or tunnel over SSH)."
fi


l
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
# There's also a second path: downloading a REAL postmarketOS
# environment via pmbootstrap instead of native packages. This matters
# because postmarketOS uses apk (from Alpine), but its plasma-mobile/
# phosh packages live in postmarketOS's OWN repo — plain Alpine's repos
# don't have them, so a plain "docker run alpine && apk add
# plasma-mobile" won't work. pmbootstrap knows the real mirrors/keys
# and targets your actual detected architecture (nothing hardcoded).
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
        echo "pmoiu needs root to install packages. Re-run as: sudo ./pmoiu" >&2
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
echo "How do you want to get $DESKTOP?"
choose SOURCE \
    "Native $PKG_MGR packages on this system (current host, headless hacks needed)" \
    "Download a real postmarketOS environment via pmbootstrap (boots in QEMU — sidesteps most of the headless GPU/dmabuf pain, since QEMU gives it a virtual GPU)"

if [[ "$SOURCE" == Download* ]]; then
    HOST_ARCH=$(uname -m)
    echo
    echo "Detected host architecture: $HOST_ARCH (not hardcoded — pmbootstrap"
    echo "will offer you devices/architectures based on what it detects too)."
    pkg_install git python3 python3-pip openssl qemu-system-"$HOST_ARCH" 2>/dev/null \
        || pkg_install git python3 python3-pip openssl
    if ! as_user "command -v pmbootstrap" &>/dev/null; then
        echo "Installing pmbootstrap for $VNC_USER via pip..."
        as_user "pip install --user pmbootstrap --break-system-packages" \
            || as_user "pip install --user pmbootstrap"
    fi
    cat <<EOF

pmbootstrap will now ask a series of questions (this is interactive —
we deliberately don't script past it, since guessing the right
device/UI answers for your specific architecture would mean hardcoding
exactly what you asked us not to). When it asks, pick:
  release channel: your choice (edge = latest, or a stable vN.NN)
  vendor:          generic
  device:          whichever entry matches $HOST_ARCH
  UI:              $DESKTOP

EOF
    as_user "pmbootstrap init"
    echo
    echo "Fetching/building the image — this can take a while..."
    as_user "pmbootstrap install"

    IMG=$(as_user "find \$HOME/.local/var/pmbootstrap \$HOME/.cache/pmbootstrap 2>/dev/null -maxdepth 6 \( -iname '*.img' -o -iname '*.qcow2' \) -printf '%T@ %p\n' | sort -rn | head -n1 | cut -d' ' -f2-" 2>/dev/null || true)

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
DESKTOP=$DESKTOP
SOURCE=pmbootstrap
HOST_ARCH=$HOST_ARCH
PMOS_USER=$REAL_USER
PMOS_IMAGE=$IMG
EOF

    cat > "$PMOS_BIN" <<'PMOS_SCRIPT'
#!/usr/bin/env bash
# pmos — boot the postmarketOS image pmoiu downloaded, with QEMU's own
# VNC output (this is QEMU's virtual-machine display, separate from
# wayvnc/kasmvnc — it works regardless of what's running inside the VM).
set -uo pipefail
source /etc/pmoiu/config

if [[ -z "${PMOS_IMAGE:-}" || ! -f "$PMOS_IMAGE" ]]; then
    echo "Couldn't find the built image automatically."
    echo "Look for it yourself under ~/.local/var/pmbootstrap (or wherever"
    echo "'pmbootstrap config work' points), and either boot it with:"
    echo "  qemu-system-$HOST_ARCH -m 2048 -drive file=<path>,format=raw -vnc :1"
    echo "or just run 'pmbootstrap qemu' for the normal (local-display) launcher."
    exit 1
fi

echo "Booting $PMOS_IMAGE with QEMU (VNC display :1 -> port 5901)..."
echo "This is QEMU's own VNC output, not wayvnc/kasmvnc — connect any VNC"
echo "client to <this-host>:5901 once it's booted."
qemu-system-"$HOST_ARCH" \
    -m 2048 \
    -drive file="$PMOS_IMAGE",format=raw \
    -vnc :1
PMOS_SCRIPT
    chmod +x "$PMOS_BIN"

    echo
    echo "=== Done ==="
    echo "Run 'pmos' (as $REAL_USER) to boot it. First boot inside pmOS still"
    echo "needs its own setup (network, maybe 'apk add wayvnc' if you'd rather"
    echo "use Wayland-native VNC from inside the guest instead of QEMU's)."
    echo "If the auto-detected image path is wrong, edit PMOS_IMAGE in"
    echo "$CONFIG_FILE by hand."
    exit 0
fi

echo
echo "Which remote-access method do you want to interface it with?"
choose INTERFACE "kasmvnc" "novnc" "rdp"

# --------------------------------------------------------------------
# 2. compatibility check — see the header comment for why
# --------------------------------------------------------------------

if [[ "$INTERFACE" == "kasmvnc" ]]; then
    cat <<EOF

WARNING: KasmVNC's normal mode of operation ('vncserver') starts and
manages its OWN X11 desktop session (like classic TigerVNC) — it does
not attach to an already-running Wayland compositor. That means it
won't show you the plasma-mobile/phosh session at all; it'll just
give you a separate, unrelated X desktop. wayvnc (the novnc option
here) is the one that actually attaches to a running Wayland session.

EOF
    choose KASM_FIX "Switch to novnc (recommended — actually shows the mobile session)" "Continue with kasmvnc anyway (separate X session, not the mobile shell)" "Abort"
    case "$KASM_FIX" in
        "Switch to novnc"*) INTERFACE="novnc" ;;
        "Continue"*) : ;;
        "Abort") exit 1 ;;
    esac
fi

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
pkg_install curl wget gnupg openssl python3 dbus
pkg_install dbus-user-session 2>/dev/null || true   # Debian/Ubuntu split this out; Fedora/Arch bundle it in 'dbus'

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
                apt)        pkg_install phosh phosh-core phoc || return 1 ;;
                dnf|pacman) pkg_install phosh phoc || return 1 ;;
            esac
            # squeekboard (on-screen keyboard) isn't always available —
            # e.g. it has a gap in Ubuntu 24.04's repos. It's a nice-to-have,
            # not required to get the session up, so don't fail the install
            # over it.
            if ! pkg_install squeekboard 2>/dev/null; then
                echo "Note: squeekboard (on-screen keyboard) isn't available"
                echo "in this release's repos. You'll need a physical/external"
                echo "keyboard, or install an on-screen keyboard some other way."
            fi
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
    echo "Setting the KasmVNC password for $VNC_USER now (needs -u, or it just prints usage):"
    as_user "vncpasswd -u '$VNC_USER' -w"
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
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
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
    # startplasmamobile needs a session D-Bus. Over plain SSH there usually
    # isn't one running yet, which is why it silently fails to start —
    # dbus-run-session gives it a fresh one.
    dbus-run-session -- startplasmamobile &
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
    # Hosts with no GPU (or no accessible DRM render node) can't do
    # dmabuf-based GPU rendering — fall back to wlroots' software (pixman)
    # renderer so phoc doesn't just fail to start.
    export WLR_RENDERER=pixman
    export WLR_LIBINPUT_NO_DEVICES=1
    export WAYLAND_DISPLAY="$WAYLAND_SOCKET_NAME"
    # -E tells phoc what to run as the shell client. If your distro's
    # phoc.ini is somewhere non-default, add: -C /etc/phosh/phoc.ini
    # phoc/phosh also want a session D-Bus, same reasoning as above.
    dbus-run-session -- phoc -E phosh-session &
    PIDS+=($!)
    sleep 3
    if [[ ! -S "$RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
        echo "phoc's Wayland socket never appeared — check 'journalctl' or"
        echo "run 'phoc -E phosh-session' in the foreground to see the real error."
        cleanup
    fi
}

start_kasmvnc() {
    echo "Starting KasmVNC (this manages its OWN X session — it will NOT show"
    echo "you $DESKTOP; see the warning pmoiu printed at install time)..."
    vncserver -select-de manual
    echo "Connect with a VNC client to <this-host>:$VNC_PORT"
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

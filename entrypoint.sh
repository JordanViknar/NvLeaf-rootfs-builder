#!/usr/bin/env bash
set -euo pipefail

# Colour helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# --------------------------- Configuration ---------------------------
UBUNTU_SUITE="${UBUNTU_SUITE:-jammy}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"

export UBUNTU_SUITE

ROM_NAME="${ROM_NAME:-ubuntu-22.04-xfce}"
OUTPUT_FILE="${OUTPUT_FILE:-/output/${ROM_NAME}.mrom}"

# Wi-Fi — all optional; leave WIFI_SSID unset to skip Wi-Fi configuration
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
# WIFI_HIDDEN: set to "true" if your network does not broadcast its SSID
WIFI_HIDDEN="${WIFI_HIDDEN:-false}"

CHROOT=/chroot
BUILD=/build
COMPRESSION_THREADS="$(nproc)"

# --------------------------- Install build tools ---------------------------
info "Installing build tools…"
apt-get update -qq
apt-get install -y --no-install-recommends \
    mmdebstrap        \
    qemu-user-static  \
    binfmt-support    \
    arch-test         \
    pigz              \
    zip               \
    rsync             \
    ca-certificates
rm -rf /var/lib/apt/lists/*

# --------------------------- Validate required inputs ---------------------------
info "Validating inputs …"
[[ -f /input/manifest.txt ]] || die "/input/manifest.txt not found."
[[ -f /input/root_dir/rom_info.txt ]] || die "/input/root_dir/rom_info.txt not found."
[[ -d /input/root_dir/boot ]] || die "/input/root_dir/boot/ directory not found."
KERNEL_COUNT=$(find /input/root_dir/boot -maxdepth 1 -type f | wc -l)
[[ "$KERNEL_COUNT" -ge 1 ]] || die "/input/root_dir/boot/ is empty — place your kernel (and initrd) there."
success "Input validation passed."

#  --------------------------- Mount binfmt_misc and register qemu ---------------------------
info "Mounting binfmt_misc and registering qemu for armhf …"
QEMU_BIN=/usr/bin/qemu-arm-static

if [[ -n "${QEMU_BIN}" ]]; then
    [[ -f "${QEMU_BIN}" ]] || die "${QEMU_BIN} not found."
    if ! mountpoint -q /proc/sys/fs/binfmt_misc 2>/dev/null; then
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
    fi

    # Register all qemu-user-static handlers (includes qemu-arm-static)
    update-binfmts --enable

    success "binfmt_misc mounted and qemu registered (${QEMU_BIN})."
else
    success "Native arch — no qemu needed."
fi

# --------------------------- Prepare build directories ---------------------------
mkdir -p "${CHROOT}" "${BUILD}/rom" "${BUILD}/root_dir" "${BUILD}/pre_install" "${BUILD}/post_install"

# --------------------------- write mmdebstrap hook scripts ---------------------------
# setup hook: runs before package installation
# Adds -updates and -security suites so Xfce and friends can be installed.
SETUP_HOOK=$(mktemp /tmp/mmdebstrap-setup-XXXXXX.sh)
cat > "${SETUP_HOOK}" <<HOOK
#!/bin/sh
set -e
cat >> "\$1/etc/apt/sources.list" <<SOURCES
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE}-updates main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE}-security main restricted universe multiverse
deb [trusted=yes] ${UBUNTU_MIRROR} trusty universe
SOURCES
HOOK
chmod +x "${SETUP_HOOK}"

# customize hook: runs after all packages are installed
CUSTOMIZE_HOOK=$(mktemp /tmp/mmdebstrap-customize-XXXXXX.sh)
cat > "${CUSTOMIZE_HOOK}" <<'HOOK'
#!/bin/sh
set -e

# Apply the rootfs overlay before chroot-side customization.
if [ -e /rootfs ] && [ ! -d /rootfs ]; then
    echo "rootfs exists but is not a directory: /rootfs" >&2
    exit 1
fi

if [ -d /rootfs ]; then
    rsync -a /rootfs/ "$1/"
fi

mkdir -p "$1/etc/apt/preferences.d"
cat > "$1/etc/apt/preferences.d/mozillateam-firefox" <<'PREF'
Package: firefox*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
PREF

chroot "$1" /bin/bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export http_proxy=http://apt-cacher:3142
    export https_proxy=http://apt-cacher:3142

    add-apt-repository -y ppa:mozillateam/ppa
    apt-get install -y --no-install-recommends firefox
    apt-get clean
    rm -rf /var/lib/apt/lists/*

    # Locale + timezone
    echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
    locale-gen
    update-locale LANG=en_US.UTF-8
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime

    # Enable NvLeaf services
    systemctl enable nvleaf-touchscreen.service || true
    systemctl enable nvleaf-wifibt.service || true
    systemctl enable nvleaf-tegra-udc.service || true

    # Default user
    id ubuntu &>/dev/null || useradd -m -s /bin/bash -G sudo,video,audio,input ubuntu
    echo 'ubuntu:ubuntu' | chpasswd
    # passwd -e ubuntu --- Temporarily disabled

    # Hostname
    echo 'ubuntu-multirom' > /etc/hostname
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tubuntu-multirom\n' > /etc/hosts

    # Remove mmdebstrap's config so it doesn't end up in the final image and cause confusion.
    rm -f /etc/apt/apt.conf.d/99mmdebstrap
"
HOOK
chmod +x "${CUSTOMIZE_HOOK}"

# --------------------------- Bootstrap via mmdebstrap ---------------------------
info "Running mmdebstrap for Ubuntu ${UBUNTU_SUITE} / armhf …"
info "Mirror: ${UBUNTU_MIRROR}"

mmdebstrap \
    --mode=auto \
    --variant=apt \
    --verbose \
    --aptopt='APT::Install-Recommends "false"' \
    --aptopt='Acquire::http::Proxy "http://apt-cacher:3142";' \
    --aptopt='Acquire::https::Proxy "http://apt-cacher:3142";' \
    --architectures="armhf" \
    --components="main,restricted,universe,multiverse" \
	--include="\
accountsservice,\
at-spi2-core,\
bluez,\
blueman,\
brcm-patchram-plus-nexus7,\
dbus,\
dbus-x11,\
gpg-agent,\
htop,\
locales,\
nano,\
network-manager,\
network-manager-gnome,\
onboard,\
openssh-server,\
pavucontrol,\
pulseaudio,\
rfkill,\
software-properties-common,\
sudo,\
systemd,\
thunar,\
thunar-volman,\
udev,\
upower,\
wpasupplicant,\
xfce4-goodies,\
xfce4-indicator-plugin,\
xfce4-notifyd,\
xfce4-panel,\
xfce4-power-manager,\
xfce4-power-manager-plugins,\
xfce4-pulseaudio-plugin,\
xfce4-session,\
xfce4-settings,\
xfce4-statusnotifier-plugin,\
xfdesktop4,\
xfwm4,\
xorg,\
xserver-xorg-input-evdev,\
xserver-xorg-video-fbdev,\
xubuntu-desktop,
zram-config" \
    --setup-hook="${SETUP_HOOK} \"\$1\"" \
    --customize-hook="${CUSTOMIZE_HOOK} \"\$1\"" \
    "${UBUNTU_SUITE}" \
    "${CHROOT}" \
    "${UBUNTU_MIRROR}"

rm -f "${SETUP_HOOK}" "${CUSTOMIZE_HOOK}"

success "mmdebstrap complete."

# --------------------------- Write Wi-Fi connection profile ---------------------------
if [[ -n "${WIFI_SSID}" ]]; then
    info "Writing Wi-Fi profile for SSID: ${WIFI_SSID} …"

    NM_DIR="${CHROOT}/etc/NetworkManager/system-connections"
    mkdir -p "${NM_DIR}"

    # Generate a stable UUID from the SSID so re-runs produce the same file
    WIFI_UUID=$(python3 -c "import uuid; print(uuid.uuid5(uuid.NAMESPACE_DNS, '${WIFI_SSID}'))")

    # Build the keyfile — NetworkManager reads this on first boot and
    # autoconnects because autoconnect=true.
    CONN_FILE="${NM_DIR}/wifi.nmconnection"
    cat > "${CONN_FILE}" <<NMCONN
[connection]
id=wifi
uuid=${WIFI_UUID}
type=wifi
autoconnect=true

[wifi]
ssid=${WIFI_SSID}
mode=infrastructure
hidden=${WIFI_HIDDEN}

NMCONN

    # Append security section only when a password is provided.
    # Leave it out entirely for open networks.
    if [[ -n "${WIFI_PASSWORD}" ]]; then
        cat >> "${CONN_FILE}" <<NMCONN
[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PASSWORD}

NMCONN
    fi

    cat >> "${CONN_FILE}" <<NMCONN
[ipv4]
method=auto

[ipv6]
method=auto
NMCONN

    # NetworkManager refuses to load profiles that are world-readable
    # because they may contain plaintext passwords.
    chmod 600 "${CONN_FILE}"
    chown root:root "${CONN_FILE}"

    success "Wi-Fi profile written (UUID: ${WIFI_UUID})."
else
    info "WIFI_SSID not set — skipping Wi-Fi configuration."
fi

# --------------------------- Create rom/root.tar.gz ---------------------------
info "Creating rom/root.tar.gz …"

tar \
    --numeric-owner \
    --preserve-permissions \
    --one-file-system \
    --use-compress-program="pigz -9 -p ${COMPRESSION_THREADS}" \
    -cf "${BUILD}/rom/root.tar.gz" \
    -C "${CHROOT}" \
    .

success "root.tar.gz created: $(du -sh ${BUILD}/rom/root.tar.gz | cut -f1)"

# --------------------------- Stage user-provided files ---------------------------
info "Staging manifest, rom_info.txt, and boot files …"

cp /input/manifest.txt           "${BUILD}/manifest.txt"
cp /input/root_dir/rom_info.txt  "${BUILD}/root_dir/rom_info.txt"
rsync -a /input/root_dir/boot/   "${BUILD}/root_dir/boot/"

success "Files staged."

# --------------------------- Assemble .mrom ZIP ---------------------------
info "Building ${OUTPUT_FILE} …"

(
    cd "${BUILD}"
    zip -0 -r "${OUTPUT_FILE}" \
        manifest.txt    \
        pre_install/    \
        post_install/   \
        rom/            \
        root_dir/
)

success "Done! Output: ${OUTPUT_FILE}  ($(du -sh ${OUTPUT_FILE} | cut -f1))"
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗"
echo -e "║  .mrom package is ready in your output/ directory.      ║"
echo -e "║  Flash it via TWRP → Advanced → MultiROM → Add ROM      ║"
echo -e "╚══════════════════════════════════════════════════════════╝${RESET}"
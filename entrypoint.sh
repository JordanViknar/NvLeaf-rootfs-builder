#!/usr/bin/env bash
set -euo pipefail

# Install build dependencies
echo "[setup] Installing build tools…"
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

# Colour helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# --------------------------- Configuration ---------------------------
UBUNTU_SUITE="${UBUNTU_SUITE:-jammy}"
TARGET_ARCH="${TARGET_ARCH:-armhf}"

# archive.ubuntu.com only carries amd64 and i386.
# All other architectures (armhf, arm64, etc.) live on ports.ubuntu.com.
case "${TARGET_ARCH}" in
    amd64|i386) _DEFAULT_MIRROR="http://archive.ubuntu.com/ubuntu" ;;
    *)          _DEFAULT_MIRROR="http://ports.ubuntu.com/ubuntu-ports" ;;
esac
UBUNTU_MIRROR="${UBUNTU_MIRROR:-${_DEFAULT_MIRROR}}"

ROM_NAME="${ROM_NAME:-ubuntu-22.04-xfce}"
OUTPUT_FILE="${OUTPUT_FILE:-/output/${ROM_NAME}.mrom}"

CHROOT=/chroot
BUILD=/build
COMPRESSION_THREADS="$(nproc)"

# --------------------------- STEP 0 — Validate required inputs ---------------------------
info "Validating inputs …"

[[ -f /input/manifest.txt ]] \
    || die "/input/manifest.txt not found."
[[ -f /input/root_dir/rom_info.txt ]] \
    || die "/input/root_dir/rom_info.txt not found."
[[ -d /input/root_dir/boot ]] \
    || die "/input/root_dir/boot/ directory not found."
KERNEL_COUNT=$(find /input/root_dir/boot -maxdepth 1 -type f | wc -l)
[[ "$KERNEL_COUNT" -ge 1 ]] \
    || die "/input/root_dir/boot/ is empty — place your kernel (and initrd) there."

success "Input validation passed."

#  --------------------------- STEP 1 — Mount binfmt_misc and register qemu ---------------------------
info "Mounting binfmt_misc and registering qemu for ${TARGET_ARCH} …"

case "${TARGET_ARCH}" in
    armhf|armel) QEMU_BIN=/usr/bin/qemu-arm-static ;;
    arm64)       QEMU_BIN=/usr/bin/qemu-aarch64-static ;;
    *)           QEMU_BIN="" ;;
esac

if [[ -n "${QEMU_BIN}" ]]; then
    [[ -f "${QEMU_BIN}" ]] \
        || die "${QEMU_BIN} not found — qemu-user-static may not support ${TARGET_ARCH}."

    # Mount binfmt_misc if not already visible
    if ! mountpoint -q /proc/sys/fs/binfmt_misc 2>/dev/null; then
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
    fi

    # Register all qemu-user-static handlers (includes qemu-arm-static)
    update-binfmts --enable

    success "binfmt_misc mounted and qemu registered (${QEMU_BIN})."
else
    success "Native arch — no qemu needed."
fi

# --------------------------- STEP 2 — Prepare build directories ---------------------------
mkdir -p \
    "${CHROOT}" \
    "${BUILD}/rom" \
    "${BUILD}/root_dir" \
    "${BUILD}/pre_install" \
    "${BUILD}/post_install"

# --------------------------- STEP 3 — Write mmdebstrap hook scripts ---------------------------
# setup hook: runs before package installation
# Adds -updates and -security suites so Xfce and friends can be installed.
SETUP_HOOK=$(mktemp /tmp/mmdebstrap-setup-XXXXXX.sh)
cat > "${SETUP_HOOK}" <<HOOK
#!/bin/sh
set -e
cat >> "\$1/etc/apt/sources.list" <<SOURCES
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE}-updates main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE}-security main restricted universe multiverse
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

chroot "$1" /bin/bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    # Locale + timezone
    echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
    locale-gen
    update-locale LANG=en_US.UTF-8
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime

    # Enable network
    systemctl enable NetworkManager || true
	# Enable touchscreen & UDC
	systemctl enable nvleaf-touchscreen.service || true
	systemctl enable nvleaf-tegra-udc.service || true

    # Default user
    id ubuntu &>/dev/null || useradd -m -s /bin/bash -G sudo,video,audio,input ubuntu
    echo 'ubuntu:ubuntu' | chpasswd
    passwd -e ubuntu

    # Hostname
    echo 'ubuntu-multirom' > /etc/hostname
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tubuntu-multirom\n' > /etc/hosts
"
# Note: apt cache / package lists are cleaned by mmdebstrap itself after
# all hooks complete — no need to do it here.
HOOK
chmod +x "${CUSTOMIZE_HOOK}"

# --------------------------- STEP 4 — Bootstrap + install everything via mmdebstrap ---------------------------
info "Running mmdebstrap for Ubuntu ${UBUNTU_SUITE} / ${TARGET_ARCH} …"
info "Mirror: ${UBUNTU_MIRROR}"

mmdebstrap \
    --mode=auto \
    --variant=minbase \
    --architectures="${TARGET_ARCH}" \
    --components="main,restricted,universe,multiverse" \
    --include="systemd,dbus,udev,accountsservice,sudo,locales,\
xfce4,xfce4-terminal,xfce4-goodies,\
lightdm,lightdm-gtk-greeter,\
xorg,dbus-x11,at-spi2-core,xserver-xorg-video-fbdev,\
fonts-dejavu-core,\
network-manager,network-manager-gnome,\
pulseaudio,pavucontrol,\
thunar,mousepad,ristretto,evince" \
    --setup-hook="${SETUP_HOOK} \"\$1\"" \
    --customize-hook="${CUSTOMIZE_HOOK} \"\$1\"" \
    "${UBUNTU_SUITE}" \
    "${CHROOT}" \
    "${UBUNTU_MIRROR}"

rm -f "${SETUP_HOOK}" "${CUSTOMIZE_HOOK}"

success "mmdebstrap complete."

# --------------------------- STEP 5 — Create rom/root.tar.gz ---------------------------
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

# --------------------------- STEP 6 — Stage user-provided files ---------------------------
info "Staging manifest, rom_info.txt, and boot files …"

cp /input/manifest.txt           "${BUILD}/manifest.txt"
cp /input/root_dir/rom_info.txt  "${BUILD}/root_dir/rom_info.txt"
rsync -a /input/root_dir/boot/   "${BUILD}/root_dir/boot/"

success "Files staged."

# --------------------------- STEP 7 — Assemble the .mrom ZIP (store-only, no compression) ---------------------------
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
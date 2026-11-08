#!/bin/bash
# =============================================================================
# Chimera Linux Automated Installation Script
# Based on: https://chimera-linux.org/docs/
#
# Usage: ./chimera-install-auto.sh <chimera.iso>
#
# Env vars (override defaults):
#   CHIMERA_DESKTOP=gnome|kde      (default: gnome)
#   CHIMERA_KERNEL=stable|lts      (default: stable per user request)
#   CHIMERA_ZFS=1|0                (default: 0)
#   CHIMERA_ENCRYPT=1|0            (default: 0)
#   ZRAM_SIZE="50%" | "4G"         (default: 50%)
# =============================================================================
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
CHIMERA_ISO="${1:-}"
CHIMERA_DESKTOP="${CHIMERA_DESKTOP:-gnome}"
CHIMERA_KERNEL="${CHIMERA_KERNEL:-stable}"
CHIMERA_ZFS="${CHIMERA_ZFS:-0}"
CHIMERA_ENCRYPT="${CHIMERA_ENCRYPT:-0}"
ZRAM_SIZE="${ZRAM_SIZE:-50%}"
CHIMERA_USER="${CHIMERA_USER:-chimera}"
CHIMERA_PASSWORD="${CHIMERA_PASSWORD:-chimera}"
TARGET_DISK=""
ESP_PART=""
ROOT_PART=""
DRACUT_MODS=""

log()  { echo "[*] $*"; }
err()  { echo "[!] ERROR: $*" >&2; exit 1; }
warn() { echo "[!] WARN: $*" >&2; }

# ── Detect architecture ───────────────────────────────────────────────────────
ARCH="$(uname --m 2>/dev/null || echo x86_64)"
case "$ARCH" in
    x86_64|aarch64) ;;
    *) err "Unsupported architecture: $ARCH";;
esac
log "Architecture: $ARCH"

# ── Validate ISO argument ────────────────────────────────────────────────────
[[ -z "$CHIMERA_ISO" ]] && { echo "Usage: $0 <chimera.iso>"; exit 1; }

# ── Build module list for dracut early video ─────────────────────────────────
build_dracut_mods() {
    DRACUT_MODS="amdgpu ast vfio-pci"
}

# ── Step 1: Select target disk (interactive) ─────────────────────────────────
discover_disks() {
    echo "--- Available block devices ---"
    printf "    %-12s %-12s %s\n" "" "" ""
    local found=0
    for dev in /dev/sd* /dev/nvme*n* /dev/vd* /dev/hd*; do
        [[ -b "$dev" ]] || continue
        found=$((found + 1))
        sz="$(blockdev --getsize "$dev" 2>/dev/null | cut -d/ -f1 || echo "?")"
        printf "    %-12s %-12s %s\n" "$dev" "${sz}B" ""
    done
    echo "    %-12s %-12s %s\n" "---" "---" "---"
    echo "Total block devices: $found"
}

select_disk() {
    while true; do
        discover_disks
        read -rp "Select target disk (/dev/sdX or /dev/nvmeXnY): " TARGET_DISK
        echo "${TARGET_DISK:-/dev/sda}"
    done
}

# ── Step 2: Wipe existing signatures ─────────────────────────────────────────
wipe_target() {
    log "Wiping existing signatures on $TARGET_DISK ..."
    wipefs -a "$TARGET_DISK" 2>/dev/null || true
    vgchange -an 2>/dev/null || true
    mdadm --zero-super --all 2>/dev/null || true
    log "Wipe complete."
}

# ── Step 3: Partition GPT disk ──────────────────────────────────────────────
partition_disk() {
    log "Creating GPT partition table on $TARGET_DISK ..."
    parted --script "$TARGET_DISK" mklabel gpt

    log "Creating ESP partition (512 MiB, FAT32)..."
    parted --script "$TARGET_DISK" mkpart EFI fat32 1MiB 513MiB
    parted --script "$TARGET_DISK" set 1 esp on

    log "Creating rootbtrfs partition (rest of disk)..."
    parted --script "$TARGET_DISK" mkpart root btrfs 513MiB 100%

    # Label partitions for unambiguous crypttab/fstab identification
    sgdisk --attributes=1 set:partlabel=EFI "$TARGET_DISK" 2>/dev/null || true
    sgdisk --attributes=2 set:partlabel=root "$TARGET_DISK" 2>/dev/null || true

    ESP_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
    log "ESP:     $ESP_PART"
    log "Root:    $ROOT_PART"
}

# ── Step 4: Format partitions ───────────────────────────────────────────────
format_parts() {
    log "Formatting ESP as FAT32..."
    mkfs.vfat -F32 "$ESP_PART" 2>/dev/null || warn "mkfs.vfat failed"

    log "Creating btrfs filesystem on root partition..."
    mkfs.btrfs -f -m0 -o no-xattr "$ROOT_PART" 2>/dev/null || warn "mkfs.btrfs failed"

    log "Mounting partitions..."
    mkdir -p /mnt/root
    mount "$ROOT_PART" /mnt/root || err "Mount failed: $ROOT_PART"
    mkdir -p /mnt/root/boot/efi
    mount "$ESP_PART" /mnt/root/boot/efi || err "Mount ESP failed: $ESP_PART"
    chmod 755 /mnt/root
    log "Format & mount complete."
}

# ── Step 5: Install Chimera locally via chimera-bootstrap ────────────────────
local_install() {
    log "Running chimera-bootstrap for local install (-l)..."
    chimera-bootstrap -l /mnt/root || err "chimera-bootstrap failed"
    chmod 755 /mnt/root
    log "Local install complete."
}

# ── Write post-install configuration script INTO the chroot ───────────────────
post_install_config() {
    # Write all config into a script file that runs inside the chroot
    local cfg="/tmp/chimera-postinstall.sh"
    cat > "$cfg" <<CFGEOF
#!/bin/bash
set -euo pipefail
CFGEOF

    echo '# --- Post-installation configuration ---' >> "$cfg"
    echo 'apk update' >> "$cfg"
    echo 'apk upgrade --available' >> "$cfg"
    echo 'apk del base-live 2>/dev/null || true' >> "$cfg"

    # Kernel
    if [[ ${CHIMERA_KERNEL} == "stable" ]]; then
        echo "apk add linux-stable" >> "$cfg"
    else
        echo "apk add linux-lts" >> "$cfg"
    fi

    # ZFS
    if [[ ${CHIMERA_ZFS} == "1" ]]; then
        echo "apk add linux-${CHIMERA_KERNEL}-zfs-bin zfs" >> "$cfg"
    fi

    # Bootloader packages
    case "${CHIMERA_KERNEL}" in
        stable|lts)
            case "${CHIMERA_BOOTLOADER:-grub}" in
                grub) echo "apk add grub-x86_64-efi grub-i386-pc" >> "$cfg";;
                systemd-boot) echo "apk add systemd-boot" >> "$cfg";;
            esac;;
    esac

    # User
    echo "useradd -m -s /bin/bash -G wheel,kvm,plugdev ${CHIMERA_USER}" >> "$cfg"
    # passwd must send two lines
    passwd "${CHIMERA_USER}" <<PASSWDEOF
${CHIMERA_PASSWORD}
${CHIMERA_PASSWORD}
PASSWDEOF

# Hostname
echo "echo chimera > /etc/hostname" >> "$cfg"

# Timezone
echo "ln -sf /usr/share/zoneinfo/UTC /etc/localtime" >> "$cfg"

# fstab
echo "genfstab -U / >> /etc/fstab" >> "$cfg"

# Encryption crypttab
if [[ ${CHIMERA_ENCRYPT} == "1" ]]; then
    echo "echo 'crypt PARTLABEL=root none luks,discard' >> /etc/crypttab" >> "$cfg"
    echo "echo GRUB_ENABLE_CRYPTODISK=y >> /etc/default/grub" >> "$cfg"
fi

# Early video modules
for m in amdgpu ast; do
    echo "echo $m >> /etc/initramfs-tools/modules" >> "$cfg"
done

# Initramfs refresh
echo "update-initramfs -c -k all" >> "$cfg"

# GRUB bootloader install
if command -v grub-install >/dev/null 2>&1; then
    echo "mkdir -p /boot/efi" >> "$cfg"
    echo "mount $ESP_PART /boot/efi 2>/dev/null || true" >> "$cfg"
    echo "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=chimera --no-nvram --removable 2>/dev/null || true" >> "$cfg"
    echo "update-grub" >> "$cfg"
fi

# Desktop environment
case "${CHIMERA_DESKTOP}" in
    gnome)
        echo "apk add gnome gdm elogind dbus" >> "$cfg"
        echo "apk mask gnome-apps || true" >> "$cfg"
        echo "dinitctl enable gdm 2>/dev/null || true" >> "$cfg"
        ;;
    kde)
        echo "apk add plasma-desktop sddm" >> "$cfg"
        echo "dinitctl enable sddm 2>/dev/null || true" >> "$cfg"
        ;;
esac

# Xorg support
echo "apk add xserver-xorg 2>/dev/null || true" >> "$cfg"

# Sound (PipeWire)
echo "apk add pipewire wireplumber 2>/dev/null || true" >> "$cfg"
echo "dinitctl enable pipewire wireplumber 2>/dev/null || true" >> "$cfg"

# Network management
echo "apk add networkmanager dhcpcd iwd 2>/dev/null || true" >> "$cfg"
echo "dinitctl enable networkmanager dhcpcd iwd 2>/dev/null || true" >> "$cfg"

# ZRAM configuration
echo "ALGO=zstd" >> "$cfg"
echo "PERCENT=${ZRAM_SIZE}" >> "$cfg"
echo "PRIORITY=100" >> "$cfg"
echo "DESC='zram swap area'" >> "$cfg"
echo "echo zram > /etc/modules-load.d/zram.conf" >> "$cfg"

# Cleanup
echo "apk fix" >> "$cfg"
echo "apk clean --unneeded" >> "$cfg"

echo "=== All post-install configuration complete ==="
CFGEOF

    log "Writing post-install configuration to $cfg ..."
    chimera-chroot /mnt/root < "$cfg" || err "chimera-chroot post-install failed"
    log "Post-install configuration complete."
    rm -f "$cfg"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    log "=== Chimera Linux Automated Installation ==="
    log "ISO:         $CHIMERA_ISO"
    log "Desktop:     $CHIMERA_DESKTOP"
    log "Kernel:      $CHIMERA_KERNEL"
    log "ZFS:         $CHIMERA_ZFS"
    log "Encryption:  $CHIMERA_ENCRYPT"
    log "ZRAM size:   $ZRAM_SIZE"

    build_dracut_mods

    wipe_target
    partition_disk
    format_parts
    local_install
    post_install_config

    echo ""
    echo "[+] Installation complete!"
    echo "    Target disk: $TARGET_DISK"
    echo "    Reboot:"
    echo "        reboot"
}

main "$@"

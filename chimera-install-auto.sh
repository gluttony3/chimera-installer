#!/bin/sh
# =============================================================================
# Chimera Linux Automated Installation Script
# Filesystem: Btrfs (subvolumes: @, @home, @snapshots, @var_log)
# Kernel: linux-stable + base-full-firmware (out of the box hardware support)
# Bootloader: Limine (UEFI + BIOS compatibility, auto-updating kernel hook)
# Desktops: GNOME or KDE Plasma
# Memory: ZRAM swap with zstd compression
# Init System: dinit
# Documentation: https://chimera-linux.org/docs/
# =============================================================================

set -eu

# Color output
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

log()  { printf "%b[*] %s%b\n" "$GREEN" "$*" "$RESET"; }
warn() { printf "%b[!] WARN: %s%b\n" "$YELLOW" "$*" "$RESET" >&2; }
err()  { printf "%b[!] ERROR: %s%b\n" "$RED" "$*" "$RESET" >&2; exit 1; }

# Check root privileges
if [ "$(id -u)" != "0" ]; then
    err "This installer must be run as root (use 'doas sh $0')"
fi

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|aarch64) ;;
    *) err "Unsupported architecture: $ARCH (supported: x86_64, aarch64)" ;;
esac

log "Chimera Linux Automated Installer initialized (Arch: $ARCH)"

# =============================================================================
# Helper Functions
# =============================================================================

prompt_default() {
    local prompt="$1"
    local default="$2"
    local answer=""
    printf "%b%s%b [%s]: " "$CYAN" "$prompt" "$RESET" "$default" >&2
    read -r answer
    if [ -z "$answer" ]; then
        echo "$default"
    else
        echo "$answer"
    fi
}

prompt_password() {
    local prompt="$1"
    local pass1=""
    local pass2=""
    while :; do
        printf "%b%s: %b" "$CYAN" "$prompt" "$RESET" >&2
        stty -echo 2>/dev/null || true
        read -r pass1
        stty echo 2>/dev/null || true
        printf "\n" >&2
        if [ -z "$pass1" ]; then
            warn "Password cannot be empty. Please re-enter."
            continue
        fi
        printf "%bConfirm %s: %b" "$CYAN" "$prompt" "$RESET" >&2
        stty -echo 2>/dev/null || true
        read -r pass2
        stty echo 2>/dev/null || true
        printf "\n" >&2
        if [ "$pass1" = "$pass2" ]; then
            echo "$pass1"
            return 0
        else
            warn "Passwords do not match. Please try again."
        fi
    done
}

# =============================================================================
# Disk Discovery & Selection
# =============================================================================

select_target_disk() {
    printf "\n%b=== Available Storage Devices ===%b\n" "$BOLD" "$RESET"
    
    local devs=""
    local idx=1
    
    # Use lsblk to discover block devices of type 'disk'
    for d in $(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
        # Ignore loop, zram, ram devices
        case "$d" in
            loop*|zram*|ram*) continue ;;
        esac
        local full_dev="/dev/$d"
        local size model
        size=$(lsblk -d -n -o SIZE "$full_dev" 2>/dev/null || echo "Unknown")
        model=$(lsblk -d -n -o MODEL "$full_dev" 2>/dev/null || echo "Generic Disk")
        printf "  %b[%d]%b %-16s %-10s %s\n" "$BOLD" "$idx" "$RESET" "$full_dev" "$size" "$model"
        eval "dev_$idx=\"$full_dev\""
        idx=$((idx + 1))
    done
    
    total_devs=$((idx - 1))
    if [ "$total_devs" -eq 0 ]; then
        err "No usable storage disks found in the system!"
    fi
    
    while :; do
        printf "\nSelect the target disk for installation [1-%d]: " "$total_devs"
        read -r choice
        case "$choice" in
            [1-9]*)
                if [ "$choice" -ge 1 ] && [ "$choice" -le "$total_devs" ]; then
                    eval "TARGET_DISK=\$dev_$choice"
                    break
                fi
                ;;
            /dev/*)
                if [ -b "$choice" ]; then
                    TARGET_DISK="$choice"
                    break
                fi
                ;;
        esac
        warn "Invalid selection. Please choose a valid disk number or path."
    done
    
    printf "\n%bWARNING: ALL DATA ON %s WILL BE COMPLETELY DESTROYED!%b\n" "$RED$BOLD" "$TARGET_DISK" "$RESET"
    printf "Are you sure you want to proceed? [yes/NO]: "
    read -r confirm
    case "$confirm" in
        yes|YES|y|Y) ;;
        *) err "Installation aborted by user." ;;
    esac
}

# =============================================================================
# Interactive Configuration Prompts
# =============================================================================

configure_installation() {
    printf "\n%b=== Installation Configuration ===%b\n" "$BOLD" "$RESET"
    
    # 1. Desktop Environment
    printf "\n%bSelect Desktop Environment:%b\n" "$BOLD" "$RESET"
    printf "  1) GNOME (Default - modern Wayland desktop)\n"
    printf "  2) KDE Plasma (Fast, highly customizable Qt desktop)\n"
    while :; do
        local de_choice
        de_choice=$(prompt_default "Select desktop" "1")
        case "$de_choice" in
            1|gnome|GNOME) CHIMERA_DESKTOP="gnome"; break ;;
            2|kde|KDE|plasma) CHIMERA_DESKTOP="kde"; break ;;
            *) warn "Please enter 1 or 2." ;;
        esac
    done
    
    # 2. Hostname
    CHIMERA_HOSTNAME=$(prompt_default "Enter system hostname" "chimera")
    
    # 3. Timezone
    local def_tz="UTC"
    if [ -f /etc/timezone ]; then
        def_tz=$(cat /etc/timezone)
    elif [ -h /etc/localtime ]; then
        def_tz=$(readlink /etc/localtime | sed 's,.*/zoneinfo/,,')
    fi
    CHIMERA_TIMEZONE=$(prompt_default "Enter timezone" "$def_tz")
    
    # 4. User Account
    CHIMERA_USER=$(prompt_default "Enter primary username (will have doas/admin privileges)" "chimera")
    CHIMERA_USER_PASS=$(prompt_password "Enter password for '$CHIMERA_USER'")
    
    # 5. Root Password
    printf "Do you want to use the same password for 'root'? [Y/n]: "
    read -r same_root_pass
    case "${same_root_pass:-y}" in
        y|Y|yes|YES)
            CHIMERA_ROOT_PASS="$CHIMERA_USER_PASS"
            ;;
        *)
            CHIMERA_ROOT_PASS=$(prompt_password "Enter password for 'root'")
            ;;
    esac
    
    # 6. ZRAM Size
    while :; do
        ZRAM_SIZE=$(prompt_default "Enter ZRAM size (percentage of RAM or absolute size, e.g., 50% or 4G)" "50%")
        case "$ZRAM_SIZE" in
            *%) break ;;
            *[0-9]G|*[0-9]M) break ;;
            *) warn "Invalid format. Examples: 50%, 75%, 4G, 8G" ;;
        esac
    done
    
    printf "\n%b--- Summary of Installation Settings ---%b\n" "$GREEN" "$RESET"
    printf "  Target Disk:  %s\n" "$TARGET_DISK"
    printf "  Filesystem:   Btrfs (@, @home, @snapshots, @var_log) + zstd\n"
    printf "  Bootloader:   Limine (UEFI + BIOS)\n"
    printf "  Kernel:       linux-stable + base-full-firmware\n"
    printf "  Desktop:      %s\n" "$CHIMERA_DESKTOP"
    printf "  Hostname:     %s\n" "$CHIMERA_HOSTNAME"
    printf "  Timezone:     %s\n" "$CHIMERA_TIMEZONE"
    printf "  Username:     %s (in wheel group)\n" "$CHIMERA_USER"
    printf "  ZRAM:         %s (zstd compression)\n" "$ZRAM_SIZE"
    printf "\nReady to proceed with installation? [y/N]: "
    read -r final_confirm
    case "$final_confirm" in
        y|Y|yes|YES) ;;
        *) err "Installation canceled by user." ;;
    esac
}

# =============================================================================
# Partitioning and Formatting (Btrfs Layout)
# =============================================================================

prepare_disk() {
    log "Preparing target disk $TARGET_DISK..."
    
    # Unmount /mnt if already mounted
    umount -R /mnt 2>/dev/null || true
    
    # Unmount any existing mounts on target disk
    log "Unmounting any existing partitions on $TARGET_DISK..."
    for part in $(lsblk -n -o PATH "$TARGET_DISK" 2>/dev/null); do
        if [ "$part" != "$TARGET_DISK" ]; then
            umount -f "$part" 2>/dev/null || true
        fi
    done
    
    # Wipe signatures
    log "Wiping existing signatures on $TARGET_DISK..."
    wipefs -a -f "$TARGET_DISK" 2>/dev/null || true
    
    # Create GPT partition table with sfdisk
    # Partition 1: 1024M EFI System Partition (type U)
    # Partition 2: Rest of disk for Linux filesystem (type L)
    log "Writing GPT partition table (1 GiB ESP + rest Btrfs)..."
    printf 'label: gpt\nsize=1024M, type=U, name="EFI System Partition"\ntype=L, name="Chimera Root"\n' | sfdisk --wipe always "$TARGET_DISK"
    
    # Wait for kernel to register partitions
    udevadm settle 2>/dev/null || sleep 2
    
    # Determine partition names (handling nvme/mmc vs sd/vd)
    if echo "$TARGET_DISK" | grep -qE '[0-9]$'; then
        ESP_PART="${TARGET_DISK}p1"
        ROOT_PART="${TARGET_DISK}p2"
    else
        ESP_PART="${TARGET_DISK}1"
        ROOT_PART="${TARGET_DISK}2"
    fi
    
    log "ESP Partition:  $ESP_PART"
    log "Root Partition: $ROOT_PART"
    
    # Format ESP partition
    log "Formatting ESP partition as FAT32..."
    mkfs.vfat -F32 -n "ESP" "$ESP_PART"
    
    # Format Root partition with Btrfs
    log "Formatting root partition as Btrfs..."
    mkfs.btrfs -f -L "chimera" "$ROOT_PART"
    
    # Create Btrfs subvolumes layout
    log "Creating Btrfs subvolumes (@, @home, @snapshots, @var_log)..."
    local tmp_mnt="/mnt/chimera-btrfs-setup"
    mkdir -p "$tmp_mnt"
    mount "$ROOT_PART" "$tmp_mnt"
    
    btrfs subvolume create "$tmp_mnt/@"
    btrfs subvolume create "$tmp_mnt/@home"
    btrfs subvolume create "$tmp_mnt/@snapshots"
    btrfs subvolume create "$tmp_mnt/@var_log"
    
    umount "$tmp_mnt"
    rmdir "$tmp_mnt"
    
    # Mount target filesystem tree at /mnt
    log "Mounting subvolumes with zstd compression to /mnt..."
    mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" /mnt
    
    mkdir -p /mnt/home /mnt/.snapshots /mnt/var/log /mnt/boot
    mount -o noatime,compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
    mount -o noatime,compress=zstd,subvol=@snapshots "$ROOT_PART" /mnt/.snapshots
    mount -o noatime,compress=zstd,subvol=@var_log "$ROOT_PART" /mnt/var/log
    
    # Mount ESP at /boot so kernels and Limine live together
    mount "$ESP_PART" /mnt/boot
    
    chmod 755 /mnt
    log "Disk partitioning and mounting complete."
}

# =============================================================================
# Bootstrap System
# =============================================================================

bootstrap_system() {
    log "Bootstrapping Chimera Linux to /mnt..."
    
    # Run official chimera-bootstrap with local cache from live media
    chimera-bootstrap -l /mnt
    
    # Generate /etc/fstab with UUIDs
    log "Generating /etc/fstab..."
    genfstab -U /mnt > /mnt/etc/fstab
    
    log "Bootstrap completed successfully."
}

# =============================================================================
# Post-Installation & Out-of-the-Box Configuration
# =============================================================================

configure_target_system() {
    log "Performing post-installation configuration in chroot..."
    
    # Copy mirror configuration if present
    if [ -f /etc/apk/repositories ]; then
        cp /etc/apk/repositories /mnt/etc/apk/repositories
    fi
    
    # Ensure DNS works inside chroot
    if [ -f /etc/resolv.conf ]; then
        cp -L /etc/resolv.conf /mnt/etc/resolv.conf 2>/dev/null || true
    fi
    
    # Get Root Partition UUID for Limine kernel cmdline
    local root_uuid
    root_uuid=$(blkid -s UUID -o value "$ROOT_PART")
    
    # Assemble packages list
    local core_pkgs="linux-stable base-full-firmware btrfs-progs dosfstools limine efibootmgr networkmanager networkmanager-dinit turnstile pipewire wireplumber elogind dbus util-linux-zramctl"
    local de_pkgs=""
    local de_service=""
    
    if [ "$CHIMERA_DESKTOP" = "gnome" ]; then
        de_pkgs="gnome gdm gdm-dinit"
        de_service="gdm"
    else
        de_pkgs="plasma-desktop plasma-workspace plasma-nm sddm sddm-dinit sddm-default-kwin konsole dolphin"
        de_service="sddm"
    fi
    
    # Write internal post-install script into target /root (avoids tmpfs mounts masking /tmp)
    cat << 'EOF' > /mnt/root/chimera_setup_internal.sh
#!/bin/sh
set -eu

DESKTOP="$1"
HOSTNAME="$2"
TIMEZONE="$3"
USERNAME="$4"
USER_PASS="$5"
ROOT_PASS="$6"
ZRAM_SIZE="$7"
ROOT_UUID="$8"
TARGET_DISK="$9"
CORE_PKGS="${10}"
DE_PKGS="${11}"
DE_SERVICE="${12}"

echo "[*] Target: Updating package repository..."
apk update

echo "[*] Target: Removing live-environment packages..."
echo "y" | apk del --no-interactive base-live 2>/dev/null || true

echo "[*] Target: Installing core and desktop packages..."
# shellcheck disable=SC2086
echo "y" | apk add --no-interactive $CORE_PKGS $DE_PKGS

# -----------------------------------------------------------------------------
# Hostname & Timezone
# -----------------------------------------------------------------------------
echo "[*] Target: Configuring hostname and timezone..."
echo "$HOSTNAME" > /etc/hostname
if [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
fi

# -----------------------------------------------------------------------------
# User & Authentication
# -----------------------------------------------------------------------------
echo "[*] Target: Setting up user account and passwords..."
# Set root password
echo "root:$ROOT_PASS" | chpasswd -c SHA512

# Create primary user with wheel and desktop groups
if ! id "$USERNAME" >/dev/null 2>&1; then
    useradd -m -s /bin/sh -G wheel,audio,video,input,kvm,network,plugdev "$USERNAME"
fi
echo "$USERNAME:$USER_PASS" | chpasswd -c SHA512

# Configure /etc/doas.conf for wheel group
mkdir -p /etc/doas.d
cat << 'DOASEOF' > /etc/doas.conf
# /etc/doas.conf
permit persist :wheel
permit nopass root
permit nopass keepenv setenv { PATH } root as root
DOASEOF
chmod 600 /etc/doas.conf

# -----------------------------------------------------------------------------
# ZRAM Service (Native dinit integration)
# -----------------------------------------------------------------------------
echo "[*] Target: Configuring ZRAM with zstd compression..."
cat << ZRAMCFG > /etc/default/zram
ZRAM_SIZE="$ZRAM_SIZE"
ZRAM_ALGO="zstd"
ZRAM_PRIO="100"
ZRAMCFG

cat << 'ZRAMSH' > /usr/local/bin/zram-setup
#!/bin/sh
set -eu

ZRAM_SIZE="50%"
ZRAM_ALGO="zstd"
ZRAM_PRIO="100"

if [ -f /etc/default/zram ]; then
    . /etc/default/zram
fi

case "${1:-start}" in
    start)
        modprobe zram 2>/dev/null || true
        total_mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
        
        # Calculate size in bytes
        case "$ZRAM_SIZE" in
            *%)
                pct=$(echo "$ZRAM_SIZE" | tr -d '%')
                bytes=$(( total_mem_kb * 1024 * pct / 100 ))
                ;;
            *G)
                gb=$(echo "$ZRAM_SIZE" | tr -d 'G')
                bytes=$(( gb * 1024 * 1024 * 1024 ))
                ;;
            *M)
                mb=$(echo "$ZRAM_SIZE" | tr -d 'M')
                bytes=$(( mb * 1024 * 1024 ))
                ;;
            *)
                bytes=$(( total_mem_kb * 1024 / 2 ))
                ;;
        esac
        
        # Set compression algorithm (fallback to lzo if zstd unsupported)
        echo "$ZRAM_ALGO" > /sys/block/zram0/comp_algorithm 2>/dev/null || \
            echo "lzo" > /sys/block/zram0/comp_algorithm 2>/dev/null || true
            
        echo "$bytes" > /sys/block/zram0/disksize
        mkswap -L zram0 /dev/zram0 >/dev/null
        swapon -p "$ZRAM_PRIO" /dev/zram0
        echo "zram: enabled swap on /dev/zram0 (size: ${bytes} bytes)"
        ;;
    stop)
        swapoff /dev/zram0 2>/dev/null || true
        echo 1 > /sys/block/zram0/reset 2>/dev/null || true
        ;;
esac
ZRAMSH
chmod +x /usr/local/bin/zram-setup

cat << 'ZRAMSVC' > /etc/dinit.d/zram-swap
type = scripted
command = /usr/local/bin/zram-setup start
stop-command = /usr/local/bin/zram-setup stop
depends-on: early-devd
before: early-fs-pre.target
ZRAMSVC

# Enable zram-swap service in dinit
dinitctl -o enable zram-swap

# -----------------------------------------------------------------------------
# Services Activation
# -----------------------------------------------------------------------------
echo "[*] Target: Enabling NetworkManager and Display Manager ($DE_SERVICE)..."
dinitctl -o enable networkmanager
dinitctl -o enable "$DE_SERVICE"

# -----------------------------------------------------------------------------
# Initramfs & Limine Bootloader Setup
# -----------------------------------------------------------------------------
echo "[*] Target: Installing Limine kernel hook..."
mkdir -p /etc/kernel.d
cat << 'LIMHOOK' > /etc/kernel.d/99-limine.sh
#!/bin/sh
# Limine bootloader auto-configuration hook

ROOT_DEV=$(findmnt -no SOURCE / 2>/dev/null || echo "")
ROOT_UUID=""
if [ -n "$ROOT_DEV" ]; then
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)
fi
if [ -z "$ROOT_UUID" ]; then
    ROOT_UUID=$(findmnt -no UUID / 2>/dev/null || echo "")
fi

KPATH=$(ls -t /boot/vmlinuz-* 2>/dev/null | head -n1 || true)
[ -n "$KPATH" ] || exit 0
KFILE=$(basename "$KPATH")
KVER=${KFILE#vmlinuz-}
IFILE="initrd.img-${KVER}"
if [ ! -f "/boot/${IFILE}" ]; then
    IFILE=$(ls -t /boot/initrd.img-* 2>/dev/null | head -n1 | xargs -r basename || echo "")
fi

cat << LIMEOF > /boot/limine.conf
timeout: 5

/Chimera Linux (stable)
    protocol: linux
    kernel_path: boot():/${KFILE}
    module_path: boot():/${IFILE}
    cmdline: root=UUID=${ROOT_UUID} rootflags=subvol=@ rw quiet splash
LIMEOF

# Ensure UEFI boot files are synchronized
mkdir -p /boot/EFI/BOOT /boot/EFI/limine
if [ -f /usr/share/limine/BOOTX64.EFI ]; then
    cp -u /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI 2>/dev/null || cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
    cp -u /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/limine.efi 2>/dev/null || cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/limine.efi
elif [ -f /usr/share/limine/BOOTAA64.EFI ]; then
    cp -u /usr/share/limine/BOOTAA64.EFI /boot/EFI/BOOT/BOOTAA64.EFI 2>/dev/null || cp /usr/share/limine/BOOTAA64.EFI /boot/EFI/BOOT/BOOTAA64.EFI
    cp -u /usr/share/limine/BOOTAA64.EFI /boot/EFI/limine/limine.efi 2>/dev/null || cp /usr/share/limine/BOOTAA64.EFI /boot/EFI/limine/limine.efi
fi
LIMHOOK
chmod +x /etc/kernel.d/99-limine.sh

# Regenerate initramfs and trigger hooks
echo "[*] Target: Regenerating initramfs..."
update-initramfs -c -k all

# Initial generation of limine.conf and UEFI binaries
/etc/kernel.d/99-limine.sh

# Register UEFI entry with efibootmgr
echo "[*] Target: Registering UEFI entry..."
efibootmgr -c -d "$TARGET_DISK" -p 1 -l '\EFI\limine\limine.efi' -L "Chimera Linux" 2>/dev/null || true

# Install BIOS Limine stage for hybrid/BIOS support
echo "[*] Target: Installing BIOS Limine stage..."
limine bios-install "$TARGET_DISK" 2>/dev/null || true

echo "[*] Target: Configuration finished successfully!"
EOF

    chmod +x /mnt/root/chimera_setup_internal.sh
    
    # Run the setup script inside the chroot
    chimera-chroot /mnt /root/chimera_setup_internal.sh \
        "$CHIMERA_DESKTOP" \
        "$CHIMERA_HOSTNAME" \
        "$CHIMERA_TIMEZONE" \
        "$CHIMERA_USER" \
        "$CHIMERA_USER_PASS" \
        "$CHIMERA_ROOT_PASS" \
        "$ZRAM_SIZE" \
        "$root_uuid" \
        "$TARGET_DISK" \
        "$core_pkgs" \
        "$de_pkgs" \
        "$de_service"
        
    rm -f /mnt/root/chimera_setup_internal.sh
    log "Post-installation configuration complete."
}

# =============================================================================
# Clean Unmount & Finalize
# =============================================================================

finalize_installation() {
    log "Synchronizing disks and unmounting target filesystem..."
    sync
    umount -R /mnt 2>/dev/null || true
    
    printf "\n%b==============================================================%b\n" "$GREEN$BOLD" "$RESET"
    printf "%b Chimera Linux installation completed successfully!%b\n" "$GREEN$BOLD" "$RESET"
    printf "%b==============================================================%b\n\n" "$GREEN$BOLD" "$RESET"
    printf "System Summary:\n"
    printf "  - Target disk:       %s\n" "$TARGET_DISK"
    printf "  - Root Filesystem:   Btrfs with zstd subvolumes\n"
    printf "  - Kernel:            linux-stable (with base-full-firmware)\n"
    printf "  - Bootloader:        Limine (ESP on /boot, auto-updating)\n"
    printf "  - Desktop:           %s (%s)\n" "$CHIMERA_DESKTOP" "$( [ "$CHIMERA_DESKTOP" = "gnome" ] && echo "GDM" || echo "SDDM" )"
    printf "  - ZRAM:              %s (zstd compression)\n" "$ZRAM_SIZE"
    printf "  - Primary user:      %s\n\n" "$CHIMERA_USER"
    printf "You may now reboot into your new Chimera Linux system:\n"
    printf "  %bdoas reboot%b\n\n" "$BOLD" "$RESET"
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    select_target_disk
    configure_installation
    prepare_disk
    bootstrap_system
    configure_target_system
    finalize_installation
}

main "$@"

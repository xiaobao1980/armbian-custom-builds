# Rockchip RK3576 SoC octa core 8-64GB 2*GBe eMMC USB3 NVMe WiFi Bluetooth
# Neardi LZ200 Development Board
BOARD_NAME="Neardi LZ200"
BOARD_VENDOR="Neardi"
BOARDFAMILY="rk35xx"
BOOTCONFIG="neardi-lz200-linux-rk3576_defconfig"
KERNEL_TARGET="vendor,edge"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3576-neardi-lz200-linux.dtb"
BOOT_SCENARIO="spl-blobs"
IMAGE_PARTITION_TABLE="gpt"
LINUXCONFIG='linux-neardi-lz200-rk3576'
BOARD_MAINTAINER=""


# Additional kernel packages - 添加蓝牙支持包
PACKAGE_LIST_BOARD="rfkill bluetooth bluez bluez-tools pulseaudio-module-bluetooth"

function post_family_tweaks__neardi_lz200_wireless() {
    display_alert "$BOARD" "Configuring FD7352S WiFi & Bluetooth" "info"

    # ===== WiFi Configuration =====
    # Create udev rule for SeekWave SDIO WiFi timing
    mkdir -p $SDCARD/etc/udev/rules.d/
    cat > $SDCARD/etc/udev/rules.d/50-fd7352s.rules << 'EOF'
# SeekWave FD7352S SDIO WiFi module initialization delay
ACTION=="add", SUBSYSTEM=="module", KERNEL=="skw_sdio_v20", RUN+="/bin/sleep 3"
EOF

    # Install WiFi firmware if available in userpatches
    if [[ -d $USERPATCHES_PATH/neardi-lz200/wifi ]]; then
        display_alert "$BOARD" "Installing FD7352S WiFi firmware" "info"
        mkdir -p $SDCARD/lib/firmware/
        cp -r $USERPATCHES_PATH/neardi-lz200/wifi/* $SDCARD/lib/firmware/
    fi

    # ===== Bluetooth Configuration =====
    display_alert "$BOARD" "Configuring FD7352S Bluetooth" "info"

    # Install Bluetooth firmware if available
    if [[ -d $USERPATCHES_PATH/neardi-lz200/bluetooth ]]; then
        display_alert "$BOARD" "Installing FD7352S Bluetooth firmware" "info"
        mkdir -p $SDCARD/lib/firmware/
        cp -r $USERPATCHES_PATH/neardi-lz200/bluetooth/* $SDCARD/lib/firmware/
    fi

    # Create Bluetooth udev rules for proper device permissions
    cat > $SDCARD/etc/udev/rules.d/50-bluetooth-neardi.rules << 'EOF'
# Neardi LZ200 Bluetooth device permissions
# FD7352S Bluetooth UART module
SUBSYSTEM=="bluetooth", ACTION=="add", ATTR{power/control}="auto", TAG+="systemd"
KERNEL=="ttyS[0-9]*", SUBSYSTEM=="tty", ATTRS{id/vendor}=="1ffe", ATTRS{id/product}=="6316", MODE="0660", GROUP="bluetooth"
EOF

    # Create Bluetooth systemd service for FD7352S initialization
    mkdir -p $SDCARD/etc/systemd/system/
    cat > $SDCARD/etc/systemd/system/fd7352s-bluetooth.service << 'EOF'
[Unit]
Description=FD7352S Bluetooth Initialization
After=bluetooth.target systemd-udev-settle.service
Wants=bluetooth.target
Before=bluetooth.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Wait for UART to be ready
ExecStartPre=/bin/sleep 2
# Initialize Bluetooth via hciattach (adjust tty device as needed)
ExecStart=/usr/bin/hciattach -n -s 115200 /dev/ttyS4 any 115200 flow
# Or if using btattach for newer kernels:
# ExecStart=/usr/bin/btattach -B /dev/ttyS4 -P h4 -S 115200 &
ExecStop=/bin/kill -TERM $MAINPID
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # Enable the Bluetooth service
    chroot $SDCARD /bin/bash -c "systemctl enable fd7352s-bluetooth.service" || true

    # Ensure Bluetooth modules load on boot
    cat > $SDCARD/etc/modules-load.d/neardi-lz200.conf << 'EOF'
# Neardi LZ200 specific modules - WiFi
skw_sdio_v20
skw6316
# Neardi LZ200 specific modules - Bluetooth
skwbt
EOF

    # Bluetooth main.conf optimization
    mkdir -p $SDCARD/etc/bluetooth/
    cat > $SDCARD/etc/bluetooth/main.conf << 'EOF'
[General]
# Default adapter name
Name = Neardi LZ200

# Default device class (Computer - Laptop)
Class = 0x000100

# How long to stay in discoverable mode before going back to non-discoverable
# 0 = infinite, 1 = timer based on DiscoverableTimeout
DiscoverableTimeout = 180

# How long to stay in pairable mode before going back to non-pairable
# 0 = infinite, 1 = timer based on PairableTimeout
PairableTimeout = 0

# Use vendor specific extensions if available
# Some vendors support vendor extensions for improved functionality
Vendor = SeekWave

# Default Secure Simple Pairing mode. Possible values are:
# "auto" - Let the kernel decide
# "user" - User confirmation required
# "confirm" - Confirmation required (auto-accept if no input)
# "none" - No confirmation required
Pairing = auto

# Privacy feature. Possible values are:
# "off" - Disable privacy
# "network" - Enable privacy for network related operations
# "device" - Enable privacy for device related operations
# "all" - Enable privacy for all operations
Privacy = device

[Policy]
# AutoEnable defines default state for new adapters
AutoEnable=true

# Allow audio devices to connect without user confirmation
AllowAudioDevices=true

[LE]
# Minimum and maximum advertising interval in milliseconds
MinAdvertisementInterval=100
MaxAdvertisementInterval=2000

[GATT]
# Number of ATT channels
Channels=1

[Connection]
# Connection interval parameters for LE connections
MinConnectionInterval=7.5
MaxConnectionInterval=75
ConnectionLatency=0
EOF

    # Create bluetooth group if not exists
    chroot $SDCARD /bin/bash -c "getent group bluetooth || groupadd -r bluetooth" || true

    # Add default user to bluetooth group
    if [[ -n $SUDO_USER ]]; then
        chroot $SDCARD /bin/bash -c "usermod -aG bluetooth $SUDO_USER" || true
    fi

    # Ensure proper permissions for Bluetooth devices
    cat > $SDCARD/etc/udev/rules.d/99-bluetooth-hci.rules << 'EOF'
# Allow bluetooth group to access HCI devices
SUBSYSTEM=="bluetooth", GROUP="bluetooth", MODE="0660"
EOF

    # PulseAudio Bluetooth configuration for audio support
    if [[ -d $SDCARD/etc/pulse ]]; then
        mkdir -p $SDCARD/etc/pulse/default.pa.d/
        cat > $SDCARD/etc/pulse/default.pa.d/bluetooth.pa << 'EOF'
# Load Bluetooth modules
.ifexists module-bluetooth-policy.so
load-module module-bluetooth-policy
.endif

.ifexists module-bluetooth-discover.so
load-module module-bluetooth-discover
.endif
EOF
    fi

    # Ensure Bluetooth service is enabled
    chroot $SDCARD /bin/bash -c "systemctl enable bluetooth.service" || true

    return 0
}

# ===== First Boot Script: hold-kernel.sh =====
function post_family_tweaks__neardi_lz200_first_boot() {
    display_alert "$BOARD" "Setting up first boot script hold-kernel.sh" "info"

    # Create hold-kernel.sh script
    mkdir -p $SDCARD/usr/local/sbin/
    cat > $SDCARD/usr/local/sbin/hold-kernel.sh << 'EOF'
#!/bin/bash
#
# hold-kernel.sh - First boot script for Neardi LZ200
# Prevents automatic kernel updates to maintain driver compatibility
# This script runs only once on first boot
#

set -e

LOG_FILE="/var/log/hold-kernel.log"
KERNEL_VERSION=$(uname -r)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting hold-kernel.sh" | tee -a $LOG_FILE
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Current kernel: $KERNEL_VERSION" | tee -a $LOG_FILE

# Function to log messages
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# 1. Hold kernel packages to prevent automatic updates
log_msg "Holding kernel packages..."

# For Debian/Ubuntu systems using apt
if command -v apt-mark &> /dev/null; then
    # Hold kernel image and headers
    apt-mark hold linux-image-$KERNEL_VERSION 2>/dev/null || log_msg "Warning: Could not hold linux-image-$KERNEL_VERSION"
    apt-mark hold linux-headers-$KERNEL_VERSION 2>/dev/null || log_msg "Warning: Could not hold linux-headers-$KERNEL_VERSION"
    
    # Hold generic kernel packages if they exist
    apt-mark hold linux-image-generic 2>/dev/null || true
    apt-mark hold linux-headers-generic 2>/dev/null || true
    apt-mark hold linux-generic 2>/dev/null || true
    
    # Hold Armbian specific packages
    apt-mark hold linux-image-current-rk35xx 2>/dev/null || true
    apt-mark hold linux-image-edge-rk35xx 2>/dev/null || true
    apt-mark hold linux-dtb-current-rk35xx 2>/dev/null || true
    apt-mark hold linux-dtb-edge-rk35xx 2>/dev/null || true
    
    log_msg "Kernel packages held successfully"
fi

# 2. Create kernel hold marker file
log_msg "Creating kernel hold marker..."
cat > /etc/apt/preferences.d/99-hold-kernel << 'HOLDEOF'
# Prevent automatic kernel upgrades
# This file was created by hold-kernel.sh on first boot

Package: linux-image-* linux-headers-* linux-dtb-* linux-*-rk35xx
Pin: version *
Pin-Priority: -1

Package: linux-generic linux-image-generic linux-headers-generic
Pin: version *
Pin-Priority: -1
HOLDEOF

# 3. Backup current kernel modules and firmware
log_msg "Backing up current kernel modules..."
mkdir -p /usr/local/backups/
tar czf /usr/local/backups/kernel-modules-$KERNEL_VERSION-backup-$(date +%Y%m%d).tar.gz \
    /lib/modules/$KERNEL_VERSION 2>/dev/null || log_msg "Warning: Could not backup kernel modules"

# 4. Create kernel update helper script
log_msg "Creating kernel update helper..."
cat > /usr/local/sbin/kernel-update-allow.sh << 'UPDATEEOF'
#!/bin/bash
# Helper script to temporarily allow kernel updates
# Usage: sudo /usr/local/sbin/kernel-update-allow.sh

echo "Temporarily allowing kernel updates..."

# Unhold packages
apt-mark unhold linux-image-* linux-headers-* linux-dtb-* 2>/dev/null || true
apt-mark unhold linux-generic linux-image-generic linux-headers-generic 2>/dev/null || true

# Remove apt hold preferences
rm -f /etc/apt/preferences.d/99-hold-kernel

echo "Kernel updates allowed. Run 'apt upgrade' to update."
echo "To re-hold kernel, run: /usr/local/sbin/kernel-update-hold.sh"
UPDATEEOF

chmod +x /usr/local/sbin/kernel-update-allow.sh

# 5. Create kernel re-hold script
cat > /usr/local/sbin/kernel-update-hold.sh << 'HOLDEEOF'
#!/bin/bash
# Helper script to re-hold kernel updates
# Usage: sudo /usr/local/sbin/kernel-update-hold.sh

echo "Re-holding kernel updates..."

KERNEL_CURRENT=$(uname -r)

# Re-hold packages
apt-mark hold linux-image-$KERNEL_CURRENT 2>/dev/null || true
apt-mark hold linux-headers-$KERNEL_CURRENT 2>/dev/null || true
apt-mark hold linux-image-generic linux-headers-generic linux-generic 2>/dev/null || true
apt-mark hold linux-image-current-rk35xx linux-image-edge-rk35xx 2>/dev/null || true
apt-mark hold linux-dtb-current-rk35xx linux-dtb-edge-rk35xx 2>/dev/null || true

# Recreate apt preferences
cat > /etc/apt/preferences.d/99-hold-kernel << 'HOLDEOF'
Package: linux-image-* linux-headers-* linux-dtb-* linux-*-rk35xx
Pin: version *
Pin-Priority: -1

Package: linux-generic linux-image-generic linux-headers-generic
Pin: version *
Pin-Priority: -1
HOLDEOF

echo "Kernel updates held. Current kernel: $KERNEL_CURRENT"
HOLDEEOF

chmod +x /usr/local/sbin/kernel-update-hold.sh

# 6. Set proper permissions for helper scripts
chmod 755 /usr/local/sbin/kernel-*.sh

# 7. Create status report
log_msg "Creating kernel hold status report..."
cat > /etc/neardi/kernel-hold-status << 'STATUS'
# Neardi LZ200 Kernel Hold Status
# Generated on first boot by hold-kernel.sh

KERNEL_VERSION: $KERNEL_VERSION
HOLD_DATE: $(date '+%Y-%m-%d %H:%M:%S')
HOLD_METHOD: apt-mark hold + apt preferences
STATUS: active

# To check held packages:
#   apt-mark showhold

# To temporarily allow updates:
#   sudo /usr/local/sbin/kernel-update-allow.sh

# To re-hold kernel:
#   sudo /usr/local/sbin/kernel-update-hold.sh
STATUS

log_msg "hold-kernel.sh completed successfully"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] First boot kernel hold setup complete" | tee -a $LOG_FILE

exit 0
EOF

    chmod +x $SDCARD/usr/local/sbin/hold-kernel.sh

    # Create systemd service for first boot execution
    cat > $SDCARD/etc/systemd/system/neardi-first-boot.service << 'EOF'
[Unit]
Description=Neardi LZ200 First Boot Script (hold-kernel.sh)
ConditionFirstBoot=yes
After=network-online.target apt-daily.service
Wants=network-online.target
Before=getty.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hold-kernel.sh
ExecStartPost=/bin/systemctl disable neardi-first-boot.service
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Enable the first boot service
    chroot $SDCARD /bin/bash -c "systemctl enable neardi-first-boot.service" || true

    # Ensure machine-id is empty to trigger ConditionFirstBoot
    # Armbian usually handles this, but we ensure it here
    if [[ -f $SDCARD/etc/machine-id ]]; then
        rm -f $SDCARD/etc/machine-id
    fi
    touch $SDCARD/etc/machine-id

    display_alert "$BOARD" "First boot script hold-kernel.sh configured" "info"

    return 0
}

# Optional: Add kernel command line tweaks for Bluetooth stability
function post_family_tweaks__neardi_lz200_cmdline() {
    display_alert "$BOARD" "Adding kernel cmdline for Bluetooth stability" "info"
    
    # Add to boot script if using extlinux
    if [[ -f $SDCARD/boot/extlinux/extlinux.conf ]]; then
        sed -i 's/append /append btusb.enable_autosuspend=0 bluetooth.disable_ertm=1 /' $SDCARD/boot/extlinux/extlinux.conf
    fi
    
    return 0
}

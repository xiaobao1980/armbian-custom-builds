# Rockchip RK3576 octa core 4-8GB SoC 1*GBe eMMC USB3 USB-C WiFi HDMI
BOARD_NAME="h96-m9"
BOARDFAMILY="rk35xx"
BOOTCONFIG="h96-m9-rk3576_defconfig"
KERNEL_TARGET="vendor"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3576-h96-m9.dtb"
BOOT_SCENARIO="spl-blobs"
IMAGE_PARTITION_TABLE="gpt"
SRC_EXTLINUX="yes"
MODULES_BLACKLIST="panfrost"
BOARD_MAINTAINER=""

function post_family_config_branch_vendor__h96_m9_uboot_patches() {
	display_alert "$BOARD" "u-boot overrides for $BOARD / $BRANCH" "info"

	# Keep the family's Radxa u-boot source/branch (rk35xx vendor is built on
	# radxa/u-boot next-dev-v2024.10) and just append our board patch directory
	# so the H96 M9 device tree + defconfig are added on top.
	declare -g BOOTPATCHDIR="legacy/u-boot-radxa-rk35xx legacy/u-boot-radxa-rk35xx-v2024.10 legacy/u-boot-rk3576-h96-m9"
}

function post_family_tweaks__h96_m9_install_dtbs() {
	display_alert "$BOARD" "Installing board DTBs" "info"

	# Ensure the kernel DTB is present in /boot/dtb/rockchip (Armbian build handles this
	# automatically when the DTB is built, but keep a fallback copy for vendor trees that
	# do not install it via the standard kernel build).
	if [[ -f "$SRC/packages/blobs/h96-m9/rk3576-h96-m9.dtb" ]]; then
		cp -R "$SRC/packages/blobs/h96-m9/rk3576-h96-m9.dtb" "$SDCARD/boot/dtb/rockchip/rk3576-h96-m9.dtb"
	fi

	return 0
}

function post_family_tweaks__h96_m9_naming_audios() {
	display_alert "$BOARD" "Renaming H96 M9 audio devices" "info"

	mkdir -p "$SDCARD/etc/udev/rules.d/"
	cat > "$SDCARD/etc/udev/rules.d/90-naming-audios.rules" <<EOF
SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-hdmi0-sound", ENV{SOUND_DESCRIPTION}="HDMI0 Audio"
SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-dp0-sound", ENV{SOUND_DESCRIPTION}="DP0 Audio"
EOF

	return 0
}

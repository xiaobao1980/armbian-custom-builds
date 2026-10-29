#!/bin/bash

# arguments: $RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP
#
# Neardi LZ200 (RK3576) image customization script
# NOTE: It is copied to /tmp directory inside the image
# and executed there inside chroot environment
# so don't reference any files that are not already installed
#
# NOTE: userpatches/overlay directory on host is bind-mounted
# to /tmp/overlay in chroot for file transfer. We deploy explicitly
# from /tmp/overlay below (does NOT rely on any auto-copy behavior).

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4

# ====================================================================
# 【重要】customize-image.sh 在 Armbian 里是「整个 userpatches 目录全局唯一」
# 的一个文件（lib/functions/rootfs/customize.sh 直接读
# $USERPATCHES_PATH/customize-image.sh），**不是按板卡的**。
# 也就是说：只要同一个 userpatches 目录还用来构建别的板子
# （H96 MAX M9 / CM3588 / K50S / AM60 ...），本脚本就会在那些板子上也执行。
#
# 因此必须在这里按 $BOARD 做守卫，否则会把 LZ200 的 unit 和脚本
# 塞进别的板子镜像里。
#
# 注意不能按 LINUXFAMILY 守卫：rk35xx 被多块板共用（RK3566/RK3568/RK3576/RK3588）。
# ====================================================================
if [[ "$BOARD" != "neardi-lz200" ]]; then
	echo "[customize-image] BOARD=$BOARD 不是 neardi-lz200，跳过 LZ200 专属定制" >&2
	exit 0
fi

Main() {
	OV=/tmp/overlay

	# ---- 1. 音频：WirePlumber 友好名 + 声道映射 ----
	# WP 0.4 读 main.lua.d/*.lua，WP 0.5 读 wireplumber.conf.d/*.conf，两份共存安全
	if [ -d "$OV/etc/wireplumber" ]; then
		mkdir -p /etc/wireplumber/main.lua.d /etc/wireplumber/wireplumber.conf.d
		cp -f "$OV"/etc/wireplumber/main.lua.d/*.lua /etc/wireplumber/main.lua.d/ 2>/dev/null || true
		cp -f "$OV"/etc/wireplumber/wireplumber.conf.d/*.conf /etc/wireplumber/wireplumber.conf.d/ 2>/dev/null || true
	fi

	# ---- 2. 板级脚本：显式 install 并强制 0755 ----
	# 注意：不要依赖 overlay 自动拷贝的权限位，git/打包过程可能丢 x 位，
	#       脚本没有执行位会导致对应 systemd 服务直接失败(203/EXEC)。
	for s in neardi-lz200-audio-fix.sh lz200-usb3-quirk.sh \
	         lz200-audio-names-install.sh lz200-kernel-sync-check.sh; do
		[ -f "$OV/usr/local/bin/$s" ] && install -Dm755 "$OV/usr/local/bin/$s" "/usr/local/bin/$s"
	done

	# ---- 3. systemd unit：落位并 enable ----
	for u in neardi-lz200-audio-fix.service lz200-wifi-bt.service lz200-usb3-quirk.service; do
		if [ -f "$OV/etc/systemd/system/$u" ]; then
			install -Dm644 "$OV/etc/systemd/system/$u" "/etc/systemd/system/$u"
			systemctl enable "$u" 2>/dev/null || true
		fi
	done
	systemctl daemon-reload 2>/dev/null || true

	# ---- 4. Xorg 显示设备修正（RK35xx 通病）----
	# 现象：lightdm 起不来，Xorg 报
	#   Fatal server error: Cannot run in framebuffer mode.
	#   Please specify busIDs for all framebuffer devices
	# 根因：RK3576 上 NPU(27700000.npu, card1) 也注册成 DRM 设备，Xorg 自动探测
	#   把它当成主显示设备；但 NPU 没有显示器输出 → modesetting 落到 framebuffer
	#   模式直接 fatal。真正的显示控制器是 VOP(display-subsystem, card0)，HDMI 接它。
	# 修复：强制 modesetting 用 /dev/dri/card0（VOP），彻底绕开 NPU。
	# 适用于所有 rk35xx vendor + 桌面镜像（RK3566/3568/3576/3588 同因）。
	mkdir -p /etc/X11/xorg.conf.d
	cat > /etc/X11/xorg.conf.d/10-rk3576-display.conf <<'CONF'
Section "Device"
    Identifier "RK3576 VOP"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/card0"
    Option "Accel" "true"
    Option "PageFlip" "true"
EndSection
CONF
	chmod 644 /etc/X11/xorg.conf.d/10-rk3576-display.conf

	# ---- 5. 内核/模块同源体检 ----
	# 历史坑：内核 Image 单独重编而 /lib/modules 用旧 .config 编译时，
	# module_layout CRC 不同 → dmesg 刷 "disagrees about version of symbol
	# module_layout"，WiFi/BT 必须 modprobe -f 才能加载。
	# 若构建过程换过 Image 却没重建模块树/initramfs，这里留痕，便于开机自检。
	if command -v lz200-kernel-sync-check.sh >/dev/null 2>&1; then
		echo "[lz200] 内核/模块同源自检可用: lz200-kernel-sync-check.sh" >&2
	fi

	case $RELEASE in
		noble)
			# Ubuntu noble-specific tweaks (if any)
			;;
		trixie)
			# Debian trixie-specific tweaks (if any)
			;;
	esac

	# 板级通用微调示例（按需取消注释）：
	# - WiFi/BT 固件目录：userpatches/neardi-lz200/{wifi,bluetooth}
	#   已由 neardi-lz200.csc 的 post_family_tweaks__neardi_lz200_wireless 自动安装
	# - 若需额外文件，放入 userpatches/overlay/ 并在此处从 /tmp/overlay 拷贝
	:
} # Main

Main "$@"

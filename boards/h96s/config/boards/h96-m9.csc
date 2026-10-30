# H96 Max M9 TV Box - Rockchip RK3576 octa core 4GB RAM 128GB eMMC GbE HDMI WiFi(AIC8800D80/SDIO) BT
# Merged baseline (2026-08-29): compact build-tree version (proven golden image)
# + BT-enable / CMA / Xorg hooks ported from the full 543-line version.
# WirePlumber friendly names are deployed via the h96-m9-configure overlay
# (etc/wireplumber/wireplumber.conf.d/50-h96-audio-names.conf) — RENAME ONLY.
# Do NOT re-add audio.channels / audio.position node rules here.
BOARD_NAME="H96 Max M9"
BOARD_VENDOR="h96"
BOARDFAMILY="rk35xx"
BOOT_SOC="rk3576"
BOOTCONFIG="h96-m9s-rk3576_defconfig"
KERNEL_TARGET="vendor"
KERNEL_TEST_TARGET="vendor"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3576-h96-m9s.dtb"
BOOT_SCENARIO="spl-blobs"
IMAGE_PARTITION_TABLE="gpt"
# 启动流程：跟随 rk35xx 家族标准 boot.scr + armbianEnv.txt（BOOTSCRIPT 由
# 家族配置按 BOOT_SOC=rk3576 自动选 boot-rk3576.cmd）。2026-08-29 板上实证：
# /boot 无 extlinux 目录，/proc/cmdline 与 boot-rk3576.cmd 模板逐参数吻合，
# root=UUID 来自 armbianEnv.txt → armbianEnv.txt 完全有效。
# 不要加 SRC_EXTLINUX="yes"：自定义 U-Boot defconfig 未显式启用
# BOOTMETH_EXTLINUX，强切 extlinux 有不开机风险，且与家族工具链脱节。
BOARD_MAINTAINER=""


# AIC8800D80 SDIO WiFi：vendor 内核已内置驱动(CONFIG_AIC8800_WLAN_SUPPORT=m)，
# 固件由 armbian-firmware 提供(firmware/aic8800/SDIO/aic8800D80)，无需 DKMS。
AIC8800_TYPE="sdio"
BT_UART="/dev/ttyS4"


function post_family_config_branch_vendor__h96_m9_uboot_patches() {
	display_alert "$BOARD" "u-boot overrides for $BOARD / $BRANCH" "info"

	# Keep the family's Radxa u-boot source/branch (rk35xx vendor is built on
	# radxa/u-boot next-dev-v2024.10) and just append our board patch directory
	# so the H96 M9 device tree + defconfig are added on top.
	declare -g BOOTPATCHDIR="legacy/u-boot-radxa-rk35xx legacy/u-boot-radxa-rk35xx-v2024.10 legacy/u-boot-rk3576-h96-m9s"

	# 关于「要不要往 arch/arm/dts/Makefile 里加 rk3576-h96-m9s.dtb 条目」：
	# 不需要，也不要加。三条证据（2026-08-30 核对源码坐实）：
	# 1) 顶层 dts/Makefile 走的是
	#      DEVICE_TREE ?= $(CONFIG_DEFAULT_DEVICE_TREE:"%"=%)
	#      DTB := arch/$(ARCH)/dts/$(DEVICE_TREE).dtb
	#      $(DTB): ... $(MAKE) $(build)=$(ARCH_PATH) $@
	#    即直接按名字 make 单个 dtb，走 %.dtb: %.dts 模式规则，
	#    完全不读 arch/arm/dts/Makefile 里的 dtb-$(CONFIG_*) 列表。
	#    本板 defconfig 有 CONFIG_DEFAULT_DEVICE_TREE="rk3576-h96-m9s"，够了。
	# 2) radxa 的 arch/arm/dts/Makefile 里根本没有 CONFIG_ROCKCHIP_RK3576
	#    分组（只有老的 dtb-$(CONFIG_ARCH_ROCKCHIP)，全是 rk3036~rk3368）。
	#    这正是旧 install 脚本 awk 找 RK3576 分组失败、patch 从不生成的根因。
	# 3) Armbian 官方 6+ 个 rk3576 板卡（armsom-sige5 / nanopi-r76s /
	#    bananapi-m5-pro / recomputer-devkit / dshanpi-a1 ...）的 defconfig+dts
	#    都只放在 legacy/u-boot-radxa-rk35xx/{defconfig,dt}/，
	#    没有任何一个改过 dts Makefile —— 由 yaml 的 overlay-directories 复制即可。
	#
	# 若将来确实需要 dtb-y 列表（例如依赖 `make dtbs` 批量构建），注意：追加到
	# 文件末尾是无效的——targets += $(dtb-y) 在文件靠后位置已先展开，
	# 必须插到该行之前或插入对应 CONFIG 分组内。
}

function post_family_tweaks__h96_m9_install_dtbs() {
	display_alert "$BOARD" "Installing board DTBs" "info"

	# Primary: Armbian installs the DTB from kernel build output automatically
	# via BOOT_FDT_FILE. This hook is a fallback for cases where the DTB
	# wasn't built or wasn't installed by the standard mechanism.

	local dtb_dest="$SDCARD/boot/dtb/rockchip/rk3576-h96-m9s.dtb"
	if [[ ! -f "$dtb_dest" ]]; then
		# Fallback 1: search kernel build output
		local kernel_dtb=""
		for ksrc in "$SRC/cache/sources/linux-"*; do
			if [[ -f "$ksrc/arch/arm64/boot/dts/rockchip/rk3576-h96-m9s.dtb" ]]; then
				kernel_dtb="$ksrc/arch/arm64/boot/dts/rockchip/rk3576-h96-m9s.dtb"
				break
			fi
		done
		if [[ -n "$kernel_dtb" ]]; then
			cp "$kernel_dtb" "$dtb_dest"
			display_alert "$BOARD" "DTB installed from kernel build output" "info"
		elif [[ -f "$SRC/packages/blobs/h96-m9/rk3576-h96-m9s.dtb" ]]; then
			# Fallback 2: pre-built blob
			cp "$SRC/packages/blobs/h96-m9/rk3576-h96-m9s.dtb" "$dtb_dest"
			display_alert "$BOARD" "DTB installed from pre-built blob" "info"
		else
			display_alert "$BOARD" "WARNING: rk3576-h96-m9s.dtb not found!" "wrn"
		fi
	fi

	return 0
}

# eMMC 优先，其次 SD 卡（盒子一般从 eMMC 启动；保留 SD 便于救砖/测试）
function pre_config_uboot_target__h96_max_m9_boot_order() {
	declare -a rockchip_uboot_targets=("mmc0" "mmc1" "usb" "pxe" "dhcp")
	display_alert "u-boot for ${BOARD}/${BRANCH}" "u-boot: adjust boot order to '${rockchip_uboot_targets[*]}'" "info"
	sed -i -e "s/#define BOOT_TARGETS.*/#define BOOT_TARGETS \"${rockchip_uboot_targets[*]}\"/" include/configs/rockchip-common.h
	regular_git diff -u include/configs/rockchip-common.h || true
}

# 音频命名：HDMI / HT5010(模拟) / SPDIF（udev 层提示；桌面显示名由 WP conf 负责）
function post_family_tweaks__h96_max_m9_naming_audios() {
	display_alert "$BOARD" "Renaming H96 Max M9 audio" "info"

	mkdir -p $SDCARD/etc/udev/rules.d/
	echo 'SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-hdmi-sound", ENV{SOUND_DESCRIPTION}="HDMI Audio"' > $SDCARD/etc/udev/rules.d/90-naming-audios.rules
	echo 'SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-ht5010-sound", ENV{SOUND_DESCRIPTION}="Analog Audio"' >> $SDCARD/etc/udev/rules.d/90-naming-audios.rules
	echo 'SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-spdif-tx0-sound", ENV{SOUND_DESCRIPTION}="SPDIF Audio"' >> $SDCARD/etc/udev/rules.d/90-naming-audios.rules
	return 0
}

# TV 盒子禁用休眠（避免遥控器唤醒问题）
function post_family_tweaks__h96_max_m9_disable_suspend() {
	display_alert "$BOARD" "Disabling suspend and hibernation" "info"

	mkdir -p "${SDCARD}"/etc/systemd/sleep.conf.d
	cat > "${SDCARD}"/etc/systemd/sleep.conf.d/nosuspend.conf <<- 'EOF'
		[Sleep]
		AllowSuspend=no
		AllowHibernation=no
		AllowSuspendThenHibernate=no
		AllowHybridSleep=no
	EOF
}

# 蓝牙（AIC8800D80 UART, /dev/ttyS4）：service 文件与脚本由 h96-m9-configure
# overlay 提供（usr/local/bin/h96-m9-bluetooth.sh + etc/systemd/system/），
# customize-image.sh 只 enable audio-fix，所以这里负责 enable 蓝牙。
# 注意：同时创建手动 wants 符号链接做兜底——即使 chroot systemctl 不可用
# 或本钩子先于 overlay 复制执行，dangling symlink 在文件就位后依然生效。
function post_family_tweaks__h96_m9_enable_bluetooth() {
	display_alert "$BOARD" "Enabling on-board Bluetooth service (ttyS4)" "info"

	if [[ -x "$SDCARD/bin/systemctl" ]]; then
		chroot "$SDCARD" /bin/systemctl enable h96-m9-bluetooth.service 2>/dev/null || true
	fi
	mkdir -p "$SDCARD/etc/systemd/system/multi-user.target.wants"
	ln -sf "/etc/systemd/system/h96-m9-bluetooth.service" \
	       "$SDCARD/etc/systemd/system/multi-user.target.wants/h96-m9-bluetooth.service"

	return 0
}

# CMA 512M：vendor 6.1 默认 CMA 仅 16MB，历史上 1080p framebuffer 分配失败
#（dmesg "failed to allocate 8364032 byte dma buffer"）→ HDMI 黑屏，加
# cma=512M 后解决（8GB+ 板推荐；4K60 VPU 解码缓冲池需 ≥512M；2GB 板应改 128M）。
# 2026-08-29 实证：本板走 boot.scr + armbianEnv.txt（无 extlinux），
# boot-rk3576.cmd 的 bootargs 拼接 ${extraargs} ${extraboardargs}，
# 所以参数必须写进 armbianEnv.txt 的 extraboardargs。
function post_family_tweaks__h96_m9_cma_reserve() {
	display_alert "$BOARD" "Bumping CMA to 512M for 4K VPU + HDMI framebuffer" "info"

	local env="$SDCARD/boot/armbianEnv.txt"
	if [[ ! -f "$env" ]]; then
		display_alert "$BOARD" "armbianEnv.txt not found; CMA fix skipped" "wrn"
		return 0
	fi
	if grep -q 'cma=' "$env"; then
		: # already set, idempotent
	elif grep -q '^extraboardargs=' "$env"; then
		sed -i -E 's/^extraboardargs=(.*)$/extraboardargs=\1 cma=512M/' "$env"
	else
		echo 'extraboardargs=cma=512M' >> "$env"
	fi

	return 0
}

# 把 userpatches/h96-m9-configure/ 部署进 rootfs。
# 为什么用 .csc hook 而不是 userpatches/customize-image*.sh（Armbian 源码实证）：
#   lib/functions/rootfs/customize.sh:13
#     [[ -f $USERPATCHES_PATH/customize-image-host.sh ]] && source ...
#     对所有板卡无条件 source，没有 board 判定 → 里面的任何内容都会泄漏进
#     别的板卡镜像，除非自己加 $BOARD 守卫。
#   lib/functions/rootfs/customize.sh:24-34
#     customize-image.sh 是在 chroot 内执行的 → ${SRC} 不可达 →
#     userpatches/h96-m9-configure 的 [[ -d ]] 恒为假，overlay 被静默跳过
#     ——这正是"新镜像里没有 h96-m9-configure 文件"的根因。
#   lib/functions/rootfs/customize.sh:30
#     userpatches/overlay 只是只读 bind 到 ${SDCARD}/tmp/overlay，不会自动进镜像。
#   lib/functions/rootfs/distro-agnostic.sh:454
#     post_family_tweaks 在 HOST 上下文、包安装完成后触发，${SRC}/${SDCARD}/
#     chroot 全都可用；且写在 .csc 里就只对本板卡生效，零污染其它板卡。
# 同名 hook 按后缀名排序执行（extensions.sh），本 hook 排在
# disable_suspend / enable_bluetooth / install_dtbs / naming_audios / xorg_panfrost 之前。
function post_family_tweaks__h96_m9_deploy_config_files() {
	display_alert "$BOARD" "Deploying userpatches/h96-m9-configure into rootfs" "info"

	local conf="${SRC}/userpatches/h96-m9-configure"
	if [[ ! -d "$conf" ]]; then
		# 不致命：install-to-armbian.sh 负责生成该目录；若被跳过，构建仍会
		# 产出可启动镜像，只是少了音频/蓝牙/友好名等板级定制。
		display_alert "$BOARD" "userpatches/h96-m9-configure not present — skipping overlay deploy" "wrn"
		return 0
	fi

	for d in etc usr; do
		[[ -d "$conf/$d" ]] && cp -r "$conf/$d/." "$SDCARD/$d/"
	done
	chmod 755 "$SDCARD/usr/local/bin/h96-m9-audio-fix.sh" 2>/dev/null || true
	chmod 755 "$SDCARD/usr/local/bin/h96-m9-bluetooth.sh" 2>/dev/null || true
	chmod 755 "$SDCARD/usr/local/bin/h96-m9-vpu-codecs.sh" 2>/dev/null || true
	chmod 644 "$SDCARD/etc/systemd/system/h96-m9-vpu.service" 2>/dev/null || true
	chmod 755 "$SDCARD/etc/rc.local" 2>/dev/null || true

	# 只 enable 音频路由服务；蓝牙由 post_family_tweaks__h96_m9_enable_bluetooth 负责。
	if [[ -x "$SDCARD/bin/systemctl" ]]; then
		chroot "$SDCARD" /bin/systemctl --no-reload enable h96-m9-audio-fix.service 2>/dev/null || true
	else
		mkdir -p "$SDCARD/etc/systemd/system/multi-user.target.wants"
		ln -sf "/etc/systemd/system/h96-m9-audio-fix.service" \
		       "$SDCARD/etc/systemd/system/multi-user.target.wants/h96-m9-audio-fix.service"
	fi

	return 0
}

# Xorg modesetting：RK3576 + Panfrost 下 Xorg 可能误探 "rockchip" DDX 或退回
# fbdev 导致 lightdm 不起、进不去桌面（XFCE 镜像实测）。钉 modesetting 后正常。
# 对 GNOME/Wayland 无影响（xorg.conf.d 仅 Xorg 读取）。
function post_family_tweaks__h96_m9_xorg_panfrost() {
	display_alert "$BOARD" "Installing Xorg modesetting config for Panfrost GPU" "info"

	mkdir -p "$SDCARD/etc/X11/xorg.conf.d"
	cat > "$SDCARD/etc/X11/xorg.conf.d/10-rockchip.conf" <<'XORG_EOF'
Section "OutputClass"
    Identifier "rockchip"
    MatchDriver "rockchip"
    Driver "modesetting"
    Option "PrimaryGPU" "true"
EndSection
XORG_EOF

	return 0
}

# ---------------------------------------------------------------------------
# VPU 硬件编解码用户态栈（RK3576 / Rockchip MPP）
#
# 为什么要有这个 hook（2026-08-30 实证，三条结论）：
#
# 1) extensions/mesa-vpu.sh 在上游 armbian/build 已被删除。提交 27c668343
#    "mesa-vpu: delete extension — fully covered by armbian-config" 把它删掉，
#    职责迁到 armbian-configng 的 module_desktops
#    （_module_desktops_rockchip_multimedia，module_desktops.sh:147）。
#    实测上游 main 已取不到该文件（raw.githubusercontent.com/armbian/build/main/
#    extensions/mesa-vpu.sh → 404）。
#    ⚠️ 但本仓库自带一份：common/extensions/mesa-vpu.sh，
#    scripts/sync-board-to-build.sh 会把它同步到 userpatches/extensions/，
#    Armbian 按「扩展名 → userpatches/extensions/<name>.sh」解析，因此
#    ENABLE_EXTENSIONS=mesa-vpu 在本仓依然有效（noble/jammy + Wayland 桌面生效）。
#    本 hook 保留为**兜底 + 补充**（扩展没装 mpp 用户态与 vpu.service），
#    两者共存是幂等的：PPA 源与 pin 都有存在性判断。
#
# 2) configng 那条路径在完整镜像构建里实测没跑。./compile.sh build 的日志
#    中既无 BOARDFAMILY 记录也无 module_desktops 调用痕迹；rootfs 里能查到
#    PPA 源，只是因为构建机 cache/aptcache/lists 里 2025-03-06 的历史残留
#    被 cp -pr 复制进了 /var/lib/apt/lists/。结论：VPU 用户态包一个都没装。
#
# 3) 内核侧其实一直就绪，缺的只有用户态：
#      CONFIG_ROCKCHIP_MPP_RKVDEC2/RKVENC2/AV1DEC/JPGDEC/JPGENC = y
#      /dev/mpp_service 存在；/proc/mpp_service/supports-device 列出
#      RKVDEC(HW_ID 0x38321746)、RKVENC、RKJPEGD、RKJPEGE、IEP2、VDPP。
#    补上 librockchip_mpp1 + gstreamer1.0-rockchip1 后，实测 1080p / 4K /
#    8K(7680x4320) 的 H.264 与 H.265 硬编硬解全部通过。
#
# 失败一律降级为 warning：VPU 缺失不该让整机构建失败。这个 PPA 走 Launchpad，
# 国内链路不稳，历史上正是 add-apt-repository 抛 ssl.SSLEOFError 打挂过构建。
# ---------------------------------------------------------------------------
function post_family_tweaks__h96_m9_vpu_stack() {
	# 门控：只有 rk35xx + vendor + noble 的桌面镜像才装（CLI 无消费方）
	[[ "${BOARDFAMILY:-}" != "rk35xx" ]] && return 0
	[[ "${BRANCH:-}" != "vendor" ]] && return 0
	[[ "${RELEASE:-}" != "noble" ]] && return 0
	[[ "${BUILD_DESKTOP:-}" != "yes" ]] && return 0
	[[ "${BUILD_MINIMAL:-}" == "yes" ]] && return 0

	display_alert "$BOARD" "Installing RK3576 VPU userspace stack (Rockchip MPP)" "info"

	# 1) PPA 源。幂等：sources.list.d 里已有就跳过。
	if ! grep -qr 'rockchip-multimedia' "${SDCARD}"/etc/apt/sources.list.d/ 2>/dev/null; then
		if ! do_with_retries 3 chroot_sdcard add-apt-repository ppa:liujianfeng1994/rockchip-multimedia --yes --no-update; then
			display_alert "$BOARD" "Failed to add rockchip-multimedia PPA — VPU stack skipped" "wrn"
			return 0
		fi
	fi

	# 2) Pin 必须是 1001 而不是 990：PPA 的 ffmpeg/chromium 需要能跨源替换
	#    官方同名包，990 会以"降级"为由拒绝；完全没有 pin 时 apt 直接报
	#    "Packages were downgraded and -y was used without --allow-downgrades"。
	#    文件名与 common/extensions/mesa-vpu.sh 写入的保持一致 —— 两个 hook 都跑时
	#    只有一个 pin 文件，内容相同且幂等，避免 /etc/apt/preferences.d 里出现两份。
	cat > "${SDCARD}"/etc/apt/preferences.d/amazingfated-rk3588-rockchip-multimedia-pin <<- 'EOF'
		Package: *
		Pin: release o=LP-PPA-liujianfeng1994-rockchip-multimedia
		Pin-Priority: 1001
	EOF

	# 3) 刷新索引
	if ! do_with_retries 3 chroot_sdcard_apt_get_update; then
		display_alert "$BOARD" "apt update after PPA add failed — VPU stack skipped" "wrn"
		return 0
	fi

	# 4) 装包。libv4l 必须单独先装：rockchip-multimedia-config 的 postinst
	#    依赖 V4L2 用户态库已在位（实测该包 Depends 只有 udev，**不会**自动拉
	#    libv4l，所以这一步不能省）；且 rockchip-multimedia-config 会装上
	#    99-rk-device-permissions.rules（把 /dev/mpp_service 从
	#    crw------- root root 改成 crw-rw---- root video），否则桌面会话的
	#    普通用户根本打不开 VPU。
	#    包名随 time_t 迁移变化：jammy/bullseye -> libv4l-0；noble/trixie+ -> libv4l-0t64
	local v4l_pkg="libv4l-0"
	case "${RELEASE:-}" in
		noble | oracular | plucky | questing | resolute | trixie) v4l_pkg="libv4l-0t64" ;;
	esac
	do_with_retries 3 chroot_sdcard_apt_get_install "${v4l_pkg}" ||
		display_alert "$BOARD" "${v4l_pkg} install failed; rockchip-multimedia postinst may fail" "wrn"

	do_with_retries 3 chroot_sdcard_apt_get_install \
		librockchip-mpp1 rockchip-mpp-demos gstreamer1.0-rockchip1 \
		libv4l-rkmpp rockchip-multimedia-config ||
		display_alert "$BOARD" "VPU package install failed (see above) — continuing" "wrn"

	# 5) 启用 VPU 能力声明服务（补齐 RK3576 的 /dev/video-dec0 codecs）。
	#    文件由 post_family_tweaks__h96_m9_deploy_config_files 复制进 rootfs；
	#    同名 hook 按后缀排序执行（d < v），deploy 先于本 hook。
	if [[ -x "$SDCARD/bin/systemctl" ]]; then
		chroot "$SDCARD" /bin/systemctl --no-reload enable h96-m9-vpu.service 2>/dev/null || true
	fi
	mkdir -p "$SDCARD/etc/systemd/system/multi-user.target.wants"
	ln -sf "/etc/systemd/system/h96-m9-vpu.service" \
	       "$SDCARD/etc/systemd/system/multi-user.target.wants/h96-m9-vpu.service"

	return 0
}

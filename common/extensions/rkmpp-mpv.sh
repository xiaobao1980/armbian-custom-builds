#
# SPDX-License-Identifier: GPL-2.0
# Armbian build framework extension
#
# rkmpp-mpv: 全局 RKMPP + mpv 硬件解码加速（X11 桌面，RK35xx / RK3588 vendor 内核）
#
# =============================================================================
#  v3 栈（与板端 192.168.50.105 验证通过的栈完全一致）
# -----------------------------------------------------------------------------
#  mpp(github/gitee jellyfin-mpp) -> rkrga(gitee jellyfin-rga，仅 gitee 有该分支)
#   -> ffmpeg-rockchip(github/gitee, 隔离 /usr/local/lib/ffmpeg-rkmpp)
#   -> mpv(官方主线 v0.41.0 + nyanmisaka/boogiepop rkmpp 后端补丁 mpp.patch)
#
#  源码 clone 策略（v3.1）：github 优先、gitee 兜底，每个源重试 5 次。
#  - CI (GitHub Actions) github 原生可达，避开 gitee 大仓库 early EOF：
#      error: RPC failed; curl 56 GnuTLS recv error (-110) / fatal: early EOF
#  - 板上 github 被封时自动回落 gitee（已验证）。
#  - rga 的 jellyfin-rga 分支仅在 gitee 维护，故只走 gitee + 重试。
#
#  关键事实：mpv 官方 v0.41.0 主线 video/out/hwdec/ 只有 drmprime 帧格式后端，
#  不含 rkmpp 解码后端（无 hwdec_rkmpp.c）。github.com/nyanmisaka/mpv 不存在(404)，
#  其 rkmpp 工作以补丁形式落在本扩展自带 assets/rkmpp-mpv/mpp.patch（PATCH 2/3
#  作者即 nyanmisaka）。对官方 v0.41.0 应用该补丁 == 获得 fork 同款原生 rkmpp 后端
#  （--hwdec=rkmpp 可用，h264_rkmpp/hevc_rkmpp/vp9_rkmpp/av1_rkmpp 等驱动后端）。
#
#  本扩展自带 assets（与 boards/h96s/mpv-rkmpp/ 同源，提交时一并纳入版本控制）：
#    assets/rkmpp-mpv/rk35xx-rkmpp-mpv-build.sh  —— v3 一键编译脚本
#    assets/rkmpp-mpv/mpp.patch                  —— rkmpp 后端补丁
#
#  生效条件（全局, 所有 vendor 内核 Rockchip 板）:
#    * BRANCH=vendor 且 LINUXFAMILY=rk35xx / rockchip-rk3588（BSP 内核带 rkmpp 驱动）
#    * 非 minimal 镜像
#    * ARCH=arm64
#  可选环境变量:
#    RKMPP_MPV_SKIP_BUILD=yes  跳过源码编译（仅做 X11 强制 + CMA 兜底，用于快速验证）
#
#  落盘内容:
#    1. /usr/local/bin/mpv                —— v0.41.0 + rkmpp 后端（rpath 链 ffmpeg-rkmpp）
#    2. /usr/local/lib/ffmpeg-rkmpp/      —— 隔离的 ffmpeg-rockchip（含 *_rkmpp 解码器）
#    3. /etc/mpv/mpv.conf                 —— hwdec=rkmpp（零拷贝；缺 egl-x11 的板改 rkmpp-copy）
#    4. /etc/udev/rules.d/99-mpp.rules    —— mpp_service 0666
#    5. /boot/armbianEnv.txt              —— extraboardargs=cma=512M（4K 流畅前提，首启即生效）
#    6. 桌面会话强制 X11（gdm3/sddm）+ modesetting TearFree
# =============================================================================

function extension_prepare_config__rkmpp_mpv() {
	# 仅 vendor 内核 + Rockchip rk35xx/rk3588 家族（BSP 内核才带 rkmpp/RGA 驱动）
	if [[ ! ( "${LINUXFAMILY}" =~ ^(rk35xx|rockchip-rk3588)$ && "${BRANCH}" == "vendor" ) ]]; then
		display_alert "Extension: ${EXTENSION}" "needs vendor kernel on rk35xx/rk3588, skipping" "warn"
		return 0
	fi

	# minimal 镜像跳过
	if [[ "${BUILD_MINIMAL}" == "yes" ]]; then
		display_alert "Extension: ${EXTENSION}" "skip installation in minimal images" "warn"
		return 0
	fi

	display_alert "Extension: ${EXTENSION}" "RKMPP + mpv v3 stack (X11, native rkmpp backend) enabled for ${LINUXFAMILY}/${BRANCH}" "info"
	return 0
}

function post_install_kernel_debs__rkmpp_mpv() {
	# 条件与 prepare 阶段一致
	if [[ ! ( "${LINUXFAMILY}" =~ ^(rk35xx|rockchip-rk3588)$ && "${BRANCH}" == "vendor" ) ]]; then
		return 0
	fi
	if [[ "${BUILD_MINIMAL}" == "yes" ]]; then
		return 0
	fi

	# ---- 0. 定位扩展自带 assets（v3 脚本 + mpp.patch）----
	# BASH_SOURCE[0] 指向本扩展文件；assets 置于同级的 rkmpp-mpv/ 子目录。
	local SCRIPT_DIR ASSET_DIR
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	ASSET_DIR="${SCRIPT_DIR}/rkmpp-mpv"
	if [[ ! -f "${ASSET_DIR}/rk35xx-rkmpp-mpv-build.sh" || ! -f "${ASSET_DIR}/mpp.patch" ]]; then
		display_alert "rkmpp-mpv assets missing at ${ASSET_DIR}; cannot build v3 stack" "${EXTENSION}" "err"
		return 0
	fi

	# ---- 1. 把 assets 拷进 chroot ----
	display_alert "Staging v3 rkmpp-mpv assets into chroot" "${EXTENSION}" "info"
	mkdir -p "${SDCARD}/root/rkmpp-src" "${SDCARD}/usr/local/sbin"
	cp "${ASSET_DIR}/rk35xx-rkmpp-mpv-build.sh" "${SDCARD}/usr/local/sbin/rk35xx-rkmpp-mpv-build.sh"
	cp "${ASSET_DIR}/mpp.patch" "${SDCARD}/root/rkmpp-src/mpp.patch"
	chmod +x "${SDCARD}/usr/local/sbin/rk35xx-rkmpp-mpv-build.sh"
	# 烧卡后一键校验脚本（可选资产，缺失不影响构建）
	if [[ -f "${ASSET_DIR}/verify-rkmpp-image.sh" ]]; then
		cp "${ASSET_DIR}/verify-rkmpp-image.sh" "${SDCARD}/usr/local/sbin/verify-rkmpp-image.sh"
		chmod +x "${SDCARD}/usr/local/sbin/verify-rkmpp-image.sh"
	fi

	# ---- 2. 预拉 mpv v0.41.0 源码 tarball（best-effort，CI 有 github 访问）----
	# 失败则 v3 脚本会回退到 gitee 镜像 clone（脚本内部已实现）。
	local _TARBALL="${SDCARD}/root/rkmpp-src/mpv-0.41.0.tar.gz"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 -o "${_TARBALL}" \
			"https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz" \
		|| curl -fsSL --retry 3 -o "${_TARBALL}" \
			"https://gitee.com/mirrors/mpv/repository/archive/v0.41.0.tar.gz" \
		|| display_alert "mpv tarball download failed; v3 script will try gitee clone fallback" "${EXTENSION}" "warn"
	fi

	# ---- 3. chroot 内执行 v3 一键编译（mpp/rga/ffmpeg-rockchip/mpv+rkmpp 补丁）----
	if [[ "${RKMPP_MPV_SKIP_BUILD:-no}" != "yes" ]]; then
		display_alert "Building RKMPP+mpv v3 stack in chroot (this takes a while)" "${EXTENSION}" "info"
		# 用 env 传参（chroot_sdcard 直接把参数交给 chroot，无 shell 包裹）
		chroot_sdcard "env BUILD_BASE=/root/rkmpp-build \
			MPV_TARBALL=/root/rkmpp-src/mpv-0.41.0.tar.gz \
			MPV_PATCH=/root/rkmpp-src/mpp.patch \
			VIDEO_DIR=/root \
			bash /usr/local/sbin/rk35xx-rkmpp-mpv-build.sh build" || {
			# 中止整镜像构建：此前“仅告警不中止”会产出 success 但静默缺 rkmpp 的镜像
			# （run 40562290671 / 40589991000 均因此伪装成功）。宁可让 CI 变红，
			# 也不交付一个硬解失效、只能软解的镜像。
			display_alert "v3 rkmpp-mpv build FAILED; aborting image build to avoid shipping a silently rkmpp-less image" "${EXTENSION}" "err"
			exit 1
		}
	else
		display_alert "Skipping rkmpp source build (RKMPP_MPV_SKIP_BUILD=yes)" "${EXTENSION}" "warn"
	fi
	# 构建脚本仅用于镜像内一次性编译，编译完即删，避免残留在最终镜像
	rm -f "${SDCARD}/usr/local/sbin/rk35xx-rkmpp-mpv-build.sh"

	# ---- 4. 安全网：确保 CMA=512M 写入 armbianEnv.txt（旧扩展缺失此项 → 4K 掉帧）----
	# v3 脚本已在 chroot 内写 /boot/armbianEnv.txt；此处兜底（防 boot 分区未挂载时序）。
	if [[ -f "${SDCARD}/boot/armbianEnv.txt" ]]; then
		if grep -q 'cma=' "${SDCARD}/boot/armbianEnv.txt"; then
			sed -i -E 's/(cma=)[0-9]+M/\1512M/' "${SDCARD}/boot/armbianEnv.txt"
		else
			sed -i '1i extraboardargs=cma=512M' "${SDCARD}/boot/armbianEnv.txt"
		fi
		display_alert "Ensured cma=512M in armbianEnv.txt" "${EXTENSION}" "info"
	fi

	# ---- 5. 桌面会话强制 X11（rkmpp 零拷贝需 X11 + egl-x11/glx 上下文）----
	if [[ "${BUILD_DESKTOP}" == "yes" ]]; then
		display_alert "Forcing X11 session (disabling Wayland) for rkmpp" "${EXTENSION}" "info"

		# GNOME / gdm3: WaylandEnable=false
		if [[ -d "${SDCARD}/etc/gdm3" || "${DESKTOP_ENVIRONMENT:-}" == "gnome" ]]; then
			mkdir -p "${SDCARD}/etc/gdm3"
			local gdmconf="${SDCARD}/etc/gdm3/custom.conf"
			if [[ -f "${gdmconf}" ]]; then
				sed -i 's/^#\?WaylandEnable=.*/WaylandEnable=false/' "${gdmconf}"
				grep -q '^WaylandEnable=' "${gdmconf}" || sed -i '/^\[daemon\]/a WaylandEnable=false' "${gdmconf}"
			else
				cat <<- 'GDMCONF' > "${gdmconf}"
					[daemon]
					# 非 Wayland: 强制 X11 会话 (RKMPP/mpv X11 渲染基线)
					WaylandEnable=false

					[security]

					[xdmcp]

					[chooser]

					[debug]
				GDMCONF
			fi
		fi

		# KDE / sddm: DisplayServer=x11
		if [[ -d "${SDCARD}/etc/sddm.conf.d" || "${DESKTOP_ENVIRONMENT:-}" == "kde-plasma" ]]; then
			mkdir -p "${SDCARD}/etc/sddm.conf.d"
			cat <<- 'SDDMCONF' > "${SDCARD}/etc/sddm.conf.d/90-force-x11.conf"
				# 非 Wayland: 强制 X11 会话
				[General]
				DisplayServer=x11
			SDDMCONF
		fi

		# X11 撕裂优化（modesetting TearFree）
		mkdir -p "${SDCARD}/etc/X11/xorg.conf.d"
		cat <<- 'XORGCONF' > "${SDCARD}/etc/X11/xorg.conf.d/20-tearfree.conf"
			Section "Device"
			    Identifier "Rockchip-GPU"
			    Driver "modesetting"
			    Option "TearFree" "true"
			EndSection
		XORGCONF
	fi

	display_alert "RKMPP+mpv v3 stack install complete" "${EXTENSION}" "info"
	return 0
}

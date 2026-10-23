#
# SPDX-License-Identifier: GPL-2.0
# Armbian build framework extension
#
# rkmpp-mpv: 全局 RKMPP + mpv 硬件解码加速（非 Wayland / X11 专用）
#
# 来源: Debian_X11_RKMPP_MPV_Guide.md（方案 A: ffmpeg-rockchip + mpv wrapper）
#   https://github.com/nyanmisaka/mpp          (jellyfin-mpp 分支)
#   https://github.com/nyanmisaka/rk-mirrors  (jellyfin-rga 分支)
#   https://github.com/nyanmisaka/ffmpeg-rockchip
#
# 生效条件（全局, 所有 vendor 内核 Rockchip 板）:
#   * BRANCH=vendor 且 LINUXFAMILY=rk35xx / rockchip-rk3588（BSP 内核带 rkmpp 驱动）
#   * 非 minimal 镜像
#   * ARCH=arm64
# 可选环境变量:
#   RKMPP_MPV_SKIP_BUILD=yes  跳过源码编译（仅装 mpv + 写配置, 用于快速验证）
#
# 做了什么:
#   双路径自动选择（检测 mesa-vpu 是否已启用 amazingfated PPA）:
#   * noble + desktop + mesa-vpu（PPA liujianfeng1994/rockchip-multimedia 已 pin）:
#     PPA 的 ffmpeg 6.1.1 构建参数带 --enable-rkmpp --enable-rkrga
#     （changelog: "Add mpp patch from nyanmisaka"）。注意 PPA 自己的 mpv
#     重打包(0.36.0-1+j1)现仅剩 jammy/armhf, noble 已下架 —— noble 上 apt
#     装 Ubuntu 官方 mpv(0.37), 但其动态链接 PPA 的 rkmpp 版 libavcodec60,
#     h264_rkmpp 等 wrapper 解码器被 mpv 动态注册为 hwdec 方法
#     (mpv vd_lavc 从 libavcodec 枚举 wrapper_name), 硬解可用, 跳过自编译
#   * 其他场景（bookworm / server / 未启用 mesa-vpu）:
#     chroot 内源码编译 MPP / RGA / ffmpeg-rockchip
#     （库隔离在 /usr/local/lib/ffmpeg-rkmpp, 不污染系统 ffmpeg）+ mpv wrapper
#   两条路径共同落盘:
#   1. 全局 /etc/mpv/mpv.conf: hwdec=auto + vo=gpu + gpu-api=opengl（X11 渲染）
#   2. 全局非 Wayland: gdm3 WaylandEnable=false / sddm DisplayServer=x11,
#      桌面会话强制跑在 X11 上
#

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

	display_alert "Extension: ${EXTENSION}" "RKMPP + mpv (X11, non-Wayland) enabled for ${LINUXFAMILY}/${BRANCH}" "info"
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

	# ---- 0. 检测 mesa-vpu 的 amazingfated PPA 栈（noble + desktop）----
	# PPA ffmpeg 6.1.1 带 --enable-rkmpp --enable-rkrga; PPA 的 mpv 重打包
	# (0.36.0-1+j1) 仅剩 jammy/armhf, noble 上 apt 装官方 mpv 0.37 —— 但它
	# 动态链接 PPA 的 rkmpp 版 libavcodec60, wrapper 解码器对 mpv 可见,
	# 硬解可用。判据: mesa-vpu 扩展写入的 apt pin 文件（顺序 mesa-vpu 在前）
	RKMPP_USE_PPA_STACK="no"
	if [[ -f "${SDCARD}/etc/apt/preferences.d/amazingfated-rk3588-rockchip-multimedia-pin" ]]; then
		RKMPP_USE_PPA_STACK="yes"
		display_alert "mesa-vpu PPA rkmpp stack detected, using PPA mpv/ffmpeg (no source build)" "${EXTENSION}" "info"
	fi

	# ---- 1. mpv (+ 编译依赖, 仅自编译路径需要) ----
	if [[ "${RKMPP_USE_PPA_STACK}" == "yes" ]]; then
		display_alert "Installing mpv/ffmpeg from rkmpp-enabled PPA" "${EXTENSION}" "info"
		do_with_retries 3 chroot_sdcard_apt_get_install "mpv" "ffmpeg"
	else
		display_alert "Installing mpv and build dependencies" "${EXTENSION}" "info"
		declare -a pkgs=(
			"mpv" "ffmpeg"
			"git" "cmake" "meson" "ninja-build" "pkg-config"
			"build-essential" "yasm" "nasm"
			"libdrm-dev" "libx11-dev" "libxext-dev"
			"libfdk-aac-dev" "libmp3lame-dev" "libopus-dev"
			"libx264-dev" "libx265-dev" "libass-dev"
		)
		do_with_retries 3 chroot_sdcard_apt_get_install "${pkgs[@]}"
	fi

	# ---- 2. 源码编译 MPP / RGA / ffmpeg-rockchip（chroot 内 root, 无需 sudo）----
	if [[ "${RKMPP_USE_PPA_STACK}" == "yes" ]]; then
		display_alert "Skipping rkmpp source build (PPA stack in place)" "${EXTENSION}" "info"
	elif [[ "${RKMPP_MPV_SKIP_BUILD:-no}" == "yes" ]]; then
		display_alert "Skipping rkmpp source build" "RKMPP_MPV_SKIP_BUILD=yes" "warn"
	else
		display_alert "Staging install script" "${EXTENSION}" "info"
		mkdir -p "${SDCARD}"/usr/local/sbin
		cat <<- 'INSTALLER' > "${SDCARD}"/usr/local/sbin/install-rkmpp-mpv.sh
			#!/bin/bash
			# RKMPP + mpv 硬件加速安装（在镜像构建 chroot 内以 root 运行）
			# 来源: Debian_X11_RKMPP_MPV_Guide.md 方案 A
			set -e

			# ---- MPP (Media Process Platform) ----
			# 注意: jellyfin-mpp 仓库自带顶层 build/ 目录, 不能用 "mkdir build" + "cmake ..";
			# 改用 cmake -S/-B 显式指定源/构建目录, 并避开 "cd x && mkdir y" 链
			# (bash set -e 对 && 链中间命令失败不退出, 曾导致 cmake 误以 /tmp 为源目录).
			rm -rf /tmp/rkmpp /tmp/mpp-build
			git clone -b jellyfin-mpp --depth=1 https://github.com/nyanmisaka/mpp.git /tmp/rkmpp
			cmake -S /tmp/rkmpp -B /tmp/mpp-build \
			    -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_SHARED_LIBS=ON -DBUILD_TEST=OFF
			cmake --build /tmp/mpp-build -j"$(nproc)"
			cmake --install /tmp/mpp-build
			ldconfig

			# ---- RGA (2D 加速器) ----
			rm -rf /tmp/rkrga /tmp/rga-build
			git clone -b jellyfin-rga --depth=1 https://github.com/nyanmisaka/rk-mirrors.git /tmp/rkrga
			meson setup /tmp/rga-build /tmp/rkrga \
			    --prefix=/usr/local --buildtype=release \
			    --default-library=shared -Dlibdrm=false -Dlibrga_demo=false
			ninja -C /tmp/rga-build
			ninja -C /tmp/rga-build install
			ldconfig

			# ---- ffmpeg-rockchip（库隔离到 /usr/local/lib/ffmpeg-rkmpp）----
			# ffmpeg 只支持 in-source 构建; 逐条独立命令, 让 set -e 精确捕获失败
			rm -rf /tmp/ffmpeg-rockchip
			git clone --depth=1 https://github.com/nyanmisaka/ffmpeg-rockchip.git /tmp/ffmpeg-rockchip
			cd /tmp/ffmpeg-rockchip
			./configure \
			    --prefix=/usr/local \
			    --libdir=/usr/local/lib/ffmpeg-rkmpp \
			    --enable-gpl --enable-version3 \
			    --enable-libdrm --enable-rkmpp --enable-rkrga \
			    --enable-shared --disable-static \
			    --extra-ldflags="-Wl,-rpath,/usr/local/lib/ffmpeg-rkmpp" \
			    --enable-nonfree
			make -j"$(nproc)"
			make install
			ldconfig

			# ---- ffmpeg 优先指向 rkmpp 版 ----
			for cmd in ffmpeg ffprobe ffplay; do
			    [ -x "/usr/local/bin/$cmd" ] || continue
			    update-alternatives --install "/usr/bin/$cmd" "$cmd" "/usr/local/bin/$cmd" 100 || true
			    update-alternatives --set "$cmd" "/usr/local/bin/$cmd" || true
			done

			# ---- mpv wrapper: 加载 ffmpeg-rockchip 的 libavcodec ----
			if [ -x /usr/bin/mpv ] && [ ! -e /usr/bin/mpv.distrib ]; then
			    mv /usr/bin/mpv /usr/bin/mpv.distrib
			fi
			if [ -e /usr/bin/mpv.distrib ]; then
			    cat > /usr/bin/mpv << 'WRAP'
			#!/bin/bash
			# mpv wrapper — 加载 ffmpeg-rockchip 库以启用 rkmpp 硬件解码
			export LD_LIBRARY_PATH=/usr/local/lib/ffmpeg-rkmpp:/usr/local/lib:${LD_LIBRARY_PATH}
			exec /usr/bin/mpv.distrib "$@"
			WRAP
			    chmod +x /usr/bin/mpv
			fi

			# 显式快捷命令（绕过 wrapper 直接调用）
			cat > /usr/local/bin/mpv-rkmpp << 'WRAP'
			#!/bin/bash
			export LD_LIBRARY_PATH=/usr/local/lib/ffmpeg-rkmpp:/usr/local/lib:${LD_LIBRARY_PATH}
			exec /usr/bin/mpv.distrib "$@"
			WRAP
			chmod +x /usr/local/bin/mpv-rkmpp

			# 清理源码树（减小镜像体积）
			rm -rf /tmp/rkmpp /tmp/rkrga /tmp/ffmpeg-rockchip /tmp/mpp-build /tmp/rga-build
			ldconfig
			echo "=== rkmpp-mpv 安装完成 ==="
		INSTALLER
		chmod +x "${SDCARD}"/usr/local/sbin/install-rkmpp-mpv.sh

		display_alert "Compiling MPP/RGA/ffmpeg-rockchip in chroot (this takes a while)" "${EXTENSION}" "info"
		chroot_sdcard "bash /usr/local/sbin/install-rkmpp-mpv.sh" || {
			display_alert "rkmpp source build failed, mpv falls back to software decoding" "${EXTENSION}" "err"
			return 0
		}
		rm -f "${SDCARD}"/usr/local/sbin/install-rkmpp-mpv.sh
	fi

	# ---- 3. 全局 mpv 配置（X11 / OpenGL）----
	display_alert "Writing global mpv.conf (X11/OpenGL)" "${EXTENSION}" "info"
	mkdir -p "${SDCARD}"/etc/mpv
	cat <<- 'MPVCONF' > "${SDCARD}"/etc/mpv/mpv.conf
		# RKMPP 硬件加速 — X11 (非 Wayland) 全局配置
		# 适用: XFCE / GNOME (X11) / Deepin + Panfrost (Mali GPU)

	# ========== 硬件解码 ==========
	# 显式锁定 rkmpp: mpv 会从 libavcodec 动态枚举 wrapper 解码器
	# (h264_rkmpp 等, wrapper_name=rkmpp) 注册为 hwdec 方法; 但 hwdec=auto
	# 的探测白名单不含 rkmpp(排在最后且随机序), 显式指定才确定命中。
	# rkmpp 初始化失败或该编码无 *_rkmpp 解码器时 mpv 自动回退软解。
	hwdec=rkmpp
	hwdec-codecs=all

		# ========== 视频输出 ==========
		vo=gpu
		# 强制 OpenGL: Panfrost Mali 不支持 Vulkan, 且绕开 Wayland
		gpu-api=opengl

		# ========== 渲染质量（4K 性能优化）==========
		profile=fast
		scale=bilinear

		# ========== 缓冲 ==========
		cache=yes
		cache-secs=60
		demuxer-max-bytes=50M

		# ========== 字幕 ==========
		sub-font-size=35
		sub-color="#FFFFFFFF"
		sub-border-color="#FF000000"
	MPVCONF

	# ---- 4. 全局非 Wayland: 桌面会话锁 X11 ----
	display_alert "Forcing X11 session (disabling Wayland)" "${EXTENSION}" "info"

	# GNOME / gdm3: WaylandEnable=false
	if [[ -d "${SDCARD}/etc/gdm3" || "${DESKTOP_ENVIRONMENT:-}" == "gnome" ]]; then
		mkdir -p "${SDCARD}"/etc/gdm3
		local gdmconf="${SDCARD}/etc/gdm3/custom.conf"
		if [[ -f "${gdmconf}" ]]; then
			# 已有配置: 只改/加 WaylandEnable, 不动其余
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
		mkdir -p "${SDCARD}"/etc/sddm.conf.d
		cat <<- 'SDDMCONF' > "${SDCARD}"/etc/sddm.conf.d/90-force-x11.conf
			# 非 Wayland: 强制 X11 会话
			[General]
			DisplayServer=x11
		SDDMCONF
	fi

	# X11 撕裂优化（modesetting TearFree）
	if [[ "${BUILD_DESKTOP}" == "yes" ]]; then
		mkdir -p "${SDCARD}"/etc/X11/xorg.conf.d
		cat <<- 'XORGCONF' > "${SDCARD}"/etc/X11/xorg.conf.d/20-tearfree.conf
			Section "Device"
			    Identifier "Rockchip-GPU"
			    Driver "modesetting"
			    Option "TearFree" "true"
			EndSection
		XORGCONF
	fi

	return 0
}

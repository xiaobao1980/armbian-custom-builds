#
# SPDX-License-Identifier: GPL-2.0
# Armbian build framework extension
#
# Enables 3D and multimedia, 4K VPU with Chromium, acceleration for Ubuntu. Debian only 3D
#
# =============================================================================
#  扩展选路规则（本仓约定，2026-10-30）
# -----------------------------------------------------------------------------
#   GNOME/Wayland 桌面 + RELEASE=jammy|noble  ->  本扩展 mesa-vpu（PPA 栈，零编译）
#   其它一切（X11 桌面 / Debian 系 / server）  ->  rkmpp-mpv.sh（自编译 RKMPP 栈）
#
#   两个扩展可以安全地同时写进 ENABLE_EXTENSIONS：判定互斥，只会有一个真正生效。
#   CI 的 build-image.yml 允许在 build.env 之外覆盖 RELEASE / DESKTOP_ENVIRONMENT，
#   所以「板级写死某一个扩展」会选错 —— 必须由扩展自己按实际参数判定。
#
#   ⚠️ _mesa_vpu__selected() 与 rkmpp-mpv.sh 的 _rkmpp_mpv__defer_to_mesa_vpu()
#      是同一判据的正反两面，改动务必同步，否则会双开（PPA 栈 + 自编译栈混装）
#      或双关（两条硬解路径都不装）。
#
#   可覆盖变量：
#     MESA_VPU_FORCE=yes      强制走本扩展（例如 X11 桌面也想要 PPA 的 ffmpeg/gstreamer
#                             rkmpp，而不是自编译 40 分钟）；此时 rkmpp-mpv 自动让位
#     MESA_VPU_PANTHOR=yes    非 noble 也加 panthor-gpu overlay（默认仅 noble）
# =============================================================================

# 本扩展是否生效 —— 全文件唯一判定点
function _mesa_vpu__selected() {
	# PPA 只发布 jammy / noble 两个系列（bookworm/trixie 等交给 rkmpp-mpv 自编译）
	[[ "${RELEASE:-}" =~ ^(jammy|noble)$ ]] || return 1

	# minimal 镜像不装
	[[ "${BUILD_MINIMAL:-}" == "yes" ]] && return 1

	# 显式强制（X11 桌面也走 PPA 栈）
	[[ "${MESA_VPU_FORCE:-no}" == "yes" ]] && return 0

	# 本扩展面向桌面镜像；server/CLI 由 rkmpp-mpv 接管（它只在有桌面时才配显示管理器）
	[[ "${BUILD_DESKTOP:-}" == "yes" ]] || return 1

	# jammy 只能走 PPA：自编译 mpv 0.41 需要 libplacebo >= 6.338.2，jammy 自带 4.x，必失败
	[[ "${RELEASE}" == "jammy" ]] && return 0

	# noble：只有 Wayland 能力桌面才走 PPA；X11 桌面（xfce/i3/cinnamon/mate/lxqt）让位 rkmpp-mpv
	case "${DESKTOP_ENVIRONMENT:-}" in
		gnome | kde-plasma | budgie) return 0 ;;
		*) return 1 ;;
	esac
}

function extension_prepare_config__mesa-vpu() {
	if ! _mesa_vpu__selected; then
		display_alert "Extension: ${EXTENSION}" \
			"skip (${RELEASE:-?}/${DESKTOP_ENVIRONMENT:-no-desktop}): not a jammy|noble Wayland desktop -> rkmpp-mpv.sh owns this combo (if the family supports it)" "info"
		return 0
	fi

	# panthor DTB overlay：仅 noble（jammy 自带 mesa 22.x 无 panthor 驱动，
	# 强行开 overlay 会让 GPU 绑到无用户态的 panthor 上、GL 掉回 llvmpipe）
	if [[ "${LINUXFAMILY}" =~ ^(rockchip-rk3588|rk35xx)$ && "${BRANCH}" == "vendor" ]]; then
		if [[ "${RELEASE}" == "noble" || "${MESA_VPU_PANTHOR:-no}" == "yes" ]]; then
			# 不用 `declare -g`（bash 3.2 不支持，本地 mock/老 shell 会报错）；
			# 这种写法在 bash 3.2+ 与 5.x 下语义一致。
			DEFAULT_OVERLAYS="${DEFAULT_OVERLAYS:+${DEFAULT_OVERLAYS} }panthor-gpu"
			display_alert "Extension: ${EXTENSION}" "panthor-gpu overlay enabled (${RELEASE})" "info"
		fi
	fi

	display_alert "Extension: ${EXTENSION}" "mesa-vpu selected: ${RELEASE}/${DESKTOP_ENVIRONMENT} (Wayland, PPA stack)" "info"
	return 0
}

function post_install_kernel_debs__mesa-vpu() {
	_mesa_vpu__selected || return 0

	# Packages that are going to be installed, always, both for cli and desktop
	declare -a pkgs=("libgl1-mesa-dri")
	# PPA 专属可选包：缺失只告警，不能让整镜像挂掉
	declare -a opt_pkgs=()

	if [[ "${BUILD_DESKTOP}" == "yes" ]]; then
		pkgs+=("libglx-mesa0") # x11 stuff all the way
		pkgs+=("mesa-utils" "mesa-utils-extra")
		pkgs+=("glmark2" "glmark2-wayland" "glmark2-es2-wayland" "glmark2-es2" "glmark2-x11" "glmark2-es2-x11")
	fi

	# ---- amazingfated PPA：只对 vendor 内核的 rockchip 家族的桌面镜像加 ----
	local ppa_ok=0
	if [[ "${BUILD_DESKTOP}" == "yes" ]] \
		&& [[ "${LINUXFAMILY}" =~ ^(rockchip-rk3588|rk35xx)$ && "${BRANCH}" =~ ^(vendor)$ ]]; then
		display_alert "Adding amazingfated's multimedia PPAs" "${EXTENSION}" "info"
		# 加 PPA 失败不再中止构建：退回发行版自带 mesa（无 rkmpp），至少 3D/桌面可用
		if do_with_retries 3 chroot_sdcard add-apt-repository ppa:liujianfeng1994/rockchip-multimedia --yes --no-update; then
			ppa_ok=1
			display_alert "Pinning amazingfated's multimedia PPAs" "${EXTENSION}" "info"
			cat <<- EOF > "${SDCARD}"/etc/apt/preferences.d/amazingfated-rk3588-rockchip-multimedia-pin
				Package: *
				Pin: release o=LP-PPA-liujianfeng1994-rockchip-multimedia
				Pin-Priority: 1001
			EOF
		else
			display_alert "add-apt-repository failed; falling back to distro mesa (no rkmpp)" "${EXTENSION}" "warn"
		fi
	fi

	display_alert "Updating sources list, after adding all PPAs" "${EXTENSION}" "info"
	do_with_retries 3 chroot_sdcard_apt_get_update

	# KDE neon downgrades base-files for some reason. This prevents tacking it
	do_with_retries 3 chroot_sdcard apt-mark hold base-files

	if [[ "${BUILD_DESKTOP}" == "yes" ]]; then
		# 该库必须在 rockchip-multimedia-config 之前装。包名随 time_t 迁移变化：
		#   jammy            -> libv4l-0
		#   noble 及之后      -> libv4l-0t64
		local v4l_pkg="libv4l-0"
		case "${RELEASE}" in
			noble | oracular | plucky | questing | resolute) v4l_pkg="libv4l-0t64" ;;
		esac
		do_with_retries 3 chroot_sdcard_apt_get_install "${v4l_pkg}" \
			|| display_alert "install ${v4l_pkg} failed; rockchip-multimedia-config may fail too" "${EXTENSION}" "warn"
	fi

	if [[ ${ppa_ok} -eq 1 ]]; then
		pkgs+=("rockchip-multimedia-config" "libv4l-rkmpp")
		# PPA 里 gstreamer rockchip 插件的真实包名是 gstreamer1.0-rockchip1
		# （jammy / noble 一致；不存在 gstreamer1.0-rockchip 这个包，装它会整个 apt 事务失败）
		opt_pkgs+=("gstreamer1.0-rockchip1" "libwidevinecdm0")
	fi

	display_alert "Installing 3D extension packages" "${EXTENSION}" "info"
	do_with_retries 3 chroot_sdcard_apt_get_install "${pkgs[@]}"

	if [[ ${#opt_pkgs[@]} -gt 0 ]]; then
		display_alert "Installing optional PPA packages: ${opt_pkgs[*]}" "${EXTENSION}" "info"
		do_with_retries 2 chroot_sdcard_apt_get_install "${opt_pkgs[@]}" \
			|| display_alert "optional PPA packages not all installed (${opt_pkgs[*]})" "${EXTENSION}" "warn"
	fi

	# This library gets downgraded
	if [[ "${BUILD_DESKTOP}" == "yes" ]]; then
		if [[ "${RELEASE}" =~ ^(oracular|noble)$ && "${ARCH}" == arm* ]]; then
			do_with_retries 3 chroot_sdcard apt-mark hold libdav1d7
		fi
	fi

	display_alert "Upgrading all packages, including hopefully all mesa packages" "${EXTENSION}" "info"
	do_with_retries 3 chroot_sdcard_apt_get -o Dpkg::Options::="--force-confold" --allow-downgrades dist-upgrade

	# KDE neon downgrade hack undo
	do_with_retries 3 chroot_sdcard apt-mark unhold base-files

	if [[ "${BUILD_DESKTOP}" == "yes" ]]; then
		if [[ "${RELEASE}" =~ ^(oracular|noble)$ && "${ARCH}" == arm* ]]; then
			do_with_retries 3 chroot_sdcard apt-mark unhold libdav1d7
		fi
	fi

	return 0
}

function post_armbian_repo_customize_image__mesa-vpu() {
	_mesa_vpu__selected || return 0

	# Add browser if building a desktop - architecture dependent
	[[ "${BUILD_DESKTOP}" != "yes" ]] && return 0

	if [[ "${ARCH}" == "amd64" ]]; then
		# amd64: prefer google-chrome
		pkgs=("google-chrome-stable")
	elif [[ "${ARCH}" =~ ^(arm64|armhf)$ ]]; then
		# arm64/armhf: use chromium
		pkgs=("chromium")
	else
		# other architectures: fallback to firefox
		pkgs=("firefox")
	fi

	display_alert "Installing browser" "${EXTENSION}" "info"
	do_with_retries 3 chroot_sdcard_apt_get_install "${pkgs[@]}"

	return 0
}

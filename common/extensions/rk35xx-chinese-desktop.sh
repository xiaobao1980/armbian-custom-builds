#
# SPDX-License-Identifier: GPL-2.0
# Armbian build framework extension
#
# rk35xx-chinese-desktop: RK35xx 系列（RK3566/RK3568/RK3576/RK3588）厂商内核镜像
# 的中文桌面「通用设置」。跨板共享，但**多板编译互不影响**：
#
#   1) 本扩展只对 LINUXFAMILY=rk35xx|rockchip-rk3588 且 BRANCH=vendor 生效，
#      其它板卡/内核/最小镜像在 prepare 阶段直接跳过（零副作用）；
#   2) 所有改动只写入 ${SDCARD}（当前镜像根），不写宿主、不写全局缓存；
#   3) 板级差异全部由各板 build.env / .csc 注入环境变量，公共代码不写死型号：
#        RK_CN_USER / RK_CN_USER_PASS / RK_CN_ROOT_PASS
#        RK_CN_TZ / RK_CN_IME(fcitx5|ibus|auto) / RK_CN_LOCALES_ALL / RK_CN_RIME_MIRROR
#   4) 每块板在全新 clone 的 build 树里编译（sync-board-to-build.sh 只拷本板目录），
#      extensions 虽共享，但守卫+变量隔离，不会互相污染镜像。
#
# 落盘内容（全部在镜像内）：
#   · root 密码；首次启动 rc.local 自动创建普通用户（幂等）
#   · Locale=zh_CN.UTF-8 / 时区 / 中文字体 / 中国 NTP 源
#   · 输入法：GNOME→ibus-rime；X11/XFCE 等→fcitx5-rime（均配 rime-ice 雾凇拼音）
#   · Chromium 中文界面（语言包 + --lang + ApplicationLocale + Local State）
#   · DTB 过滤：只保留本板 dtb 与本平台 dtbo（宿主侧直接操作 ${SDCARD}/boot）
#
# 与其它扩展的关系：
#   · mpv/ffmpeg 硬解栈由 rkmpp-mpv.sh 负责；Chromium 硬解参数由 mesa-vpu.sh 的 PPA
#     负责。本扩展只管「中文」部分，不重复安装解码栈。
#   · rkmpp-mpv.sh 会把 GNOME 强制成 X11（WaylandEnable=false）。若某板要保留
#     GNOME/Wayland + ibus-rime，请在该板 build.env 设 RK_CN_IME=ibus 并**不启用**
#     rkmpp-mpv 的强制 X11（或改其逻辑），二者对会话类型的要求互斥。
# =============================================================================

# 守卫：只放行 RK35xx/RK3588 厂商内核 + 非最小镜像
_rk_cn_should_run() {
	[[ "${LINUXFAMILY}" =~ ^(rk35xx|rockchip-rk3588)$ && "${BRANCH}" == "vendor" ]] || return 1
	[[ "${BUILD_MINIMAL:-no}" == "yes" ]] && return 1
	return 0
}

function extension_prepare_config__rk35xx_chinese_desktop() {
	if ! _rk_cn_should_run; then
		display_alert "Extension: ${EXTENSION}" "needs vendor kernel on rk35xx/rk3588 & non-minimal; skipping" "warn"
		return 0
	fi
	display_alert "Extension: ${EXTENSION}" "Chinese desktop (user/locale/IME/Chromium/DTB) enabled for ${LINUXFAMILY}/${BRANCH}" "info"
	return 0
}

function post_install_kernel_debs__rk35xx_chinese_desktop() {
	_rk_cn_should_run || return 0

	local SCRIPT_DIR ASSET
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	ASSET="${SCRIPT_DIR}/chinese-desktop/rk35xx-chinese-desktop.sh"
	if [[ ! -f "${ASSET}" ]]; then
		display_alert "chinese-desktop asset missing at ${ASSET}" "${EXTENSION}" "err"
		return 0
	fi

	# ---- 1. 暂存 chroot 执行器（用完即删，不残留进镜像） ----
	display_alert "Staging rk35xx chinese-desktop executor into chroot" "${EXTENSION}" "info"
	mkdir -p "${SDCARD}/usr/local/sbin"
	cp "${ASSET}" "${SDCARD}/usr/local/sbin/rk35xx-chinese-desktop.sh"
	chmod +x "${SDCARD}/usr/local/sbin/rk35xx-chinese-desktop.sh"

	# ---- 2. 板级变量（全部可由 build.env / .csc 覆盖） ----
	local bd="no"
	[[ "${BUILD_DESKTOP:-no}" == "yes" ]] && bd="yes"
	local ime="${RK_CN_IME:-auto}"
	local cn_user="${RK_CN_USER:-xiaobao}"
	local cn_upass="${RK_CN_USER_PASS:-123456}"
	local cn_rpass="${RK_CN_ROOT_PASS:-123456789}"
	local cn_tz="${RK_CN_TZ:-Asia/Shanghai}"
	local cn_locales_all="${RK_CN_LOCALES_ALL:-1}"

	# ---- 3. chroot 内执行（env 传参，无 shell 包裹） ----
	display_alert "Running Chinese desktop setup in chroot (desktop=${DESKTOP_ENVIRONMENT:-none}, ime=${ime})" "${EXTENSION}" "info"
	chroot_sdcard "env \
		RK_CN_BUILD_DESKTOP=${bd} \
		RK_CN_DESKTOP_ENV=${DESKTOP_ENVIRONMENT:-xfce} \
		RK_CN_IME=${ime} \
		RK_CN_USER=${cn_user} \
		RK_CN_USER_PASS=${cn_upass} \
		RK_CN_ROOT_PASS=${cn_rpass} \
		RK_CN_TZ=${cn_tz} \
		RK_CN_LOCALES_ALL=${cn_locales_all} \
		RK_CN_RIME_MIRROR=${RK_CN_RIME_MIRROR:-} \
		bash /usr/local/sbin/rk35xx-chinese-desktop.sh" \
		|| display_alert "Chinese desktop setup returned non-zero (image may be partially configured)" "${EXTENSION}" "warn"

	# 执行器一次性使用，删除避免残留
	rm -f "${SDCARD}/usr/local/sbin/rk35xx-chinese-desktop.sh"

	# ---- 4. DTB 过滤（宿主侧；直接操作 ${SDCARD}/boot，避开 chroot /boot 挂载时序） ----
	_rk_cn_filter_dtb

	display_alert "Chinese desktop setup complete" "${EXTENSION}" "info"
	return 0
}

# =============================================================================
# DTB 过滤：只保留板卡相关 dtb/dtbo
# -----------------------------------------------------------------------------
# 安全性第一：无法确定本板 dtb 时**绝不删除**任何文件（宁可保留全部 dtb，
# 也不能删错导致镜像无法启动）。
# 板卡识别来源优先级：镜像内 armbian-image-release 的 BOARD > 构建变量 ${BOARD}。
# =============================================================================
_rk_cn_filter_dtb() {
	local dtb_dir="${SDCARD}/boot/dtb/rockchip"
	local overlay_dir="${dtb_dir}/overlay"
	local board_name="" board_dtb="" chip_prefix="" extra_dtbo="rockchip-rk3588-panthor-gpu.dtbo"
	local f

	# 1) 板卡名：优先读镜像内 armbian-image-release（构建期最准）
	for f in "${SDCARD}/etc/armbian-image-release" "${SDCARD}/etc/armbian-release"; do
		[[ -r "${f}" ]] || continue
		board_name="$(sed -n 's/^BOARD=//p' "${f}" 2>/dev/null | tr -d '"' | head -1)"
		[[ -n "${board_name}" ]] && break
	done
	[[ -n "${board_name}" ]] || board_name="${BOARD:-}"

	[[ -d "${dtb_dir}" ]] || { display_alert "DTB filter: ${dtb_dir} 不存在，跳过" "${EXTENSION}" "warn"; return 0; }
	[[ -n "${board_name}" ]] || { display_alert "DTB filter: 无法确定 BOARD，跳过（保留全部 dtb）" "${EXTENSION}" "warn"; return 0; }

	# 2) 匹配本板 dtb（板卡名子串匹配；取第一个命中）
	board_dtb="$(find "${dtb_dir}" -maxdepth 1 -type f -name '*.dtb' -print 2>/dev/null \
		| grep -E "${board_name}" | head -n1 | sed 's#^.*/##')"
	if [[ -z "${board_dtb}" ]]; then
		display_alert "DTB filter: 未匹配到 BOARD=${board_name} 的 dtb，跳过（保留全部 dtb）" "${EXTENSION}" "warn"
		return 0
	fi

	# 3) 芯片前缀（决定保留哪些 dtbo）
	chip_prefix="$(printf '%s' "${LINUXFAMILY:-}" | grep -oE 'rk35[0-9]{2}' | head -1)"
	[[ -n "${chip_prefix}" ]] || chip_prefix="$(printf '%s' "${board_name}" | grep -oE 'rk35[0-9]{2}' | head -1)"
	[[ -n "${chip_prefix}" ]] || chip_prefix="$(printf '%s' "${board_dtb}" | sed -E 's/^([a-z0-9]+)-.*/\1/')"
	case "${chip_prefix}" in *.dtb*) chip_prefix="" ;; esac

	display_alert "DTB filter: BOARD=${board_name} 保留 ${board_dtb}，dtbo 前缀=${chip_prefix:-<全部>}" "${EXTENSION}" "info"

	# 4) 清理非本板 dtb
	find "${dtb_dir}" -maxdepth 1 -type f -name '*.dtb' ! -name "${board_dtb}" -exec rm -f {} \; 2>/dev/null || true

	# 5) 清理非本平台 dtbo（保留 EXTRA_DTBO）
	if [[ -n "${chip_prefix}" && -d "${overlay_dir}" ]]; then
		find "${overlay_dir}" -maxdepth 1 -type f -name '*.dtbo' \
			! -name "${chip_prefix}-*" ! -name "${extra_dtbo}" -exec rm -f {} \; 2>/dev/null || true
	fi

	# 6) 若 /boot/dtb 是符号链接指向 /usr/lib/linux-image-*/rockchip，同步清理实体目录
	for f in "${SDCARD}"/usr/lib/linux-image-*/rockchip; do
		[[ -d "${f}" ]] || continue
		find "${f}" -maxdepth 1 -type f -name '*.dtb' ! -name "${board_dtb}" -exec rm -f {} \; 2>/dev/null || true
		if [[ -n "${chip_prefix}" && -d "${f}/overlay" ]]; then
			find "${f}/overlay" -maxdepth 1 -type f -name '*.dtbo' \
				! -name "${chip_prefix}-*" ! -name "${extra_dtbo}" -exec rm -f {} \; 2>/dev/null || true
		fi
	done

	display_alert "DTB filter: 完成（保留 ${board_dtb} / ${chip_prefix:-*}-*.dtbo / ${extra_dtbo}）" "${EXTENSION}" "info"
	return 0
}

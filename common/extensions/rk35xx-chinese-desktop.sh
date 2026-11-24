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
#      DTB_KEEP_EXTRA（空格分隔的 dtb 文件名）由板级配置提供，见 _rk_cn_filter_dtb 注释。
#      ⚠️ 口令留空 = 不写该口令，本扩展不再兜底任何默认口令（历史缺陷：兜底
#      123456/123456789 被静默烧进镜像）。CI 必须走凭据文件，见下。
#   4) 每块板在全新 clone 的 build 树里编译（sync-board-to-build.sh 只拷本板目录），
#      extensions 虽共享，但守卫+变量隔离，不会互相污染镜像。
#
# 落盘内容（全部在镜像内）：
#   · root 密码；首次启动 rc.local 自动创建普通用户（幂等）
#   · Locale=zh_CN.UTF-8 / 时区 / 中文字体 / 中国 NTP 源
#   · AccountsService Language=zh_CN.UTF-8（GNOME/GDM 会话语言的实际来源，
#     缺它就会出现「系统 locale 中文、桌面全英文」——187 实测根因）
#   · 输入法：GNOME→ibus-rime；X11/XFCE 等→fcitx5-rime（均配 rime-ice 雾凇拼音）
#   · Chromium 中文界面（语言包 + --lang + ApplicationLocale + Local State）
#   · DTB 过滤：只保留本板 dtb 与本平台 dtbo（宿主侧直接操作 ${SDCARD}/boot）
#
# 发行版适配：全套逻辑按「Ubuntu / Debian」和「桌面环境」自适应，不锁发行版 ——
#   jammy/noble 走 language-pack-*；trixie/bookworm 走 locales-all + 包自带翻译；
#   字体/语言包一律逐包安装，单包在某发行版缺失不会拖垮整条 apt 事务。
#
# 与其它扩展的关系：
#   · mpv/ffmpeg 硬解栈由 rkmpp-mpv.sh 负责；Chromium 硬解（+rkmpp 包与 PPA）由
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

# ---------------------------------------------------------------- 凭据来源
# ⚠️ 为什么必须走文件（与 default-user.sh 同一个坑）：
#   compile.sh 以非 root 启动时会 `exec sudo --preserve-env <3 个 ARMBIAN 变量>
#   bash compile.sh ...` 重启自己，普通环境变量一律被 sudo 丢弃 → CI 里
#   step `env: RK_CN_ROOT_PASS=...` 到这里已经是空的。历史上这里回退到
#   ${RK_CN_ROOT_PASS:-123456789}，于是「用户填的口令没生效、镜像里是默认弱口令」
#   成为静默缺陷。现在：CI 构建前写 ${SRC}/userpatches/.rk-cn-pass.env（0600），
#   这里 source 一次后立即删除；拿不到口令就【不写口令】，绝不回退默认值。
_rk_cn_load_pass_file() {
	[[ "${_RK_CN_FILE_LOADED:-no}" == "yes" ]] && return 0
	_RK_CN_FILE_LOADED=yes

	local f="${SRC:-}/userpatches/.rk-cn-pass.env"
	[[ -n "${SRC:-}" && -r "${f}" ]] || return 0

	# shellcheck disable=SC1090
	source "${f}"

	display_alert "Extension: ${EXTENSION}" "已从 userpatches/.rk-cn-pass.env 载入中文桌面凭据（sudo 环境白名单会丢弃 env，故走文件）" "info"

	# 用后即毁：不在构建目录/缓存里留明文口令（CI 侧另有 always() 清理兜底）
	rm -f "${f}" 2>/dev/null || true
	return 0
}

# 校验：非法输入直接中止构建 —— 交付一个「没配好口令」的构建失败，远好于
# 交付一个「带默认弱口令」的镜像。字符集与 default-user.sh 逐字一致（两边同改），
# 目的是让值能安全地塞进单引号与 chroot 命令行（无空格 / 无引号 / 无 $ 与反引号）。
_rk_cn_validate() {
	_rk_cn_load_pass_file

	local err=0 v
	if [[ -n "${RK_CN_USER:-}" ]] && ! [[ "${RK_CN_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
		display_alert "RK_CN_USER 非法" "'${RK_CN_USER}'（要求 ^[a-z_][a-z0-9_-]{0,31}$）" "err"
		err=1
	fi
	for v in RK_CN_USER_PASS RK_CN_ROOT_PASS; do
		[[ -z "${!v:-}" ]] && continue
		if ! [[ "${!v}" =~ ^[A-Za-z0-9._+#=:@%-]{4,64}$ ]]; then
			display_alert "${v} 字符集受限" \
				"只允许 A-Z a-z 0-9 . _ + # = : @ % -（4~64 位）；含空格/引号/\$ 的值会污染 chroot 命令行，请改用上述字符或留空表示不设置" "err"
			err=1
		fi
	done

	[[ ${err} -eq 0 ]] || exit 1
	return 0
}

function extension_prepare_config__rk35xx_chinese_desktop() {
	if ! _rk_cn_should_run; then
		display_alert "Extension: ${EXTENSION}" "needs vendor kernel on rk35xx/rk3588 & non-minimal; skipping" "warn"
		return 0
	fi
	_rk_cn_validate
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

	# ---- 2. 板级变量（全部可由 build.env / .csc / 凭据文件覆盖） ----
	_rk_cn_load_pass_file
	local bd="no"
	[[ "${BUILD_DESKTOP:-no}" == "yes" ]] && bd="yes"
	local ime="${RK_CN_IME:-auto}"
	local cn_user="${RK_CN_USER:-xiaobao}"
	local cn_upass="${RK_CN_USER_PASS:-}"
	local cn_rpass="${RK_CN_ROOT_PASS:-}"
	local cn_tz="${RK_CN_TZ:-Asia/Shanghai}"
	local cn_locales_all="${RK_CN_LOCALES_ALL:-1}"

	if [[ -z "${cn_upass}" && -z "${cn_rpass}" ]]; then
		display_alert "Extension: ${EXTENSION}" \
			"未取到 RK_CN_USER_PASS / RK_CN_ROOT_PASS：本次不写入任何口令（沿用 default-user 扩展的凭据或发行版默认）。要设口令请写 userpatches/.rk-cn-pass.env" "warn"
	fi

	# ---- 3. chroot 内执行（值已过白名单校验；单引号包裹，防空格分词与元字符） ----
	display_alert "Running Chinese desktop setup in chroot (desktop=${DESKTOP_ENVIRONMENT:-none}, ime=${ime})" "${EXTENSION}" "info"
	chroot_sdcard "env \
		RK_CN_BUILD_DESKTOP='${bd}' \
		RK_CN_DESKTOP_ENV='${DESKTOP_ENVIRONMENT:-xfce}' \
		RK_CN_IME='${ime}' \
		RK_CN_USER='${cn_user}' \
		RK_CN_USER_PASS='${cn_upass}' \
		RK_CN_ROOT_PASS='${cn_rpass}' \
		RK_CN_TZ='${cn_tz}' \
		RK_CN_LOCALES_ALL='${cn_locales_all}' \
		RK_CN_RIME_MIRROR='${RK_CN_RIME_MIRROR:-}' \
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
# -----------------------------------------------------------------------------
# 一块板出多份 dtb 时（如 lz120 的双屏 / 单屏变体，靠 armbianEnv.txt 的 fdtfile 切换），
# 由板级配置给 DTB_KEEP_EXTRA 传空格分隔的文件名：这些 dtb 既**不参与**下面的
# 「唯一命中」判定（否则命中 2 个 → 触发安全分支 → 全量厂商 dtb 留在镜像里），
# 也**一定不被删除**。留空 = 维持原行为。
# =============================================================================
_rk_cn_filter_dtb() {
	local dtb_dir="${SDCARD}/boot/dtb/rockchip"
	local overlay_dir="${dtb_dir}/overlay"
	local board_name="" board_dtb="" chip_prefix="" extra_dtbo="rockchip-rk3588-panthor-gpu.dtbo"
	local f

	# 板级保留名单（词法切分，不展开 glob：值来自仓库内的 .csc，不是外部输入）
	local -a keep_extra=() _keep_args=()
	read -r -a keep_extra <<< "${DTB_KEEP_EXTRA:-}" || true
	for f in ${keep_extra[@]+"${keep_extra[@]}"}; do
		[[ -n "${f}" ]] && _keep_args+=('!' '-name' "${f}")
	done
	local keep_note=""
	[[ ${#keep_extra[@]} -gt 0 ]] && keep_note=" / DTB_KEEP_EXTRA: ${keep_extra[*]}"

	# 1) 板卡名：优先读镜像内 armbian-image-release（构建期最准）
	for f in "${SDCARD}/etc/armbian-image-release" "${SDCARD}/etc/armbian-release"; do
		[[ -r "${f}" ]] || continue
		board_name="$(sed -n 's/^BOARD=//p' "${f}" 2>/dev/null | tr -d '"' | head -1)"
		[[ -n "${board_name}" ]] && break
	done
	[[ -n "${board_name}" ]] || board_name="${BOARD:-}"

	[[ -d "${dtb_dir}" ]] || { display_alert "DTB filter: ${dtb_dir} 不存在，跳过" "${EXTENSION}" "warn"; return 0; }
	[[ -n "${board_name}" ]] || { display_alert "DTB filter: 无法确定 BOARD，跳过（保留全部 dtb）" "${EXTENSION}" "warn"; return 0; }

	# 2) 匹配本板 dtb
	#    旧实现 `find | grep -E "${board_name}" | head -n1`：正则未转义（板名里的 . / +
	#    当元字符用）、子串匹配、find 顺序不确定 —— 一旦同一目录里有多个都能匹配
	#    （rock-5b 与 rock-5b-model-b、rk3588s- 与 rk3588b- 前缀同名板），
	#    head -n1 取到的那个被保留、**其余全部删除**，完全可能把唯一能启动的
	#    dtb 删掉变砖。改成确定性的两级匹配：精确后缀 → 芯片前缀收窄 → 仍不唯一就【不删】。
	local -a _dtb_raw=() _dtb_all=() _dtb_hit=()
	local _d _k _is_keep
	while IFS= read -r _d; do
		[[ -n "${_d}" ]] || continue
		_d="$(basename "${_d}")"
		_dtb_raw+=("${_d}")
		# 名单内的 dtb 不参与唯一性判定（它们是「有意为之的第二份」，不是同板误命中）
		_is_keep=no
		for _k in ${keep_extra[@]+"${keep_extra[@]}"}; do
			[[ "${_d}" == "${_k}" ]] && _is_keep=yes && break
		done
		[[ "${_is_keep}" == "yes" ]] && continue
		_dtb_all+=("${_d}")
	done < <(find "${dtb_dir}" -maxdepth 1 -type f -name '*.dtb' -print 2>/dev/null | LC_ALL=C sort)

	if [[ ${#_dtb_raw[@]} -eq 0 ]]; then
		display_alert "DTB filter: ${dtb_dir} 下没有任何 dtb，跳过" "${EXTENSION}" "warn"
		return 0
	fi
	# 名单把候选清空了（例如 DTB_KEEP_EXTRA 误把本板 dtb 也列进去）→ 退回全量参与判定，
	# 免得静默走进「0 命中 → 什么都不删」，把几百份厂商 dtb 留在镜像里。
	[[ ${#_dtb_all[@]} -gt 0 ]] || _dtb_all=("${_dtb_raw[@]}")

	# 名单里写了镜像中不存在的名字 = 板级配置打错字，第二份 dtb 其实会被删掉：必须喊出来
	for _k in ${keep_extra[@]+"${keep_extra[@]}"}; do
		local -a _found=()
		for _d in "${_dtb_raw[@]}"; do
			[[ "${_d}" == "${_k}" ]] && _found+=("${_d}")
		done
		[[ ${#_found[@]} -gt 0 ]] || display_alert "DTB filter: DTB_KEEP_EXTRA 里的 ${_k} 在 ${dtb_dir} 不存在（拼错或该 dtb 没编出来）" \
			"${EXTENSION}" "warn"
	done

	# 2a) 精确后缀 -<board>.dtb（不再是任意子串、不再当正则解释）
	for _d in "${_dtb_all[@]}"; do
		[[ "${_d}" == *"-${board_name}.dtb" ]] && _dtb_hit+=("${_d}")
	done
	# 2b) 兜底：没有精确命中时退到子串匹配（仍用字面比较，不是正则）
	if [[ ${#_dtb_hit[@]} -eq 0 ]]; then
		for _d in "${_dtb_all[@]}"; do
			[[ "${_d}" == *"${board_name}"* ]] && _dtb_hit+=("${_d}")
		done
	fi
	# 2c) 多个命中 → 用芯片前缀（rk35xx 本平台）再收一轮
	if [[ ${#_dtb_hit[@]} -gt 1 ]]; then
		# 用 bash 正则而不是 printf|grep：grep 无匹配返回 1，pipefail 会把它传给整条管道，
		# 裸赋值即失败；rk35xx 这个 LINUXFAMILY 值本就凑不出「rk35+两位数字」，命中不了。
		local _chip=''
		if [[ "${LINUXFAMILY:-}" =~ rk35[0-9]{2} ]]; then _chip="${BASH_REMATCH[0]}"; fi
		if [[ -n "${_chip}" ]]; then
			local -a _narrow=()
			for _d in "${_dtb_hit[@]}"; do
				[[ "${_d}" == *"${_chip}"* ]] && _narrow+=("${_d}")
			done
			[[ ${#_narrow[@]} -gt 0 ]] && _dtb_hit=("${_narrow[@]}")
		fi
	fi
	# 2d) 仍不唯一且本板声明了多份 dtb → 用出厂 fdtfile（BOOT_FDT_FILE）定唯一：镜像启动用的
	#     就是这一份，按它保留比按板名猜更准。闸门加 ${#keep_extra[@]} -gt 0 是为了**只**影响
	#     显式列了 DTB_KEEP_EXTRA 的板子 —— 没列的板子走不到这里，与改动前逐字节同行为
	#     （否则原本「命中多个 → 一个都不删」的板子会突然开始删 dtb）。
	if [[ ${#_dtb_hit[@]} -ne 1 && ${#keep_extra[@]} -gt 0 && -n "${BOOT_FDT_FILE:-}" ]]; then
		local _hint="$(basename "${BOOT_FDT_FILE}")" _hit2=()
		for _d in "${_dtb_raw[@]}"; do
			[[ "${_d}" == "${_hint}" ]] && _hit2+=("${_d}")
		done
		if [[ ${#_hit2[@]} -eq 1 ]]; then
			display_alert "DTB filter: 板名匹配不唯一，改用 BOOT_FDT_FILE=${_hint} 定唯一份" "${EXTENSION}" "info"
			_dtb_hit=("${_hit2[@]}")
		fi
	fi
	if [[ ${#_dtb_hit[@]} -ne 1 ]]; then
		display_alert "DTB filter: BOARD=${board_name} 命中 ${#_dtb_hit[@]} 个 dtb（${_dtb_hit[*]:-无}），无法唯一确定" \
			"${EXTENSION}" "warn"
		display_alert "DTB filter: 安全优先，本次【不删除】任何 dtb（保留全部 ${#_dtb_raw[@]} 个）" "${EXTENSION}" "warn"
		return 0
	fi
	board_dtb="${_dtb_hit[0]}"

	# 3) 芯片前缀（决定保留哪些 dtbo）：同 2c 用 bash 正则，别用 printf|grep 管道
	chip_prefix=''
	if [[ "${LINUXFAMILY:-}" =~ rk35[0-9]{2} ]]; then chip_prefix="${BASH_REMATCH[0]}"; fi
	if [[ -z "${chip_prefix}" && "${board_name}" =~ rk35[0-9]{2} ]]; then chip_prefix="${BASH_REMATCH[0]}"; fi
	[[ -n "${chip_prefix}" ]] || chip_prefix="$(printf '%s' "${board_dtb}" | sed -E 's/^([a-z0-9]+)-.*/\1/')"
	case "${chip_prefix}" in *.dtb*) chip_prefix="" ;; esac

	display_alert "DTB filter: BOARD=${board_name} 保留 ${board_dtb}，dtbo 前缀=${chip_prefix:-<全部>}" "${EXTENSION}" "info"

	# 4) 清理非本板 dtb（板级保留名单一并留下）
	find "${dtb_dir}" -maxdepth 1 -type f -name '*.dtb' ! -name "${board_dtb}" ${_keep_args[@]+"${_keep_args[@]}"} -exec rm -f {} \; 2>/dev/null || true

	# 5) 清理非本平台 dtbo（保留 EXTRA_DTBO）
	if [[ -n "${chip_prefix}" && -d "${overlay_dir}" ]]; then
		find "${overlay_dir}" -maxdepth 1 -type f -name '*.dtbo' \
			! -name "${chip_prefix}-*" ! -name "${extra_dtbo}" -exec rm -f {} \; 2>/dev/null || true
	fi

	# 6) 若 /boot/dtb 是符号链接指向 /usr/lib/linux-image-*/rockchip，同步清理实体目录
	for f in "${SDCARD}"/usr/lib/linux-image-*/rockchip; do
		[[ -d "${f}" ]] || continue
		find "${f}" -maxdepth 1 -type f -name '*.dtb' ! -name "${board_dtb}" ${_keep_args[@]+"${_keep_args[@]}"} -exec rm -f {} \; 2>/dev/null || true
		if [[ -n "${chip_prefix}" && -d "${f}/overlay" ]]; then
			find "${f}/overlay" -maxdepth 1 -type f -name '*.dtbo' \
				! -name "${chip_prefix}-*" ! -name "${extra_dtbo}" -exec rm -f {} \; 2>/dev/null || true
		fi
	done

	display_alert "DTB filter: 完成（保留 ${board_dtb}${keep_note} / ${chip_prefix:-*}-*.dtbo / ${extra_dtbo}）" "${EXTENSION}" "info"
	return 0
}

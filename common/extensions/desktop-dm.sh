#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
# Armbian build framework extension
#
# desktop-dm —— 保证桌面镜像里「graphical.target 能真正拉起显示管理器」
#
# =============================================================================
#  为什么需要这个扩展（187 实测，2026-11-02）
# -----------------------------------------------------------------------------
#  症状：noble + GNOME/Wayland 镜像烧卡后停在文字控制台，`systemctl status gdm3`
#        报 not-found/未启动，日志里 graphical.target 找不到 display-manager.service。
#  根因（缺陷 A）：chroot 里装 gdm3 时，Debian/Ubuntu 的 gdm3.postinst 只跑
#        `deb-systemd-helper enable`，它建的是 .wants 链接，**不会**建
#        /etc/systemd/system/display-manager.service 这个 Alias。该 Alias 正常由
#        `systemctl enable gdm3` 在真实系统（有 systemd 在跑）时创建 —— chroot 里
#        没有 PID 1，于是整条链缺最后一环：
#            graphical.target → Wants=display-manager.service → （缺失）→ 文字控制台
#        XFCE/lightdm 路线不受影响，因为 lightdm 的 deb 自带该链接，所以这个坑是
#        GNOME/gdm 独有，只在 Wayland 定制版（默认 gnome）暴露。
#
#  做法：在所有定制步骤之后（post_armbian_repo_customize_image）检查一次，
#        * 检测已装的 DM 与它的 unit 名（gdm3/gdm/lightdm/sddm 都覆盖）
#        * display-manager.service 缺失才补（优先 `systemctl --root` 让 systemd
#          自己算 Alias；不可用则按真实 unit 路径手工建链接）
#        * 补 graphical.target.wants/display-manager.service
#        * 若 default.target 指向 multi-user.target，改回 graphical.target
#        全部幂等：已存在就不动，重复构建不会叠加。
#
#  与 default-user.sh 的分工：本扩展只保证「DM 能起来」，不建用户、不写自动登录；
#  default-user.sh 负责建用户 + gdm3 custom.conf。两者可同时启用，互不覆盖。
#
#  可选变量：
#    DESKTOP_DM_FIX=no        显式关闭（本扩展本来就只在 BUILD_DESKTOP=yes 生效）
#    DESKTOP_DM_FORCE_TARGET=no  不修改 default.target（默认会修，仅当它指向
#                                multi-user.target 这种明显错误的情况）
# =============================================================================

# rootfs 内某个 unit 文件的实际路径（/usr/lib 优先，兼容老的 /lib 布局）
_desktop_dm__rootfs_unit() {
	local unit="$1" base
	for base in usr/lib/systemd/system lib/systemd/system; do
		if [[ -f "${SDCARD}/${base}/${unit}" ]]; then
			printf '%s' "/${base}/${unit}"
			return 0
		fi
	done
	return 1
}

# 检测已安装的显示管理器（按可执行文件判断，比猜 unit 名可靠）
_desktop_dm__detect() {
	local dm
	for dm in gdm3 gdm lightdm sddm; do
		if [[ -x "${SDCARD}/usr/sbin/${dm}" || -x "${SDCARD}/usr/bin/${dm}" ]]; then
			printf '%s' "${dm}"
			return 0
		fi
	done
	return 1
}

# 把 DM 名字映射到真实 unit 名（Debian 12 及以前叫 gdm3.service，noble/trixie 是 gdm.service）
_desktop_dm__unit() {
	local dm="$1" unit
	case "${dm}" in
		gdm | gdm3)
			for unit in gdm3.service gdm.service; do
				if _desktop_dm__rootfs_unit "${unit}" >/dev/null; then
					printf '%s' "${unit}"
					return 0
				fi
			done
			;;
		lightdm)
			_desktop_dm__rootfs_unit lightdm.service >/dev/null && {
				printf '%s' lightdm.service
				return 0
			}
			;;
		sddm)
			_desktop_dm__rootfs_unit sddm.service >/dev/null && {
				printf '%s' sddm.service
				return 0
			}
			;;
	esac
	return 1
}

function post_armbian_repo_customize_image__desktop_dm() {
	if [[ "${DESKTOP_DM_FIX:-yes}" != "yes" ]]; then
		display_alert "Extension: ${EXTENSION}" "DESKTOP_DM_FIX!=yes，跳过显示管理器自愈" "info"
		return 0
	fi
	if [[ "${BUILD_DESKTOP:-no}" != "yes" ]]; then
		display_alert "Extension: ${EXTENSION}" "非桌面镜像，跳过（server 无图形目标）" "info"
		return 0
	fi

	local dm unit unit_path
	if ! dm="$(_desktop_dm__detect)"; then
		display_alert "Extension: ${EXTENSION}" \
			"rootfs 里没有 gdm3/gdm/lightdm/sddm —— 不补 display-manager.service（请确认桌面元包装全）" "warn"
		return 0
	fi
	if ! unit="$(_desktop_dm__unit "${dm}")"; then
		display_alert "Extension: ${EXTENSION}" \
			"检测到 ${dm}，但找不到它的 systemd unit（gdm3.service/gdm.service/...）—— 无法自愈，请检查桌面包装配" "warn"
		return 0
	fi
	unit_path="$(_desktop_dm__rootfs_unit "${unit}")"

	local changed=0
	local sysdir="${SDCARD}/etc/systemd/system"
	local dm_link="${sysdir}/display-manager.service"
	mkdir -p "${sysdir}"

	# ---- 1. display-manager.service（graphical.target 的 Wants 目标）----
	if [[ -L "${dm_link}" || -e "${dm_link}" ]]; then
		local cur
		cur="$(readlink "${dm_link}" 2>/dev/null || printf '(普通文件)')"
		display_alert "Extension: ${EXTENSION}" "display-manager.service 已存在 → ${cur}" "info"
	else
		# 优先交给 systemd 自己处理（会一并算 Alias / 依赖）；
		# `systemctl --root` 不需要 PID 1，正好适配 chroot。
		if command -v systemctl >/dev/null 2>&1 &&
			systemctl --root="${SDCARD}" enable "${unit}" >/dev/null 2>&1 &&
			[[ -L "${dm_link}" || -e "${dm_link}" ]]; then
			display_alert "Extension: ${EXTENSION}" \
				"已用 systemctl --root 建立 display-manager.service → ${unit}" "info"
		else
			# 兜底：手工按真实 unit 路径建（绝对路径，和 Debian 自带链接形式一致）
			ln -sfn "${unit_path}" "${dm_link}"
			display_alert "Extension: ${EXTENSION}" \
				"已手工建立 display-manager.service → ${unit_path}" "info"
		fi
		changed=1
	fi

	# ---- 2. graphical.target.wants（双保险：即使 Alias 解析异常也能拉起）----
	local wants="${sysdir}/graphical.target.wants"
	mkdir -p "${wants}"
	if [[ -L "${wants}/display-manager.service" || -e "${wants}/display-manager.service" ]]; then
		: # 已就位
	else
		ln -sfn ../display-manager.service "${wants}/display-manager.service"
		display_alert "Extension: ${EXTENSION}" "已补 graphical.target.wants/display-manager.service" "info"
		changed=1
	fi

	# ---- 3. default.target：只有指向 multi-user 这种明显错误时才改 ----
	if [[ "${DESKTOP_DM_FORCE_TARGET:-yes}" == "yes" ]]; then
		local dt="${sysdir}/default.target"
		local tgt=""
		[[ -L "${dt}" ]] && tgt="$(readlink "${dt}" 2>/dev/null || true)"
		case "${tgt}" in
			*multi-user.target)
				# 目标文件也可能在 /lib（老布局），别硬编码 /usr/lib
				local gt="/usr/lib/systemd/system/graphical.target"
				[[ -f "${SDCARD}${gt}" ]] || gt="/lib/systemd/system/graphical.target"
				ln -sfn "${gt}" "${dt}"
				display_alert "Extension: ${EXTENSION}" \
					"default.target 原本指向 ${tgt}（桌面镜像应为 graphical）→ 已改为 ${gt}" "warn"
				changed=1
				;;
		esac
	fi

	# ---- 4. 留一份现场可查的记录（不含任何凭据）----
	cat >"${SDCARD}/etc/desktop-dm.conf" <<-EOF
		# 由 desktop-dm 扩展写入（构建期）
		DM=${dm}
		UNIT=${unit}
		UNIT_PATH=${unit_path}
		DISPLAY_MANAGER_LINK=$(readlink "${dm_link}" 2>/dev/null || printf '(none)')
		FIXED=$([[ ${changed} -eq 1 ]] && printf yes || printf no)
	EOF
	chmod 644 "${SDCARD}/etc/desktop-dm.conf"

	if [[ ${changed} -eq 1 ]]; then
		display_alert "Extension: ${EXTENSION}" "显示管理器自愈完成（DM=${dm} unit=${unit}）" "info"
	else
		display_alert "Extension: ${EXTENSION}" "显示管理器配置本来就完整（DM=${dm}），未做改动" "info"
	fi
	return 0
}

#
# SPDX-License-Identifier: GPL-2.0
# Armbian build framework extension
#
# default-user —— 在**构建期**（chroot 内）确定性地创建默认普通用户，并可选配置
#                 显示管理器自动登录。面向「烧卡即用、首启即可登录」的定制镜像。
#
# 与 rk35xx-chinese-desktop.sh 的分工：
#   · 本扩展：用户/密码/附加组/免密 sudo/桌面自动登录，构建期落盘，不依赖首启时序；
#   · rk35xx-chinese-desktop.sh：中文 locale / 字体 / 输入法 / Chromium 中文化。
#     它的首启建用户脚本已改为「用户已存在则只同步密码」，不会与本扩展打架。
#
# 变量（来自 compile.sh 的 KEY=VALUE 参数，或板卡 build.env）：
#   DEFAULT_USER_NAME             用户名——**不设则本扩展整体跳过（零副作用）**
#   DEFAULT_USER_PASSWORD         用户密码（必填，字符集受限，见下）
#   DEFAULT_ROOT_PASSWORD         root 密码（可选，留空=不改）
#   DEFAULT_USER_GROUPS           附加组，逗号分隔（默认 sudo,adm,audio,video,plugdev,
#                                 netdev,render,input,dialout,cdrom）
#   DEFAULT_USER_SHELL            登录 shell（默认 /bin/bash）
#   DEFAULT_SUDO_NOPASSWD         yes=该用户 sudo 免密（默认 no）
#   DEFAULT_DESKTOP_AUTOLOGIN     yes=显示管理器自动登录（默认 no）
#   DEFAULT_DESKTOP_SESSION_TYPE  x11|wayland|auto（默认 auto；决定 gdm3 的 WaylandEnable）
#
# 钩子时序（已对照 armbian/build main 源码核实）：
#   post_family_tweaks                → lib/functions/rootfs/distro-agnostic.sh:459
#                                       装包之后、customize-image.sh 之前
#   post_armbian_repo_customize_image → lib/functions/rootfs/customize.sh:60
#                                       整条定制链最后一步
#   自动登录必须放在后者：rkmpp-mpv.sh 在 post_install_kernel_debs 阶段会把
#   gdm3 写成 WaylandEnable=false（X11 强制），Wayland 定制版需要反向覆盖它。
#
# 安全：密码只经 env 传入 chroot 脚本，不回显、不落日志；校验字符集白名单，
#       避免 shell 注入（CI 侧同样做一层校验，双保险）。
# =============================================================================

# 默认附加组（组不存在会自动跳过，不会因某发行版缺组而失败）
_default_user_groups() {
	printf '%s' "${DEFAULT_USER_GROUPS:-sudo,adm,audio,video,plugdev,netdev,render,input,dialout,cdrom}"
}

# 本扩展是否启用：不设用户名即整体跳过
_default_user_enabled() {
	[[ -n "${DEFAULT_USER_NAME:-}" ]]
}

# 输入校验：非法输入直接中止构建（比起交付一个「没建出用户」的镜像要好）
_default_user_validate() {
	local err=0

	if ! [[ "${DEFAULT_USER_NAME}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
		display_alert "DEFAULT_USER_NAME 非法" "'${DEFAULT_USER_NAME}'（要求 ^[a-z_][a-z0-9_-]{0,31}$）" "err"
		err=1
	fi
	if [[ "${DEFAULT_USER_NAME}" =~ ^(root|daemon|bin|sys|nobody|admin)$ ]]; then
		display_alert "DEFAULT_USER_NAME 不可用" "'${DEFAULT_USER_NAME}' 是系统保留名" "err"
		err=1
	fi
	if [[ -z "${DEFAULT_USER_PASSWORD:-}" ]]; then
		display_alert "DEFAULT_USER_PASSWORD 为空" "必须提供用户密码" "err"
		err=1
	elif ! [[ "${DEFAULT_USER_PASSWORD}" =~ ^[A-Za-z0-9._+#=:@%-]{4,64}$ ]]; then
		display_alert "DEFAULT_USER_PASSWORD 字符集受限" \
			"只允许 A-Z a-z 0-9 . _ + # = : @ % -（4~64 位）；含空格/引号/\$ 的密码会污染 compile.sh 参数，请改用上述字符" "err"
		err=1
	fi
	if [[ -n "${DEFAULT_ROOT_PASSWORD:-}" ]] \
		&& ! [[ "${DEFAULT_ROOT_PASSWORD}" =~ ^[A-Za-z0-9._+#=:@%-]{4,64}$ ]]; then
		display_alert "DEFAULT_ROOT_PASSWORD 字符集受限" "同用户密码规则" "err"
		err=1
	fi
	if [[ -n "${DEFAULT_USER_GROUPS:-}" ]] && ! [[ "${DEFAULT_USER_GROUPS}" =~ ^[A-Za-z0-9_,]*$ ]]; then
		display_alert "DEFAULT_USER_GROUPS 非法" "'${DEFAULT_USER_GROUPS}'（只允许字母数字下划线与逗号）" "err"
		err=1
	fi
	case "${DEFAULT_DESKTOP_SESSION_TYPE:-auto}" in
		x11 | wayland | auto) ;;
		*)
			display_alert "DEFAULT_DESKTOP_SESSION_TYPE 非法" \
				"'${DEFAULT_DESKTOP_SESSION_TYPE}'（只接受 x11 | wayland | auto）" "err"
			err=1
			;;
	esac

	[[ ${err} -eq 0 ]] || exit 1
}

function extension_prepare_config__default_user() {
	if ! _default_user_enabled; then
		display_alert "Extension: ${EXTENSION}" "DEFAULT_USER_NAME 未设置，跳过（不创建默认用户）" "info"
		return 0
	fi
	_default_user_validate
	display_alert "Extension: ${EXTENSION}" \
		"默认用户 ${DEFAULT_USER_NAME}（自动登录=${DEFAULT_DESKTOP_AUTOLOGIN:-no} 会话=${DEFAULT_DESKTOP_SESSION_TYPE:-auto} sudo免密=${DEFAULT_SUDO_NOPASSWD:-no}）" "info"
	return 0
}

# 把 chroot 执行器写进镜像 /tmp（用完即删，不残留）
_default_user_stage_script() {
	local dst="${SDCARD}/tmp/.armbian-default-user.sh"
	cat > "${dst}" <<'DEFAULT_USER_SETUP_EOF'
#!/bin/bash
# Armbian default-user 构建期执行器（由 common/extensions/default-user.sh 生成）
# 用法: DMODE=user|autologin bash /tmp/.armbian-default-user.sh
set -u

log() { echo "[default-user] $*"; }

DUSER="${DUSER:?missing DUSER}"
DMODE="${DMODE:-user}"

# ---------------------------------------------------------------- INI 写值
# 就地修改 ini 的某个 [section] 下的 key，保留文件里其它内容。
# gdm3 不支持 drop-in（只读 /etc/gdm3/custom.conf），必须原地改。
set_ini() {
	local f="$1" sec="$2" key="$3" val="$4"
	[ -f "$f" ] || : >"$f"
	awk -v sec="$sec" -v key="$key" -v val="$val" '
		BEGIN { insec = 0; seen = 0; done = 0 }
		/^[[:space:]]*\[/ {
			if (insec && !done) { print key "=" val; done = 1 }
			insec = ($0 ~ ("^[[:space:]]*\\[" sec "\\][[:space:]]*$"))
			if (insec) { seen = 1; done = 0 }
			print
			next
		}
		{
			# 段落内的第一个空行 = 段落内容的结尾，缺的键插在这里（比插到下一个
			# 段头之前更整洁，也避免把键写到文件的空行之后）
			if (insec && !done && $0 ~ /^[[:space:]]*$/) { print key "=" val; done = 1 }
			if (insec && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=")) {
				if (!done) { print key "=" val; done = 1 }
				next
			}
			print
		}
		END {
			if (!seen) { print ""; print "[" sec "]"; print key "=" val }
			else if (insec && !done) { print key "=" val }
		}
	' "$f" > "$f.tmp.defaultuser" && mv "$f.tmp.defaultuser" "$f"
}

# ------------------------------------------------------------ 1. 建用户
setup_user() {
	DGROUPS="${DGROUPS:-}"
	DSHELL="${DSHELL:-/bin/bash}"
	DNOPASSWD="${DNOPASSWD:-no}"
	[ -x "$DSHELL" ] || DSHELL=/bin/bash

	# 只保留 rootfs 里真实存在的组（不同发行版组名不一致，缺组不能导致 useradd 失败）
	glist=""
	for g in $(printf '%s' "$DGROUPS" | tr ',' ' '); do
		[ -n "$g" ] || continue
		if getent group "$g" >/dev/null 2>&1; then
			glist="${glist:+${glist},}${g}"
		fi
	done

	if id -u "$DUSER" >/dev/null 2>&1; then
		log "用户 $DUSER 已存在，更新 shell/组/密码"
		usermod -s "$DSHELL" "$DUSER" 2>/dev/null || true
		if [ -n "$glist" ]; then
			usermod -aG "$glist" "$DUSER" 2>/dev/null || true
		fi
	else
		log "创建用户 $DUSER（附加组: ${glist:-none}）"
		if [ -n "$glist" ]; then
			useradd -m -s "$DSHELL" -G "$glist" "$DUSER"
		else
			useradd -m -s "$DSHELL" "$DUSER"
		fi
	fi

	# 主组归属 + 家目录权限
	homedir="$(getent passwd "$DUSER" | cut -d: -f6)"
	homedir="${homedir:-/home/$DUSER}"
	mkdir -p "$homedir"
	main_group="$(id -gn "$DUSER" 2>/dev/null || echo "$DUSER")"
	chown -R "${DUSER}:${main_group}" "$homedir" 2>/dev/null || true
	chmod 755 "$homedir" 2>/dev/null || true

	# 密码（chpasswd 从 stdin 读，不进 ps/日志）
	if echo "${DUSER}:${DPASS}" | chpasswd 2>/dev/null; then
		log "用户密码已设置"
	else
		log "警告: 用户密码设置失败"
	fi
	if [ -n "${DPASS_ROOT:-}" ]; then
		if echo "root:${DPASS_ROOT}" | chpasswd 2>/dev/null; then
			log "root 密码已设置"
		else
			log "警告: root 密码设置失败"
		fi
	fi

	# sudo 免密（写完立刻语法校验，不合格就删掉，绝不留下坏 sudoers）
	if [ "$DNOPASSWD" = "yes" ] && [ -d /etc/sudoers.d ]; then
		sf="/etc/sudoers.d/90-${DUSER}"
		printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DUSER" >"$sf"
		chmod 440 "$sf"
		if command -v visudo >/dev/null 2>&1 && ! visudo -cf "$sf" >/dev/null 2>&1; then
			log "警告: sudoers 校验失败，已删除 $sf"
			rm -f "$sf"
		else
			log "已配置 sudo 免密"
		fi
	fi

	# 清掉 Armbian 首启向导标记：用户已存在，向导不该再跑
	rm -f /root/.not_logged_in_yet /root/.not_logged_in_yet~ 2>/dev/null || true
	rm -f /var/lib/armbian/firstrun 2>/dev/null || true
	log "user setup done"
}

# --------------------------------------------------------- 2. 自动登录
# 会话名：取 rootfs 里实际存在的 .desktop 文件名（DM 的 autologin-session 要它）
pick_session() {
	local prefer="$1" base f
	local order="/usr/share/xsessions /usr/share/wayland-sessions"
	[ "$prefer" = "wayland" ] && order="/usr/share/wayland-sessions /usr/share/xsessions"
	for base in $order; do
		[ -d "$base" ] || continue
		f="$(ls -1 "$base"/*.desktop 2>/dev/null | head -n1)"
		if [ -n "$f" ]; then
			basename "$f" .desktop
			return 0
		fi
	done
	return 1
}

setup_autologin() {
	DSESSION_TYPE="${DSESSION_TYPE:-auto}"
	if [ "$DSESSION_TYPE" = "auto" ]; then
		case "${DESKTOP_ENV:-}" in
			gnome | kde-plasma | budgie) DSESSION_TYPE=wayland ;;
			*) DSESSION_TYPE=x11 ;;
		esac
	fi

	sess="$(pick_session "$DSESSION_TYPE" 2>/dev/null || true)"
	dm=""
	for cand in lightdm gdm3 sddm; do
		if [ -x "/usr/sbin/$cand" ] || [ -x "/usr/bin/$cand" ]; then
			dm="$cand"
			break
		fi
	done

	if [ -z "$dm" ]; then
		log "未检测到 lightdm/gdm3/sddm（可能是 server 镜像），跳过自动登录"
		return 0
	fi
	log "显示管理器=${dm} 会话=${sess:-<默认>} 类型=${DSESSION_TYPE}"

	case "$dm" in
	lightdm)
		mkdir -p /etc/lightdm/lightdm.conf.d
		{
			echo '[Seat:*]'
			echo "autologin-user=${DUSER}"
			echo 'autologin-user-timeout=0'
			[ -n "$sess" ] && echo "autologin-session=${sess}"
		} >/etc/lightdm/lightdm.conf.d/50-armbian-autologin.conf
		# lightdm 要求自动登录用户在 nopasswdlogin 组（部分版本否则会回落到登录框）
		if getent group nopasswdlogin >/dev/null 2>&1; then
			usermod -aG nopasswdlogin "$DUSER" 2>/dev/null || true
		fi
		;;
	gdm3)
		mkdir -p /etc/gdm3
		set_ini /etc/gdm3/custom.conf daemon AutomaticLoginEnable true
		set_ini /etc/gdm3/custom.conf daemon AutomaticLogin "$DUSER"
		case "$DSESSION_TYPE" in
			x11) set_ini /etc/gdm3/custom.conf daemon WaylandEnable false ;;
			wayland) set_ini /etc/gdm3/custom.conf daemon WaylandEnable true ;;
		esac
		;;
	sddm)
		mkdir -p /etc/sddm.conf.d
		{
			echo '[Autologin]'
			echo "User=${DUSER}"
			[ -n "$sess" ] && echo "Session=${sess}"
			echo 'Relogin=false'
		} >/etc/sddm.conf.d/50-armbian-autologin.conf
		if [ "$DSESSION_TYPE" = "wayland" ]; then
			set_ini /etc/sddm.conf.d/50-armbian-autologin.conf General DisplayServer wayland
		fi
		;;
	esac

	# 记录一句可读的落地说明，方便现场排障
	{
		echo "# 由 default-user 扩展写入（构建期）"
		echo "DM=${dm}"
		echo "SESSION_TYPE=${DSESSION_TYPE}"
		echo "SESSION=${sess:-auto}"
	} >/etc/default-user.autologin
	log "autologin setup done"
}

case "$DMODE" in
user) setup_user ;;
autologin) setup_autologin ;;
*)
	log "未知 DMODE=$DMODE"
	exit 2
	;;
esac
exit 0
DEFAULT_USER_SETUP_EOF
	chmod 755 "${dst}"
}

function post_family_tweaks__default_user() {
	_default_user_enabled || return 0
	[[ "${BUILD_MINIMAL:-no}" == "yes" ]] && {
		display_alert "Extension: ${EXTENSION}" "minimal 镜像跳过默认用户" "info"
		return 0
	}

	_default_user_stage_script

	display_alert "Extension: ${EXTENSION}" "在 chroot 内创建默认用户 ${DEFAULT_USER_NAME}" "info"
	# 变量全部经 env 传入（已白名单校验，无空格/引号），不做 shell 拼接
	if ! chroot_sdcard "env \
		DMODE=user \
		DUSER='${DEFAULT_USER_NAME}' \
		DPASS='${DEFAULT_USER_PASSWORD}' \
		DPASS_ROOT='${DEFAULT_ROOT_PASSWORD:-}' \
		DGROUPS='$(_default_user_groups)' \
		DSHELL='${DEFAULT_USER_SHELL:-/bin/bash}' \
		DNOPASSWD='${DEFAULT_SUDO_NOPASSWD:-no}' \
		bash /tmp/.armbian-default-user.sh"; then
		display_alert "Extension: ${EXTENSION}" "默认用户创建失败（chroot 返回非零），镜像内可能无 ${DEFAULT_USER_NAME}" "err"
		return 1
	fi

	# 留下只读标记（**不含密码**），供体检脚本/现场核对
	cat > "${SDCARD}/etc/default-user.conf" <<-EOF
		# 由 default-user 扩展写入（构建期）
		USER=${DEFAULT_USER_NAME}
		SHELL=${DEFAULT_USER_SHELL:-/bin/bash}
		GROUPS=$(_default_user_groups)
		SUDO_NOPASSWD=${DEFAULT_SUDO_NOPASSWD:-no}
		AUTOLOGIN=${DEFAULT_DESKTOP_AUTOLOGIN:-no}
		SESSION_TYPE=${DEFAULT_DESKTOP_SESSION_TYPE:-auto}
	EOF
	chmod 644 "${SDCARD}/etc/default-user.conf"
	return 0
}

function post_armbian_repo_customize_image__default_user() {
	_default_user_enabled || return 0
	[[ "${BUILD_MINIMAL:-no}" == "yes" ]] && return 0
	[[ "${DEFAULT_DESKTOP_AUTOLOGIN:-no}" == "yes" ]] || return 0
	[[ "${BUILD_DESKTOP:-no}" == "yes" ]] || {
		display_alert "Extension: ${EXTENSION}" "非桌面镜像，不配置自动登录" "info"
		return 0
	}

	# 执行器在上一个钩子已写入；这里若不存在（例如镜像重建流程差异）就补写
	[[ -f "${SDCARD}/tmp/.armbian-default-user.sh" ]] || _default_user_stage_script

	display_alert "Extension: ${EXTENSION}" "配置显示管理器自动登录 ${DEFAULT_USER_NAME}" "info"
	chroot_sdcard "env \
		DMODE=autologin \
		DUSER='${DEFAULT_USER_NAME}' \
		DESKTOP_ENV='${DESKTOP_ENVIRONMENT:-}' \
		DSESSION_TYPE='${DEFAULT_DESKTOP_SESSION_TYPE:-auto}' \
		bash /tmp/.armbian-default-user.sh" \
		|| display_alert "Extension: ${EXTENSION}" "自动登录配置返回非零（不影响镜像构建，但可能仍需手动登录）" "warn"

	# 执行器一次性使用
	rm -f "${SDCARD}/tmp/.armbian-default-user.sh"
	return 0
}

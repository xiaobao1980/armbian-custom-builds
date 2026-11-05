#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
# Armbian build framework extension
#
# ntp-boot-sync —— 出厂即带「每次开机强制 NTP 校时」
#
# =============================================================================
#  为什么需要这个扩展
# -----------------------------------------------------------------------------
#  RK35xx SBC 普遍没有 RTC 电池（或电池失效），每次上电系统时间回到构建日期/
#  epoch，导致 TLS 证书校验失败、日志时间错乱、录像/展厅素材时间戳错误。
#  Armbian 默认 chrony / systemd-timesyncd 会"渐进"校准，但：
#    · chrony 只有启动初期允许 makestep，且要等它与源收敛；
#    · timesyncd 在开机时若网络未就绪，本次启动就不再主动跳步；
#    · 原中文扩展的首启脚本只有 `ntpdate -u cn.pool.ntp.org` 一行，
#      只在**首次启动**跑一次，且 trixie/bookworm 常不装 ntpdate → 静默 no-op。
#  用户要求「每次开机 NTP 时间同步」，因此做成一个系统级 oneshot：
#  每次 boot 等网络就绪后，显式触发一次强制跳步校时，并把结果写进 journal。
#
#  做法：在 rootfs 里装 bash 脚本 + systemd unit，enable 到
#        multi-user.target.wants（chroot 里没有 PID1，不能用 systemctl enable）。
#        chrony 优先（Armbian 桌面默认），不存在则退回 systemd-timesyncd；
#        两者都没有时只记录告警，绝不返回非 0 —— 离线/展厅插网线前的开机
#        不能因为校时被阻断。有 RTC 的板会顺手 hwclock -w 写回硬件时钟。
#
#  可移植性：只依赖 systemd + timedatectl +（chrony 或 systemd-timesyncd），
#      与 SoC/板型/内核分支、X11/Wayland、是否启用中文扩展、是否自动登录无关；
#      Debian bookworm/trixie、Ubuntu jammy/noble 均适用。
#      不打开任何硬件节点，非 Armbian 的 systemd 发行版也能直接复用脚本。
#
#  可选配置 /etc/rk-ntp-boot-sync.conf：
#      NTP_HOST=ntp.aliyun.com   # 仅用于网络就绪探测（不是 NTP 源配置）
#      WAIT_NET=40               # 等待网络就绪上限（秒）
#      WAIT_SYNC=60              # 等待同步收敛上限（秒）
# =============================================================================

function post_armbian_repo_customize_image__ntp_boot_sync() {
	if [[ -z "${SDCARD:-}" || ! -d "${SDCARD}" ]]; then
		display_alert "Extension: ${EXTENSION}" "SDCARD 不可用，跳过开机 NTP 校时" "warn"
		return 0
	fi

	local bindir="${SDCARD}/usr/local/sbin"
	local unitdir="${SDCARD}/etc/systemd/system"
	local wantsdir="${unitdir}/multi-user.target.wants"
	mkdir -p "${bindir}" "${unitdir}" "${wantsdir}"

	cat >"${bindir}/rk-ntp-boot-sync.sh" <<'NTPSYNCSCRIPT'
#!/usr/bin/env bash
# rk-ntp-boot-sync —— 每次开机强制 NTP 校时（由 rk-ntp-boot-sync.service 调用）
# 离线 / 无 NTP 客户端时只记日志并成功退出，绝不阻断开机。
set -u
CONF=/etc/rk-ntp-boot-sync.conf
[ -r "$CONF" ] && . "$CONF"
NTP_HOST=${NTP_HOST:-ntp.aliyun.com}
WAIT_NET=${WAIT_NET:-40}
WAIT_SYNC=${WAIT_SYNC:-60}

log() {
	printf 'rk-ntp-boot-sync: %s\n' "$*"
	logger -t rk-ntp-boot-sync -- "$*" 2>/dev/null || true
}

BEFORE=$(date '+%Y-%m-%d %H:%M:%S %z')
log "开机校时开始，系统时间 ${BEFORE}"

# 1) 等网络就绪：DNS 可解析 + 有默认路由。离线场景最多等 WAIT_NET 秒后跳过。
ready=no
for _ in $(seq 1 $((WAIT_NET / 2 + 1))); do
	if getent ahosts "$NTP_HOST" >/dev/null 2>&1 &&
		{ ip route 2>/dev/null | grep -q '^default' ||
		  ip -6 route 2>/dev/null | grep -q '^default'; }; then
		ready=yes
		break
	fi
	sleep 2
done
if [ "$ready" != yes ]; then
	log "网络未就绪（DNS=${NTP_HOST} 或默认路由不可用），跳过本次校时；chrony/timesyncd 联网后仍会自行同步"
	exit 0
fi

# 2) 确保 NTP 客户端被 systemd 启用（chrony 与 timesyncd 互斥，timedatectl 自行选择）
timedatectl set-ntp true >/dev/null 2>&1 || true

synced=no
route=none

# 3) chrony 路线（Armbian 桌面镜像默认装 chrony）
if [ -d /etc/chrony ] ||
	systemctl is-active --quiet chrony.service 2>/dev/null ||
	systemctl is-active --quiet chronyd.service 2>/dev/null; then
	route=chrony
	svc=chrony.service
	systemctl is-active --quiet chronyd.service 2>/dev/null && svc=chronyd.service
	systemctl restart "$svc" >/dev/null 2>&1 || true
	# 显式强制跳步：chrony 默认只在前 3 次更新允许 makestep，重启后重新计数
	timeout 10 chronyc -a makestep >/dev/null 2>&1 || true
	for _ in $(seq 1 $((WAIT_SYNC / 2 + 1))); do
		trk=$(timeout 5 chronyc -n tracking 2>/dev/null || true)
		if printf '%s\n' "$trk" | grep -q '^Reference ID' &&
			! printf '%s\n' "$trk" | grep -q '^Reference ID.*00000000'; then
			synced=yes
			break
		fi
		sleep 2
	done
# 4) systemd-timesyncd 路线（无 chrony 的发行版）
elif systemctl cat systemd-timesyncd.service >/dev/null 2>&1; then
	route=systemd-timesyncd
	systemctl restart systemd-timesyncd.service >/dev/null 2>&1 || true
	for _ in $(seq 1 $((WAIT_SYNC / 2 + 1))); do
		if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then
			synced=yes
			break
		fi
		sleep 2
	done
else
	log "未发现 chrony / systemd-timesyncd，无法校时（请安装其中之一）"
	exit 0
fi

AFTER=$(date '+%Y-%m-%d %H:%M:%S %z')
if [ "$synced" = yes ]; then
	log "校时成功（${route}）：${BEFORE} -> ${AFTER}"
	# 有 RTC 的板写回硬件时钟；无 RTC / 只读时钟会失败，忽略即可
	hwclock -w >/dev/null 2>&1 || true
else
	log "本次未确认同步收敛（${route}，NTP 源不可达或尚未收敛）：${BEFORE} -> ${AFTER}；后台服务会继续尝试"
fi
exit 0
NTPSYNCSCRIPT
	chmod 755 "${bindir}/rk-ntp-boot-sync.sh"

	cat >"${unitdir}/rk-ntp-boot-sync.service" <<'NTPSYNCUNIT'
[Unit]
Description=Force NTP time synchronization at every boot (RK SBC without RTC battery)
Documentation=https://github.com/xiaobao1980/armbian-custom-builds
Wants=network-online.target
After=network-online.target systemd-timesyncd.service chrony.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/rk-ntp-boot-sync.sh
TimeoutStartSec=150
Nice=5

[Install]
WantedBy=multi-user.target
NTPSYNCUNIT
	chmod 644 "${unitdir}/rk-ntp-boot-sync.service"

	# chroot 里没有 PID 1，systemctl enable 不可用 → 直接建 wants 软链
	ln -sfn "/etc/systemd/system/rk-ntp-boot-sync.service" \
		"${wantsdir}/rk-ntp-boot-sync.service"

	# 可选配置：默认全部注释，脚本用内置默认值
	if [[ ! -f "${SDCARD}/etc/rk-ntp-boot-sync.conf" ]]; then
		cat >"${SDCARD}/etc/rk-ntp-boot-sync.conf" <<'NTPSYNCCONF'
# rk-ntp-boot-sync 可选配置（留空即用默认值）
# NTP_HOST=ntp.aliyun.com   # 仅用于网络就绪探测，不是 NTP 源配置
# WAIT_NET=40               # 等待网络就绪上限（秒）
# WAIT_SYNC=60              # 等待同步收敛上限（秒）
# 中国 NTP 源由 rk35xx-chinese-desktop 扩展写入 chrony/timesyncd 配置；
# 未启用中文扩展时，建议在镜像里自行配置 NTP/FallbackNTP。
NTPSYNCCONF
		chmod 644 "${SDCARD}/etc/rk-ntp-boot-sync.conf"
	fi

	# 落地终验：脚本可执行、unit 存在、enable 链接指向正确、语法通过
	if [[ -x "${bindir}/rk-ntp-boot-sync.sh" ]] &&
		[[ -f "${unitdir}/rk-ntp-boot-sync.service" ]] &&
		[[ -L "${wantsdir}/rk-ntp-boot-sync.service" ]] &&
		bash -n "${bindir}/rk-ntp-boot-sync.sh"; then
		display_alert "Extension: ${EXTENSION}" "开机 NTP 校时已装并 enable（每次启动强制校时）" "info"
	else
		display_alert "Extension: ${EXTENSION}" "开机 NTP 校时落地校验失败" "err"
		return 1
	fi
	return 0
}

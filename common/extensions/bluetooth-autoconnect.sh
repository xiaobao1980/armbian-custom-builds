#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
# Armbian build framework extension
#
# bluetooth-autoconnect —— 出厂即带「蓝牙音频设备自动回连」守护
#
# =============================================================================
#  为什么需要这个扩展（188 板 neardi-lz200 Wayland r12 实测，2026-11-05）
# -----------------------------------------------------------------------------
#  症状：音箱配对/连接/播放都正常，但**冷启动后不会自动连回来** —— 开机 180s
#        全程 `Connected: no`、无 bluez sink、默认 sink 回落板载 es8388；
#        `journalctl -b -u bluetooth` 里连一次自动连接尝试都没有。
#  根因：BlueZ 只对 HID 类设备做 auto-connect；A2DP/HFP 音频设备必须由客户端
#        主动发起 `bluetoothctl connect`。GNOME 蓝牙面板也不会替你连。
#        这是 BlueZ 的既定行为，不是驱动/固件故障，也不是 Trusted 标志失效。
#  第二个坑（决定必须"常驻重试"而不是 oneshot）：开机早期 WirePlumber 还没
#        注册 A2DP profile，bluetoothd 会报
#        `a2dp-sink/source profile connect failed ... Protocol not available`；
#        本板实测开机 09:55:13 报该错，09:55:47（守护第 2 轮）才连上。
#        所以 systemd oneshot / 单次 connect 必然失败。
#
#  做法：在 rootfs 里装一个 bash 守护 + systemd service，enable 到
#        multi-user.target.wants（chroot 里没有 PID1，不能用 systemctl enable）。
#        守护每 20s 枚举 Trusted+Paired 设备，未连接则 connect（12s 超时），
#        成功写 logger；常驻以便音箱任何时候开机/从别的主机会释放后都能接上。
#        没有配对设备时循环空转，开销可忽略；没有 bluetooth.service 时 unit
#        因 Requires 不成立而不启动，非蓝牙板也安全。
#
#  板上验证（188，trixie / BlueZ 5.82 / PipeWire）：
#    - 手动启用服务后 1s 自动回连，sink 与默认 sink 自动切到蓝牙；
#    - 冷启动 09:55:03 → 服务 09:55:12 → 09:55:47 `已自动回连`，
#      开机后 35s 起 8/8 采样全 Connected: yes；
#    - 手动 disconnect → t=3s no → t=28s yes（守护自愈）。
#
#  可移植性：脚本对 BlueZ 版本做了兜底（`devices Paired` 不可用时退回全版本
#      通用的 `devices`，由循环里的 Paired/Trusted 检查过滤），因此
#      noble / jammy / bookworm / trixie 都适用。守护只走 BlueZ D-Bus，
#      不打开任何硬件节点，与 SoC、板型、蓝牙芯片、X11/Wayland 会话、
#      是否自动登录均无关；唯一硬要求是 systemd + bluez。
# =============================================================================

function post_armbian_repo_customize_image__bluetooth_autoconnect() {
	if [[ -z "${SDCARD:-}" || ! -d "${SDCARD}" ]]; then
		display_alert "Extension: ${EXTENSION}" "SDCARD 不可用，跳过蓝牙自动回连" "warn"
		return 0
	fi

	local bindir="${SDCARD}/usr/local/bin"
	local unitdir="${SDCARD}/etc/systemd/system"
	local wantsdir="${unitdir}/multi-user.target.wants"
	mkdir -p "${bindir}" "${unitdir}" "${wantsdir}"

	cat >"${bindir}/rk-bluetooth-autoconnect.sh" <<'BTAUTOCONNECT'
#!/usr/bin/env bash
# rk-bluetooth-autoconnect —— 自动回连已配对且授信的蓝牙音频设备
#
# 背景：BlueZ 对 A2DP/HFP 音频设备不会主动回连（只有 HID 类有 auto-connect），
#       开机后必须由客户端发起 bluetoothctl connect。GNOME 面板也不会自动连。
# 策略：每 INTERVAL 秒枚举一次 Trusted+Paired 设备，未连接则尝试 connect；
#       常驻以便音箱任何时候开机都能自动接上（展厅/大屏场景）。
# 可选配置 /etc/rk-bluetooth-autoconnect.conf：
#       MACS="AA:BB:CC:DD:EE:FF"   # 限定设备，空=全部授信配对设备
#       INTERVAL=20                # 轮询间隔（秒）
#       CONNECT_TIMEOUT=12         # 单次 connect 超时（秒）
set -u
CONF=/etc/rk-bluetooth-autoconnect.conf
[ -r "$CONF" ] && . "$CONF"
INTERVAL=${INTERVAL:-20}
CONNECT_TIMEOUT=${CONNECT_TIMEOUT:-12}
log() { logger -t rk-bt-autoconnect -- "$*"; }

# 等 bluetoothd 就绪（最多 60s）
for _ in $(seq 1 30); do
    bluetoothctl show 2>/dev/null | grep -q 'Powered: yes' && break
    sleep 2
done
log "守护启动 interval=${INTERVAL}s timeout=${CONNECT_TIMEOUT}s"

while :; do
    if [ -n "${MACS:-}" ]; then
        DEVS="$MACS"
    else
        # `devices Paired` 过滤参数是较新 BlueZ 才有；老版本返回空/报错时
        # 退回全版本通用的 `devices`（循环里的 Paired+Trusted 检查会过滤）。
        # 这样同一份脚本在 noble / jammy / bookworm / trixie 都能用。
        DEVS=$(bluetoothctl devices Paired 2>/dev/null | awk '/^Device /{print $2}')
        [ -z "$DEVS" ] && DEVS=$(bluetoothctl devices 2>/dev/null | awk '/^Device /{print $2}')
    fi
    for mac in $DEVS; do
        st=$(bluetoothctl info "$mac" 2>/dev/null)
        printf '%s\n' "$st" | grep -q 'Paired: yes' || continue
        printf '%s\n' "$st" | grep -q 'Trusted: yes' || continue
        printf '%s\n' "$st" | grep -q 'Connected: yes' && continue
        out=$(timeout "$CONNECT_TIMEOUT" bluetoothctl connect "$mac" 2>&1)
        if printf '%s\n' "$out" | grep -aq 'Connection successful\|Connected: yes'; then
            log "已自动回连 $mac ($(printf '%s\n' "$st" | grep -a 'Name:' | head -1 | sed 's/^[[:space:]]*Name: //'))"
        fi
    done
    sleep "$INTERVAL"
done
BTAUTOCONNECT
	chmod 755 "${bindir}/rk-bluetooth-autoconnect.sh"

	cat >"${unitdir}/rk-bluetooth-autoconnect.service" <<'BTAUTOUNIT'
[Unit]
Description=Auto-reconnect trusted paired Bluetooth audio devices
Documentation=https://github.com/xiaobao1980/armbian-custom-builds
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=simple
ExecStart=/usr/local/bin/rk-bluetooth-autoconnect.sh
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
BTAUTOUNIT
	chmod 644 "${unitdir}/rk-bluetooth-autoconnect.service"

	# chroot 里没有 PID 1，systemctl enable 不可用 → 直接建 wants 软链
	ln -sfn "/etc/systemd/system/rk-bluetooth-autoconnect.service" \
		"${wantsdir}/rk-bluetooth-autoconnect.service"

	# 可选配置模板：默认注释掉，守护用内置默认值
	if [[ ! -f "${SDCARD}/etc/rk-bluetooth-autoconnect.conf" ]]; then
		cat >"${SDCARD}/etc/rk-bluetooth-autoconnect.conf" <<'BTAUTOCONF'
# rk-bluetooth-autoconnect 可选配置（留空即用默认值）
# MACS="AA:BB:CC:DD:EE:FF"   # 只自动连指定设备；不填=所有授信(Trusted)配对设备
# INTERVAL=20                # 轮询间隔（秒）
# CONNECT_TIMEOUT=12         # 单次 connect 超时（秒）
BTAUTOCONF
		chmod 644 "${SDCARD}/etc/rk-bluetooth-autoconnect.conf"
	fi

	# 落地终验：脚本可执行、unit 存在、enable 链接指向正确
	if [[ -x "${bindir}/rk-bluetooth-autoconnect.sh" ]] &&
		[[ -f "${unitdir}/rk-bluetooth-autoconnect.service" ]] &&
		[[ -L "${wantsdir}/rk-bluetooth-autoconnect.service" ]] &&
		bash -n "${bindir}/rk-bluetooth-autoconnect.sh"; then
		display_alert "Extension: ${EXTENSION}" "蓝牙自动回连守护已装并 enable（开机自启）" "info"
	else
		display_alert "Extension: ${EXTENSION}" "蓝牙自动回连守护落地校验失败" "err"
		return 1
	fi
	return 0
}

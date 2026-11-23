#!/bin/sh
# LZ120 RTL8852BS 蓝牙拉起与保活（UART1 = /dev/ttyS1）
#
# 为什么必须这么干（缺工具 = 永远没有 hci0）：
#   内核 hci_uart 里没有 Realtek 的 UART 协议（这板注册的只有
#   H4/BCSP/3WIRE/Intel/Broadcom/QCA/AG6XX/AIC），bluez 的 hciattach 没有 realtek
#   类型、bookworm 的 btattach 也不认；直接拿 H4 attach 上去只会
#   "RX bytes:0 / Bluetooth: hci0: command 0x1003 tx timeout（-110）"——芯片在等
#   Realtek 自己的 patchram 下载流程。2026-11-24 板上实测：纯 H4 attach 零回包，
#   换成 rtk_hciattach 立刻 hci0 UP RUNNING、BD 34:7D:E4:BF:F5:37（与 wlan0 连号）。
#   命令行照抄厂商 external/rkwifibt/scripts/wifibt-init.sh 的 start_bt_rtk_uart()：
#     rtk_hciattach -n -s 115200 <tty> rtk_h5
#   固件由 armbian-firmware 提供，工具读固定路径 /lib/firmware/rtlbt/rtl8852bs_{fw,config}。
#
# 为什么要常驻保活、而不是一次性 attach（2026-11-24 板上实测的两条死法）：
#   1) patchram 是下载到芯片 RAM 的，**掉一次电就没了**。UI 里关蓝牙再开、
#      rfkill block/unblock、suspend 回来，走的都是 bt_rfkill 的断电重上电；
#      此时 hci0 这个名字还在（tty 没关、设备没注销），但任何 HCI 命令都不回：
#        hciconfig hci0 up            → Can't init device hci0: Connection timed out (110)
#        bluetoothctl power on        → org.bluez.Error.Failed / Powered 仍为 no
#        bluetoothctl connect <音箱>  → org.bluez.Error.NotReady br-connection-adapter-not-powered
#      只有把 attach 整个重来才救得回来（实测：杀 attach → hci0 消失 → 断电重上电
#      → 重新 attach → power on succeeded → Connection successful）。
#      一次性 attach 的服务在这里完全不动作：进程活着（Restart=on-failure 不会触发）、
#      hci0 又确实存在，所以「开机能连、UI 关开一次之后永久连不上」是必然结果。
#   2) attach 之前必须做一次断电重上电（rfkill block → 等 2s → unblock），否则上一轮
#      半途失败会把芯片留在「等 H4」状态，本轮 H5 握手连打三行
#      "OP_H5_SYNC Transmission timeout" → "Retransmission exhausts" 退出。厂商脚本里
#      对应的就是 bt_reset 那一步。
#
# 于是本脚本 = 拉起 + 看门狗：
#   · 开机：等 ttyS1 → modprobe hci_uart → rfkill unblock（bt_default 出厂就是 blocked，
#     桌面版有人解、无头镜像没人解）→ 「杀残留 → 断电重上电 → attach → power on」；
#   · 之后每 CHECK_INTERVAL 秒复查三件事：用户正关着（soft-block，一律不动，不抢开关）、
#     刚从 block 回到 unblock（芯片掉过电，重来一遍）、hci0 没了（重来一遍，失败退避
#     FAIL_SLEEP 秒）。hci0 还在就什么都不做。
#   · 重 attach 成功后自己 power on：新注册的适配器 BlueZ 一律算未上电，而回连守护要等
#     Powered: yes 才动手。
#   自动回连已配对音箱不是本脚本的职责，由 rk-bluetooth-autoconnect 守护负责
#   （common/extensions/bluetooth-autoconnect.sh，本板 build.env 已启用）。

BT_TTY="${LZ120_BT_TTY:-/dev/ttyS1}"
BT_SPEED="${LZ120_BT_SPEED:-115200}"
BT_PROTO="${LZ120_BT_PROTO:-rtk_h5}"
BT_WAIT="${LZ120_BT_WAIT:-30}"
CHECK_INTERVAL="${LZ120_BT_CHECK:-10}"
FAIL_SLEEP="${LZ120_BT_FAIL_SLEEP:-30}"
TOOL=/usr/local/sbin/rtk_hciattach
BT_PID=''

log() { logger -t lz120-bt -- "$*"; echo "lz120-bt: $*"; }

# 只认平台胶水那颗 rfkill（type=bluetooth、name=bt_default）：它在没有 hci0 时也在，
# 且 UI 的蓝牙开关最终就是翻它的 soft 位。索引号每次开机会变，所以按属性找、不按号找。
is_blocked() {
	local d
	for d in /sys/class/rfkill/rfkill*; do
		[ "$(cat "$d/type" 2>/dev/null)" = "bluetooth" ] || continue
		[ "$(cat "$d/name" 2>/dev/null)" = "bt_default" ] || continue
		[ "$(cat "$d/soft" 2>/dev/null)" = "1" ] && return 0
		return 1
	done
	return 1
}

# 清掉所有 rtk_hciattach（不只本脚本的子孙）：残留一枚就会一直占着 /dev/ttyS1，
# 新的 attach 立刻失败退出，看门狗于是每轮空转重 attach（2026-11-24 板上真踩过，
# 那枚残留是手工调试留下的孤儿）。不依赖 psmisc 的 killall/procps 的 pkill：
# /proc/<pid>/comm 就是可执行名，逐枚比对即可，bookworm/noble/trixie 都在。
kill_all_attach() {
	local c p
	for c in /proc/[0-9]*/comm; do
		[ "$(cat "$c" 2>/dev/null)" = "rtk_hciattach" ] || continue
		p="$(basename "$(dirname "$c")")"
		kill -9 "$p" 2>/dev/null || true
	done
	BT_PID=''
}

# 一次完整的重新拉起：杀干净（tty 一关 hci0 就注销）→ 断电重上电 → attach → 等 hci0。
# 成功返回 0，失败返回 1（调用方据此退避，别每 10s 反复给芯片断电）。
reattach() {
	kill_all_attach
	sleep 1
	rfkill block bluetooth 2>/dev/null || true
	sleep 2
	rfkill unblock bluetooth 2>/dev/null || true
	sleep 1
	"$TOOL" -n -s "$BT_SPEED" "$BT_TTY" "$BT_PROTO" &
	BT_PID=$!
	i=0
	while [ ! -e /sys/class/bluetooth/hci0 ] && [ "$i" -lt 15 ]; do
		sleep 1
		i=$((i + 1))
	done
	[ -e /sys/class/bluetooth/hci0 ] || {
		log "attach 后 15s 内没等到 hci0"
		return 1
	}
	log "attach 完成，hci0 就位（pid=$BT_PID）"

	# 重新注册的适配器 BlueZ 一律按「未上电」处理（本板实测：重 attach 之后 Powered
	# 恒为 no，除非有人在桌面上点一下开关）。而 rk-bluetooth-autoconnect 守护要等
	# Powered: yes 才动手 → 「attach 成功但音箱不回连」。所以 attach 成功后自己上电，
	# 试 3 次（芯片刚注册时 mgmt 会短暂回 Failed/Busy）。用户自己 CLI power off 不走
	# 这条路径（那时 hci0 还在、也不会触发重 attach），不跟用户抢开关。
	i=0
	while [ "$i" -lt 3 ]; do
		bluetoothctl show 2>/dev/null | grep -q 'Powered: yes' && break
		timeout 10 bluetoothctl power on >/dev/null 2>&1
		i=$((i + 1))
		sleep 3
	done
	if bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; then
		log "适配器已上电"
	else
		log "3 次 power on 仍未上电，交给桌面/回连守护下一轮再试"
	fi
	return 0
}

[ -x "$TOOL" ] || { log "缺少 $TOOL"; exit 1; }

# ttyS1 由 uart 驱动晚于本服务创建也正常，等一会儿再判失败
i=0
while [ ! -e "$BT_TTY" ] && [ "$i" -lt "$BT_WAIT" ]; do
	sleep 1
	i=$((i + 1))
done
[ -e "$BT_TTY" ] || { log "等不到 $BT_TTY，退出"; exit 1; }

# hci_uart 在本内核里是模块（=m），没它就没有 UART HCI 传输层
modprobe hci_uart 2>/dev/null || true

# 开机一律先解阻断再拉起：bt_default 这颗 rfkill 出厂态就是 soft-blocked（2026-11-24
# 重启实测：03:36:20 守护起来看到的是「蓝牙被 soft-block」，直到 03:36:30 桌面把它打开
# 才有第一轮 attach）。桌面会自己解，所以只有桌面时会顺；**无头镜像没有任何人来解**，
# 不在这里 unblock 就永远没有 hci0。与厂商 wifibt-init 的开机行为一致。
# 桌面上用户自己存了「蓝牙关」的话，gnome-bluetooth 随后会再 block 一次，那时下面的
# 循环认这个 soft-block 并停手，不跟他抢。
rfkill unblock bluetooth 2>/dev/null || true
reattach
reattach_done=yes

while :; do
	sleep "$CHECK_INTERVAL"

	# soft-block 期间芯片是断电的：什么都不做，只记住「现在关着」
	if is_blocked; then
		[ "$reattach_done" = yes ] && log "蓝牙关闭（rfkill soft-block），暂停保活"
		reattach_done=no
		continue
	fi

	# 从 soft-block 回到开：芯片断电重上电过、RAM 里的 patchram 已经没了，
	# hci0 名字却还挂着 —— 这一条边沿就是「UI 关开一次之后再也连不上」的现场。
	if [ "$reattach_done" != yes ]; then
		log "蓝牙重新打开，重做 attach（断电重上电后 patchram 需重新下载）"
		reattach || sleep "$FAIL_SLEEP"
		reattach_done=yes
		continue
	fi

	# hci0 还在 = 芯片没被动过，什么都不做
	[ -e /sys/class/bluetooth/hci0 ] && continue

	# hci0 没了（attach 进程退出、或被别的东西拆掉）→ 重来。
	# ⚠️ 判活只看 hci0 存在与否，不看 attach 进程还在不在：本板除「断电重上电」外没有
	# 别的「hci0 活着但芯片不响应」的失效模式，而拿进程当条件会被一枚抢不到 tty 的短命
	# 子进程带进每 10 秒给芯片断电一次的死循环（2026-11-24 真踩过，元凶是调试留下的孤儿
	# rtk_hciattach）。残留由 kill_all_attach 统一清，失败再退避 FAIL_SLEEP 秒。
	log "hci0 不在，重做 attach"
	reattach || sleep "$FAIL_SLEEP"
done

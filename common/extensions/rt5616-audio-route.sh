#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
# Armbian build framework extension
#
# rt5616-audio-route —— 打开 RT5616 codec 的耳机（HPO）通路
#
# =============================================================================
#  为什么需要这个扩展
# -----------------------------------------------------------------------------
#  RT5616 复位后 HPO（耳机输出驱动）的**输入源开关全是断的**：ALSA 只做最小初始化，
#  不会替你选 DAC→HPO 这条路。结果是最迷惑的那种故障——声卡注册正常、应用播放无报错、
#  PipeWire 的 Sink 甚至进入 running 状态，但 3.5mm 一口完全无声。
#  2026-11-25 在 cm3588-nas（192.168.50.103，vendor 6.1 / Ubuntu 26.04）实测到位：
#      出厂态  HPO MIX DAC1=off  HPO MIX HPVOL=on  HPVOL Playback Switch=off,off
#              → HPO 两条可能的输入都不通（选中的 HPVOL 那级自己没供电）→ 无声
#      pw-play /usr/share/sounds/alsa/Front_*.wav 直灌该 Sink，Sink state=running，
#              依旧一声都听不到 → 软件栈三层全绿也不出声，问题在 codec 内部路由
#      打开开关后  左右声道立刻正常（用户在场逐声确认）
#
#  寄存器语义（板上 regmap /sys/kernel/debug/regmap/7-001b/registers 实测）：
#      0x045 bit13 = HPO MIX DAC1、bit14 = HPO MIX HPVOL，**低有效**（开 = 清 0）。
#      两开关全 off 读回 0x6000，只开 DAC1 = 0x2000，只开 HPVOL = 0x4000，全开 = 0x0000。
#      0x002 随 HPVOL 级开关在 0x4848 ↔ 0x0808 之间变，那级是 HP 驱动供电位。
#      别照这份位定义去直接写寄存器：ALSA 控件名是稳定的，寄存器位是随驱动版本变的。
#      本扩展只走 amixer 控件名，且在动手前逐个探测控件存在性（缺控件的固件跳过，不误报成功）。
#
#  为什么是「开机服务」而不是镜像里存一份 asound.state：
#      alsa-restore 存的是**上次关机时的运行态**，把这套开关写进存档等于把一次实验固化下来，
#      换内核/换控件名就悄悄失效（lz120 上已经踩过它把 amixer 实验留下的坑）。
#      服务在 sound.target 之后、按卡名现算卡号重放一遍开关，才是可移植的写法。
#      ⚠️ 服务的 After=alsa-restore.service 是刻意的：它先恢复用户音量，我们再补路由，
#         顺序反过来会被 alsa-restore 把开关覆盖回死状态。
#
#  为什么单独一个扩展、不搭车 audio-friendly-names：
#      那个扩展只管「面板上显示什么名字」，桌面/无头走两条完全不同的分支；
#      通路初始化两条镜像都要、且要在无头 NAS 上也生效，混进去会让「命名没生效」和
#      「压根没声」这两种完全不同的故障共用一套日志，排障时反而更难切分。
#
#  验证状态（2026-11-25，同一块 cm3588-nas 冷启动）：
#      把 alsa-restore 临时 mask 掉（防上次实验的运行态被恢复回来污染判定）→ 断电重启 →
#      rt5616-audio-init.service 开机 +9s 跑完，日志「设置 14 项、跳过 0 项」→
#      此后再没手工碰过控件，直接播放，用户在场逐声确认左右都出声。开机自动生效成立。
#      ⚠️ 排障时别拿 `HP Playback Switch` 当判据：它是 alsa-card-profile(ACP) 自己
#         按端口上/下电管的开关，**空闲（流结束、设备 suspend）时读回 off,off 属正常**，
#         播放期间才是 on,on；本次观测到播放结束后约 10 秒被置 off，而声音在播放那一刻正常。
#         ACP 不管、必须本服务打开的是 HPO 的两个**输入源**（`HPO MIX DAC1` /
#         `HPO MIX HPVOL`）——实测这两个值冷启动后一直停在 on，不受流生命周期影响。
#
#  可移植性：门控 LINUXFAMILY（rk35xx / rockchip-rk3588）；卡号按 /sys/class/sound/card*/id
#      = realtekrt5616co 现场探测（HDMI/DP 注册顺序一变卡号就漂，写死 -c 1 必翻车）。
#      板子没贴 RT5616 时服务自己判定「找不到声卡」并成功退出，不留错误。
# =============================================================================

function extension_prepare_config__rt5616_audio_route() {
	[[ "${LINUXFAMILY:-}" =~ ^(rk35xx|rockchip-rk3588)$ ]] || return 1
	return 0
}

function post_armbian_repo_customize_image__rt5616_audio_route() {
	if [[ -z "${SDCARD:-}" || ! -d "${SDCARD}" ]]; then
		display_alert "Extension: ${EXTENSION}" "SDCARD 不可用，跳过 RT5616 通路初始化" "warn"
		return 0
	fi

	local bindir="${SDCARD}/usr/local/sbin"
	local unitdir="${SDCARD}/etc/systemd/system"
	local wantsdir="${unitdir}/multi-user.target.wants"

	mkdir -p "${bindir}" "${unitdir}" "${wantsdir}"
	cat >"${bindir}/rt5616-audio-init.sh" <<'RT5616INIT'
#!/usr/bin/env bash
# rt5616-audio-init —— 打开 RT5616 的 DAC→HPO 通路（由 rt5616-audio-init.service 调用）
# 只动 codec 内部路由与音量，不抢 PCM、不碰 PipeWire；任何一步失败都只记日志并成功退出。
set -u
CARD_ID_NAME=${CARD_ID_NAME:-realtekrt5616co}
WAIT_CARD=${WAIT_CARD:-15}
# 要打开的控件：名字 = 空格分隔的值（stereo 用 "on,on"，音量用 "31,31"）
# 顺序照 am60-sa12 那份已跑通的配方：先喂 DAC 的输入源，再选 HPO 的输入，最后开 HP 驱动。
CONTROLS=(
	"DAC MIXL INF1 Switch=on"
	"DAC MIXR INF1 Switch=on"
	"Stereo DAC MIXL DAC L1 Switch=on"
	"Stereo DAC MIXR DAC R1 Switch=on"
	"DAC1 Playback Volume=175,175"
	"HPO MIX DAC1 Switch=on"
	"HPO MIX HPVOL Switch=on"
	"HPVOL Playback Switch=on,on"
	"HP Playback Switch=on,on"
	"HP Playback Volume=31,31"
	"OUT MIXL DAC L1 Switch=on"
	"OUT MIXR DAC R1 Switch=on"
	"OUT Playback Switch=on,on"
	"OUT Playback Volume=31,31"
)

log() {
	printf 'rt5616-audio-init: %s\n' "$*"
	logger -t rt5616-audio-init -- "$*" 2>/dev/null || true
}

# 声卡由 I2S/codec 驱动注册，可能晚于本服务；最多等 WAIT_CARD 秒
for _ in $(seq 1 "$WAIT_CARD"); do
	[ -n "$(grep -lx "$CARD_ID_NAME" /sys/class/sound/card[0-9]*/id 2>/dev/null)" ] && break
	sleep 1
done

# 卡号按 sysfs 的 id 精确匹配。别去解析 /proc/asound/cards 的方括号：
# id 满 15 字符时那格是 "[realtekrt5616co]:"，按空格取字段会带上 "]:"。
CARD=""
for c in /sys/class/sound/card[0-9]*; do
	[ "$(cat "$c/id" 2>/dev/null)" = "$CARD_ID_NAME" ] || continue
	CARD=${c##*/card}
	break
done
if [ -z "$CARD" ]; then
	log "没有 $CARD_ID_NAME 声卡（本板没贴 RT5616 或驱动没起来），不做任何事"
	exit 0
fi
log "使用 card$CARD ($CARD_ID_NAME)"

applied=0 skipped=0
for kv in "${CONTROLS[@]}"; do
	name=${kv%%=*}
	value=${kv#*=}
	# 控件不存在（老内核/别的 codec 版本）时静默跳过，别把失败说成成功
	if ! amixer -c "$CARD" cget name="$name" >/dev/null 2>&1; then
		skipped=$((skipped + 1))
		continue
	fi
	if amixer -c "$CARD" cset name="$name" "$value" >/dev/null 2>&1; then
		applied=$((applied + 1))
	else
		log "  cset 失败：$name=$value（声卡可能被独占）"
		skipped=$((skipped + 1))
	fi
done

# 关键开关复核：HPO 两条输入都没通 = 依旧没声，这条日志值一次读回
hpodac=$(amixer -c "$CARD" cget name='HPO MIX DAC1 Switch' 2>/dev/null | sed -n 's/.*: values=//p')
hpvolmix=$(amixer -c "$CARD" cget name='HPO MIX HPVOL Switch' 2>/dev/null | sed -n 's/.*: values=//p')
if [ "$hpodac" != on ] && [ "$hpvolmix" != on ]; then
	log "⚠️ HPO 的两个输入源都还是 off（DAC1=$hpodac HPVOL=$hpvolmix），3.5 大概率仍无声"
else
	log "耳机通路已开启（HPO MIX DAC1=$hpodac HPO MIX HPVOL=$hpvolmix；设置 $applied 项、跳过 $skipped 项）"
fi
exit 0
RT5616INIT
	chmod 755 "${bindir}/rt5616-audio-init.sh"

	cat >"${unitdir}/rt5616-audio-init.service" <<'RT5616UNIT'
[Unit]
Description=RT5616 3.5mm headphone route init
Documentation=https://github.com/xiaobao1980/armbian-custom-builds
After=sound.target local-fs.target alsa-restore.service
Wants=sound.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/rt5616-audio-init.sh
TimeoutStartSec=60
Nice=5

[Install]
WantedBy=multi-user.target
RT5616UNIT
	chmod 644 "${unitdir}/rt5616-audio-init.service"

	# chroot 里没有 PID 1，systemctl enable 不可用 → 直接建 wants 软链
	ln -sfn "/etc/systemd/system/rt5616-audio-init.service" \
		"${wantsdir}/rt5616-audio-init.service"

	# ---------------------------------------------------------------------
	# 落地终验
	# ---------------------------------------------------------------------
	if [[ -x "${bindir}/rt5616-audio-init.sh" ]] &&
		[[ -f "${unitdir}/rt5616-audio-init.service" ]] &&
		[[ -L "${wantsdir}/rt5616-audio-init.service" ]] &&
		bash -n "${bindir}/rt5616-audio-init.sh"; then
		display_alert "Extension: ${EXTENSION}" "RT5616 通路初始化已装并 enable（开机按卡名探测，无该卡则空跑）" "info"
		return 0
	fi
	display_alert "Extension: ${EXTENSION}" "RT5616 通路初始化落地校验失败" "err"
	return 1
}

#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
# Armbian build framework extension
#
# audio-friendly-names —— 声卡「看得懂的名字」+ 无桌面镜像的 ALSA 出口切换
#
# =============================================================================
#  为什么需要这个扩展
# -----------------------------------------------------------------------------
#  rk35xx 厂商内核把 HDMI/DP/耳机 codec 注册成一堆独立声卡，PipeWire 里全叫
#  「Built-in Audio」，桌面音量面板上分不清哪个是 HDMI-0、哪个是耳机。
#  cm3588-nas 实测（vendor 6.1 / noble）：
#      card0 rockchiphdmiin   ID_PATH=platform-hdmiin-sound   （纯采集，无 PCM）
#      card1 realtekrt5616co  ID_PATH=platform-rt5616-sound   （耳机 + 麦克风）
#      card2 rockchiphdmi0    ID_PATH=platform-hdmi0-sound
#      card3 rockchipdp0      ID_PATH=platform-dp0-sound
#      card4 rockchiphdmi1    ID_PATH=platform-hdmi1-sound
#  五张卡的 device.description 全是 "Built-in Audio"。
#
#  两个必须踩准的事实（都在板上验证过，别照着旧笔记改）：
#   1) udev 的 ENV{SOUND_DESCRIPTION} 只有 **PulseAudio** 的 module-udev-detect 读；
#      PipeWire / spa-alsa / WirePlumber 全都不消费它（全盘 grep 二进制为空）。
#      所以只写 udev 规则 = 名字永远不变。udev 规则这里仍然写，是为了兼容
#      纯 PulseAudio 的镜像，PipeWire 镜像靠下面的 WirePlumber 规则生效。
#   2) WirePlumber 两套配置语法不通用，且「追加」写法各不相同：
#      · 0.4（noble，0.4.17）：Lua 片段 /etc/wireplumber/main.lua.d/51-*.lua，
#        必须 table.insert(alsa_monitor.rules, {...}) —— 直接 alsa_monitor.rules = {...}
#        会**整表覆盖** 50-alsa-config.lua 里的 api.alsa.use-acp 等默认规则，音频会坏。
#      · 0.5+（trixie / resolute）：SPA-JSON 片段 /etc/wireplumber/wireplumber.conf.d/51-*.conf，
#        monitor.alsa.rules = [...] 是**追加**语义（要覆盖得写 override. 前缀），
#        正则匹配必须带 "~" 前缀，且用 [.] 代替 \. （SPA-JSON 字符串不认 \. 转义）。
#      注意 0.4.17 也装了 /usr/share/wireplumber/wireplumber.conf，所以判版本要
#      **先看 main.lua.d 目录**，不能只看有没有 wireplumber.conf。
#      验证状态：0.4 分支在 cm3588-nas（noble，WirePlumber 0.4.17）实跑通过；
#      JSON 分支 2026-11-25 在同一块板重刷成 Ubuntu 26.04 resolute
#      （PipeWire/WirePlumber 1.6.2，无 main.lua.d → flavor=json）实跑通过：
#      wpctl status 里四张卡的 Device 名与 Sink/Source 名都换成中文名，
#      rt5616 的 Sink 是默认出口、profile 保持 output+input。
#
#  做法（桌面镜像 BUILD_DESKTOP=yes）：
#      装 /usr/local/sbin/rk-audio-names.sh + rk-audio-names.service（oneshot，
#      multi-user.target.wants，Before=graphical.target）。开机时声卡已注册、
#      桌面会话还没起 → 生成规则后 WirePlumber 首次启动就读到，无需重启音频栈。
#      脚本按 /sys/class/sound/card* 的 ID_PATH 关键字现场枚举（构建期 chroot 里
#      没有声卡，写死卡号/卡名换板就废），内容没变化就不回写、不动 udev。
#      顺带补装 libcanberra-pulse：桌面「声音」面板的扬声器测试与系统提示音走
#      libcanberra，只带 ALSA 后端时会被 PipeWire 独占声卡挡成静默失败（详见函数内注释）。
#
#  做法（无桌面镜像 BUILD_DESKTOP=no）：
#      装 /usr/local/bin/audio-switch（参考 openEuler rk3576 的同名工具改写）：
#      写 /etc/asound.conf 把 ALSA default 指向目标卡，卡号同样按 ID_PATH 关键字
#      探测而不是写死 0/1/2；目标卡没有播放 PCM 时拒绝切换（cm3588-nas 的
#      hdmiin 就是纯采集卡，切过去必然没声）。
#      **不预设默认出口**：NAS/展厅要 HDMI 还是耳机取决于接法，出厂写死容易猜错，
#      装机后跑一次 `sudo audio-switch hdmi`（或 3.5）即可，`audio-switch list` 看候选。
#
#  排障（2026-11-25 cm3588-nas「设置→声音 里没有 3.5 音频」的结论）：
#      真因不是缺设备。`wpctl status` 里 alsa_output.platform-rt5616-sound.stereo-fallback
#      一直在、还是默认 Sink、profile 也是 output+input —— 只是当时的名字「耳机输出/
#      麦克风输入」不带「3.5」字样，一屏 HDMI/DP 里认不出来；再叠上那个镜像早于
#      libcanberra-pulse 修复、「测试」按钮点了没响，就报成了「没有 3.5」。
#      所以查这类反馈先看 wpctl / pw-dump 的 Sink 名单再下结论，别照名字判。
#      另注：PipeWire 把某张卡判成只剩采集节点时，看 pw-dump 该 Device 的
#      EnumProfile 里 output 那档 available 是不是 "no"（插孔检测导致），这才是真缺出口。
#
#  可移植性：只依赖 udevadm + systemd；桌面侧按 WirePlumber 实际版本选语法，
#      没装 WirePlumber（纯 PulseAudio / 纯 ALSA）时只落 udev 规则，不报错。
#      与 SoC/板型、X11/Wayland、是否启用中文扩展无关；未识别的声卡原样保留。
# =============================================================================

function extension_prepare_config__audio_friendly_names() {
	[[ "${LINUXFAMILY:-}" =~ ^(rk35xx|rockchip-rk3588)$ ]] || return 1
	return 0
}

function post_armbian_repo_customize_image__audio_friendly_names() {
	if [[ -z "${SDCARD:-}" || ! -d "${SDCARD}" ]]; then
		display_alert "Extension: ${EXTENSION}" "SDCARD 不可用，跳过声卡友好命名" "warn"
		return 0
	fi

	local bindir="${SDCARD}/usr/local/sbin"
	local unitdir="${SDCARD}/etc/systemd/system"
	local wantsdir="${unitdir}/multi-user.target.wants"

	# ---------------------------------------------------------------------
	# 桌面侧：开机生成 udev + WirePlumber 命名规则。
	# 无桌面镜像不装这套：没有 WirePlumber/PulseAudio 时 udev 的 SOUND_DESCRIPTION
	# 根本没人消费，白搭一个 boot oneshot（没声卡的板还会空等 WAIT_CARD 秒拖慢启动）。
	# ---------------------------------------------------------------------
	if [[ "${BUILD_DESKTOP:-no}" == "yes" ]]; then
		mkdir -p "${bindir}" "${unitdir}" "${wantsdir}"
		cat >"${bindir}/rk-audio-names.sh" <<'AUDIONAMES'
#!/usr/bin/env bash
# rk-audio-names —— 按 ID_PATH 给 rk35xx 声卡起友好名字（由 rk-audio-names.service 调用）
# 识别不了的声卡原样保留；任何一步失败都只记日志并成功退出，绝不阻断开机。
set -u
UDEV_RULES=/etc/udev/rules.d/90-rk-audio-names.rules
LUA_CONF=/etc/wireplumber/main.lua.d/51-rk-audio-names.lua
JSON_CONF=/etc/wireplumber/wireplumber.conf.d/51-rk-audio-names.conf
WAIT_CARD=${WAIT_CARD:-15}

log() {
	printf 'rk-audio-names: %s\n' "$*"
	logger -t rk-audio-names -- "$*" 2>/dev/null || true
}

# 关键字 → 友好名。顺序有意义：hdmiin 必须先于 hdmi0/hdmi1/hdmi 命中。
# 关键字表按**本仓库各板 DTS 里 status="okay" 的 sound 节点名**逐个对出来，不是猜的：
#   h96s        hdmi-sound / ht5010-sound(card name 就叫 "3.5mm Audio") / spdif-tx0-sound
#   neardi-lz120 hdmi-sound / rk809-sound(RK809 PMIC 内置 codec，带 hp-det-gpio)
#   rock-5-itx  es8316-sound / hdmi1-sound / dp0-sound / dp1-sound / hdmiin-sound
#   am60-sa12   hdmi0/hdmi1/dp0/hdmiin + it6621-sound(cpu=spdif_tx0，HDMI 桥)
#               + ms4344-dac-sound(3.5mm 占位，DTS 注明 dummy 不出声) + es7243-adc-linein(纯采集)
#               （板级 DTS 里没有 rt5616 节点；只有 overlay 里那套 rt5616 脚本按 cm3588-nas 抄过来的，
#                 真机上 rt5616 到底注册不注册，待 aplay -l 确认）
#   cm3588-nas  hdmiin / rt5616 / hdmi0 / dp0 / hdmi1
#   neardi-lz200 es8388-sound / hdmi-sound / dp0-sound（dp2/edp 都是 disabled，不注册）
# 3.5mm 口那几条**必须带「3.5mm」字样**：面板里只写「耳机输出」时，用户对着
# 一屏 HDMI/DP 找不到哪个是绿色那个口（2026-11-25 cm3588-nas 实测反馈：3.5 出口
# 其实一直在，就是认不出来）。和 audio-switch 的 label_of 保持同一措辞。
friendly_name() {
	case "$1" in
		*hdmiin*|*hdmirx*|*hdmi-rx*|*hdmi_rx*)          echo "HDMI-IN 音频输入" ;;
		*hdmi0*)                                        echo "HDMI-0 音频输出" ;;
		*hdmi1*)                                        echo "HDMI-1 音频输出" ;;
		*it6621*)                                       echo "HDMI(IT6621 桥) 音频输出" ;;
		*hdmi*)                                         echo "HDMI 音频输出" ;;
		*dp0*|*dp1*|*dp2*|*usbdp*)                      echo "DP(USB-C) 音频输出" ;;
		*edp*)                                          echo "eDP 音频输出" ;;
		*spdif*)                                        echo "S/PDIF 音频输出" ;;
		*es7243*|*linein*|*line-in*|*pdm-mic*)          echo "线路/麦克风输入（采集）" ;;
		*ms4344*)                                       echo "3.5mm 耳机输出（占位无声）" ;;
		*ht5010*)                                       echo "3.5mm 耳机输出" ;;
		*rt5616*|*es8388*|*es8328*|*es8316*|*es8323*)   echo "3.5mm 耳机输出/麦克风输入" ;;
		*rk809*|*rk817*|*rk816*)                        echo "3.5mm 耳机输出/麦克风输入（PMIC codec）" ;;
		*codec*|*headphone*)                            echo "3.5mm 耳机输出/麦克风输入" ;;
		*)                                              echo "" ;;
	esac
}

# 声卡由内核驱动注册，可能晚于本服务；最多等 WAIT_CARD 秒
for _ in $(seq 1 "$WAIT_CARD"); do
	[ -n "$(ls -d /sys/class/sound/card[0-9]* 2>/dev/null)" ] && break
	sleep 1
done

UDEV_LINES=(); LUA_RULES=(); JSON_RULES=(); found=0
for card in /sys/class/sound/card[0-9]*; do
	[ -e "$card" ] || continue
	idpath=$(udevadm info --query=property --path="$card" 2>/dev/null | sed -n 's/^ID_PATH=//p')
	[ -n "$idpath" ] || continue
	desc=$(friendly_name "$idpath")
	[ -n "$desc" ] || continue
	found=1
	log "  $(basename "$card") ID_PATH=$idpath → $desc"

	# PulseAudio 路线（PipeWire 不读这个属性，见扩展头注释）
	UDEV_LINES+=("SUBSYSTEM==\"sound\", ENV{ID_PATH}==\"$idpath\", ENV{SOUND_DESCRIPTION}=\"$desc\"")

	# WirePlumber 0.4：table.insert 追加，别整表赋值
	LUA_RULES+=("table.insert(alsa_monitor.rules, { matches = { { { \"device.name\", \"matches\", \"alsa_card.$idpath\" } } }, apply_properties = { [\"device.description\"] = \"$desc\" } })")
	LUA_RULES+=("table.insert(alsa_monitor.rules, { matches = { { { \"node.name\", \"matches\", \"alsa_output.$idpath.*\" } }, { { \"node.name\", \"matches\", \"alsa_input.$idpath.*\" } } }, apply_properties = { [\"node.description\"] = \"$desc\" } })")

	# WirePlumber 0.5：数组追加语义；正则带 ~ 前缀，用 [.] 不用 \.
	JSON_RULES+=("  { matches = [ { device.name = \"alsa_card.$idpath\" } ] actions = { update-props = { device.description = \"$desc\" } } }")
	JSON_RULES+=("  { matches = [ { node.name = \"~alsa_(output|input)[.]$idpath[.].*\" } ] actions = { update-props = { node.description = \"$desc\" } } }")
done

if [ "$found" != 1 ]; then
	log "没有识别到可命名的声卡（ID_PATH 不匹配已知关键字），保持原样"
	exit 0
fi

# 内容一致就不回写：重复开机是 no-op，也不会无谓重启用户的音频栈
write_if_changed() {
	local dest="$1" tmp
	tmp=$(mktemp) || return 1
	cat >"$tmp"
	mkdir -p "$(dirname "$dest")"
	if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
		rm -f "$tmp"
		return 1
	fi
	cat "$tmp" >"$dest" && chmod 644 "$dest"
	rm -f "$tmp"
	return 0
}

# 判 WirePlumber 语法：0.4.17 也带 wireplumber.conf，所以必须先认 main.lua.d
flavor=none
if [ -d /usr/share/wireplumber/main.lua.d ]; then
	flavor=lua
elif [ -d /usr/share/wireplumber/wireplumber.conf.d ] || [ -d /etc/wireplumber/wireplumber.conf.d ]; then
	flavor=json
elif command -v wireplumber >/dev/null 2>&1; then
	case "$(wireplumber --version 2>/dev/null | sed -n 1p | awk '{print $NF}')" in
		0.4*) flavor=lua ;;
		0.[5-9]*|[1-9]*) flavor=json ;;
	esac
fi

changed=0
printf '%s\n' "${UDEV_LINES[@]}" | write_if_changed "$UDEV_RULES" && changed=1
case "$flavor" in
	lua)
		{
			echo "-- 由 rk-audio-names 生成：声卡友好命名（WirePlumber 0.4 Lua 语法）"
			echo "alsa_monitor.rules = alsa_monitor.rules or {}"
			printf '%s\n' "${LUA_RULES[@]}"
		} | write_if_changed "$LUA_CONF" && changed=1
		;;
	json)
		{
			echo "# 由 rk-audio-names 生成：声卡友好命名（WirePlumber 0.5 SPA-JSON 语法）"
			echo "monitor.alsa.rules = ["
			printf '%s\n' "${JSON_RULES[@]}"
			echo "]"
		} | write_if_changed "$JSON_CONF" && changed=1
		;;
	*)
		log "未检测到 WirePlumber（纯 PulseAudio / 纯 ALSA），只落 udev 规则"
		;;
esac

if [ "$changed" != 1 ]; then
	log "声卡命名无变化（wireplumber=${flavor}）"
	exit 0
fi

udevadm control --reload 2>/dev/null || true
udevadm trigger --subsystem-match=sound 2>/dev/null || true

# 开机路径下桌面会话还没起，这个循环自然空转；手工重跑时才真正重启音频栈
for udir in /run/user/*; do
	[ -S "$udir/bus" ] || continue
	uid=${udir##*/}
	user=$(id -nu "$uid" 2>/dev/null) || continue
	log "  重启 $user 的音频栈以应用新名字"
	sudo -u "$user" XDG_RUNTIME_DIR="$udir" DBUS_SESSION_BUS_ADDRESS="unix:path=$udir/bus" \
		systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null ||
		sudo -u "$user" XDG_RUNTIME_DIR="$udir" DBUS_SESSION_BUS_ADDRESS="unix:path=$udir/bus" \
			systemctl --user restart pulseaudio 2>/dev/null || true
done

log "声卡友好命名已更新（wireplumber=${flavor}）"
exit 0
AUDIONAMES
		chmod 755 "${bindir}/rk-audio-names.sh"

		cat >"${unitdir}/rk-audio-names.service" <<'AUDIONAMESUNIT'
[Unit]
Description=Friendly names for RK35xx sound cards (udev + WirePlumber)
Documentation=https://github.com/xiaobao1980/armbian-custom-builds
After=systemd-udev-trigger.service local-fs.target
Before=graphical.target display-manager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/rk-audio-names.sh
TimeoutStartSec=60
Nice=5

[Install]
WantedBy=multi-user.target
AUDIONAMESUNIT
		chmod 644 "${unitdir}/rk-audio-names.service"

		# chroot 里没有 PID 1，systemctl enable 不可用 → 直接建 wants 软链
		ln -sfn "/etc/systemd/system/rk-audio-names.service" \
			"${wantsdir}/rk-audio-names.service"

		# -----------------------------------------------------------------
		# 桌面事件音后端：GNOME「设置 → 声音 → 测试」、XFCE 事件音、系统提示音
		# 全走 libcanberra，而 canberra 的后端是**运行时按目录挑插件**的。桌面档位
		# 镜像默认只带 libcanberra-alsa.so（alsa-utils 拖进来的），PipeWire 又独占
		# 声卡 → ALSA 后端打不开设备（板上 `aplay -D plughw:0,0` 直接报「设备或资源
		# 忙」），而 canberra 打不开设备是**静默失败**：症状就是「设置里点测试一点
		# 声音没有，但 pw-play 播同一个文件正常」，很容易被误判成声卡/功放坏了。
		# 补上 Pulse 后端，让它走 pipewire-pulse 协议而不是直连 ALSA 设备。
		# 2026-11-25 在 207 板 neardi-lz120 实测：装上 libcanberra-pulse 并重启
		# 「设置」进程后，左右声道测试 immediate 出声。
		# 装失败不阻断构建（离线/镜像源缺包都可能），只 warn，现场可补装。
		# -----------------------------------------------------------------
		if [[ "${LIBCANBERRA_PULSE:-yes}" == "yes" ]]; then
			if chroot_sdcard "dpkg -s libcanberra-pulse" >/dev/null 2>&1; then
				display_alert "Extension: ${EXTENSION}" "libcanberra-pulse 已在镜像内，跳过" "debug"
			else
				if ! chroot_sdcard "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libcanberra-pulse"; then
					display_alert "Extension: ${EXTENSION}" "apt-get update 后重试 libcanberra-pulse" "warn"
					chroot_sdcard "apt-get update -qq"
					if ! chroot_sdcard "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libcanberra-pulse"; then
						display_alert "Extension: ${EXTENSION}" "libcanberra-pulse 没装上：桌面「声音」面板的扬声器测试与系统提示音会没声（canberra 只剩打不开声卡的 ALSA 后端）。装机后补一次即可：sudo apt-get install -y libcanberra-pulse" "warn"
					fi
				fi
			fi
		fi
	else
		# -----------------------------------------------------------------
		# 无桌面侧：ALSA 默认出口切换工具（桌面镜像不装，免得 hw: 直连绕过 PipeWire）
		# -----------------------------------------------------------------
		mkdir -p "${SDCARD}/usr/local/bin"
		cat >"${SDCARD}/usr/local/bin/audio-switch" <<'AUDIOSWITCH'
#!/usr/bin/env bash
# audio-switch —— 无桌面镜像的 ALSA 默认出口切换（rk35xx）
# 原理：写 /etc/asound.conf 把 alsa "default" 指向目标卡，所有 ALSA 应用跟随。
#       卡号按 ID_PATH 关键字现场探测（不写死 0/1/2，换板/换内核卡号会变）。
# 用法：
#   sudo audio-switch 3.5|hdmi|hdmi1|it6621|dp|spdif   切换默认出口
#   audio-switch list                           看候选声卡与播放能力
#   audio-switch status                         看当前默认出口
#   sudo audio-switch test                      播 3 秒 1kHz 测试音
set -u
CONF=/etc/asound.conf

# 卡名直接取 sysfs 的 id（= ALSA hw:<name> 用的名字）。别去解析 /proc/asound/cards
# 的方括号：id 满 15 字符时那格是 "[realtekrt5616co]:"，按空格取字段会带上 "]:"，
# 写进 asound.conf 就成了非法卡名（参考脚本里的 awk 就有这个坑，111 板实测）。
card_name() { cat "/sys/class/sound/card$1/id" 2>/dev/null; }

# $1 = ID_PATH 的扩展正则；命中就回卡号。udevadm 拿不到时退回卡 id。
find_card() {
	local c idpath
	for c in /sys/class/sound/card[0-9]*; do
		[ -e "$c" ] || continue
		idpath=$(udevadm info --query=property --path="$c" 2>/dev/null | sed -n 's/^ID_PATH=//p')
		[ -n "$idpath" ] || idpath=$(cat "$c/id" 2>/dev/null)
		if printf '%s' "$idpath" | grep -Eq "$1"; then
			echo "${c##*/card}"
			return 0
		fi
	done
	return 1
}

has_playback() { ls -d "/proc/asound/card$1/pcm"*p >/dev/null 2>&1; }

label_of() {
	case "$1" in
		*hdmiin*|*hdmirx*|*hdmi-rx*|*hdmi_rx*) echo "HDMI-IN 采集" ;;
		*hdmi0*) echo "HDMI-0" ;;
		*hdmi1*) echo "HDMI-1" ;;
		*it6621*) echo "HDMI(IT6621 桥)" ;;
		*hdmi*) echo "HDMI" ;;
		*dp0*|*dp1*|*dp2*|*usbdp*) echo "DP(USB-C)" ;;
		*edp*) echo "eDP" ;;
		*spdif*) echo "S/PDIF" ;;
		*es7243*|*linein*|*line-in*|*pdm-mic*) echo "线路/麦克风输入" ;;
		*ms4344*) echo "3.5mm(占位无声)" ;;
		*ht5010*) echo "3.5mm 耳机" ;;
		*rt5616*|*es8388*|*es8328*|*es8316*|*es8323*) echo "3.5mm 耳机/麦克风" ;;
		*rk809*|*rk817*|*rk816*) echo "3.5mm(PMIC codec)" ;;
		*codec*|*headphone*) echo "3.5mm 耳机/麦克风" ;;
		*) echo "其它" ;;
	esac
}

idpath_of() {
	local p
	p=$(udevadm info --query=property --path="/sys/class/sound/card$1" 2>/dev/null | sed -n 's/^ID_PATH=//p')
	[ -n "$p" ] && printf '%s' "$p" || cat "/sys/class/sound/card$1/id" 2>/dev/null
}

# HT5010 专属路由：只有真拿到 numid=31 控件才设置（其它 codec 自动跳过）。
# amixer 在声卡不可访问时也 rc=0 但输出 "Invalid card number"，必须看输出内容。
fix_ht5010_route() {
	command -v amixer >/dev/null 2>&1 || return 0
	local num="$1" probe
	probe="$(amixer -c "$num" cget numid=31 2>&1)"
	echo "$probe" | grep -q 'numid=31' || return 0
	amixer -c "$num" cset numid=31 0 >/dev/null 2>&1
	amixer -c "$num" cset numid=3 0 >/dev/null 2>&1
}

do_switch() {
	local regex="$1" label="$2" num card
	[ "$(id -u)" = 0 ] || { echo "❌ 切换需要 root：sudo audio-switch $label"; return 1; }
	num=$(find_card "$regex") || { echo "❌ 没找到 $label 声卡，先跑 audio-switch list"; return 1; }
	card=$(card_name "$num")
	[ -n "$card" ] || { echo "❌ 读不到 card$num 的卡名"; return 1; }
	if ! has_playback "$num"; then
		echo "❌ $label (card$num: $card) 没有播放设备（纯采集卡），不能当默认出口"
		return 1
	fi
	cat >"$CONF.tmp" <<EOF
# 由 audio-switch 生成（$(date '+%F %T')）：默认输出 → $label (card$num: $card)
pcm.!default {
    type plug
    slave.pcm "hw:$card"
}
ctl.!default {
    type hw
    card $card
}
EOF
	mv "$CONF.tmp" "$CONF" || { echo "❌ 写 $CONF 失败"; return 1; }
	fix_ht5010_route "$num"
	echo "✅ 默认音频出口 → $label (hw:$card / card$num)"
	echo "   验证：audio-switch status；听音用 sudo audio-switch test"
}

show_list() {
	local c num id
	echo "== 声卡清单（card / 卡名 / 出口 / 播放设备）=="
	for c in /sys/class/sound/card[0-9]*; do
		[ -e "$c" ] || continue
		num=${c##*/card}
		id=$(idpath_of "$num")
		printf "  card%-2s %-18s %-20s %s\n" "$num" "$(card_name "$num")" "$(label_of "$id")" \
			"$(has_playback "$num" && echo 有 || echo 无-纯采集)"
	done
}

case "${1-}" in
	# 3.5 目标**故意不含 ms4344**：am60-sa12 的 ms4344-dac-sound 用 dummy codec 占位，
	# 声卡会注册、播放 PCM 也在（has_playback 拦不住），但 DTS 注释明写「不会真出声」。
	# 让它进 3.5 目标 = 切过去一片安静还以为切成功了。list 里仍会显示它的真实状态。
	3.5|35|3.5mm|headphone) do_switch 'rt5616|es8388|es8328|es8316|es8323|rk809|rk817|rk816|ht5010|codec|headphone' "3.5" ;;
	# hdmi 目标匹配精确节点名而不是裸 'hdmi'：h96s / lz200 / lz120 的节点就叫 hdmi-sound
	# （单路 HDMI，无编号），cm3588-nas / am60 叫 hdmi0-sound。裸 'hdmi' 会同时吃掉
	# hdmiin-sound（纯采集）和 hdmi-rx，POSIX ERE 又没有负向断言可排除 → 列举真实名字最稳。
	hdmi|hdmi0)             do_switch 'hdmi0|hdmi-sound|hdmi_sound' "hdmi" ;;
	hdmi1)                  do_switch 'hdmi1' "hdmi1" ;;
	# it6621 单列一个目标、不并进 hdmi：am60-sa12 上 it6621-sound(SPDIF→IT6621 桥) 与
	# hdmi0-sound/hdmi1-sound 同时 status="okay"，而 find_card 取**卡号最小**的命中，
	# 并进去会让 `hdmi` 到底切到哪一路取决于探测顺序。桥接那路要用时显式指名。
	it6621|bridge)          do_switch 'it6621' "it6621" ;;
	dp|dp0|usb-c)           do_switch 'dp0|dp1|dp2|usbdp' "dp" ;;
	spdif|spdif-out)        do_switch 'spdif' "spdif" ;;
	list) show_list ;;
	status)
		show_list
		echo "== 当前 $CONF =="
		if [ -f "$CONF" ]; then
			grep -o 'hw:[A-Za-z_0-9]*' "$CONF" | sed -n 1p
		else
			echo "  未配置（ALSA 用 card0；若 card0 是纯采集卡则没声，挑一个出口切过去）"
		fi
		;;
	test)
		[ "$(id -u)" = 0 ] || { echo "❌ 播测试音需要 root：sudo audio-switch test"; exit 1; }
		if command -v mpv >/dev/null 2>&1; then
			mpv --no-config --vo=null --ao=alsa --audio-device=alsa/default \
				--msg-level=ao=no 'av://lavfi:sine=frequency=1000:duration=3' 2>/dev/null &&
				echo "测试音已播 3 秒（1kHz）"
		elif command -v speaker-test >/dev/null 2>&1; then
			speaker-test -c2 -twav -l1 2>/dev/null | tail -1
		else
			echo "❌ 无 mpv / speaker-test（apt install alsa-utils 后再试）"
		fi
		;;
	*)
		echo "用法:"
		echo "  sudo audio-switch 3.5     # 3.5mm 耳机（codec 卡）"
		echo "  sudo audio-switch hdmi    # HDMI-0"
		echo "  sudo audio-switch hdmi1   # HDMI-1"
		echo "  sudo audio-switch it6621  # HDMI（IT6621 桥，am60-sa12）"
		echo "  sudo audio-switch dp      # DP / USB-C"
		echo "  sudo audio-switch spdif   # S/PDIF"
		echo "  audio-switch list         # 候选声卡与播放能力"
		echo "  audio-switch status       # 当前默认出口"
		echo "  sudo audio-switch test    # 播 3 秒测试音"
		exit 1
		;;
esac
AUDIOSWITCH
		chmod 755 "${SDCARD}/usr/local/bin/audio-switch"
	fi

	# ---------------------------------------------------------------------
	# 落地终验
	# ---------------------------------------------------------------------
	local ok=1
	if [[ "${BUILD_DESKTOP:-no}" == "yes" ]]; then
		[[ -x "${bindir}/rk-audio-names.sh" ]] || ok=0
		[[ -f "${unitdir}/rk-audio-names.service" ]] || ok=0
		[[ -L "${wantsdir}/rk-audio-names.service" ]] || ok=0
		bash -n "${bindir}/rk-audio-names.sh" || ok=0
	else
		[[ -x "${SDCARD}/usr/local/bin/audio-switch" ]] || ok=0
		bash -n "${SDCARD}/usr/local/bin/audio-switch" || ok=0
	fi
	if [[ "${ok}" == 1 ]]; then
		if [[ "${BUILD_DESKTOP:-no}" == "yes" ]]; then
			display_alert "Extension: ${EXTENSION}" "声卡友好命名已装并 enable（开机生成 udev + WirePlumber 规则）" "info"
		else
			display_alert "Extension: ${EXTENSION}" "无桌面镜像：已装 audio-switch（ALSA 出口切换，不预设默认）" "info"
		fi
	else
		display_alert "Extension: ${EXTENSION}" "声卡友好命名落地校验失败" "err"
		return 1
	fi
	return 0
}
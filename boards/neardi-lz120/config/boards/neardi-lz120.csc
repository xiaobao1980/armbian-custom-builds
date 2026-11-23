# Neardi LZ120 (RK3568) 板级配置
# 放置：config/boards/neardi-lz120.csc（由 scripts/sync-board-to-build.sh 同步进构建树）
#
# ── provenance（正文 1-12 行逐字节照抄厂商件，导入即分叉）─────────────────────
#   来源：Neardi LZ120 官方 6.1.115 镜像随附的 userpatches/config/boards/neardi-lz120.csc
#         本地留档 rk3568/lz120/6.1.115内核配置/neardi-lz120.csc（1-12 行完全一致）
#   内核：armbian/linux-rockchip branch:rk-6.1-rkr7.2 → KERNELPATCHDIR=rk35xx-vendor-6.1
#   U-Boot：radxa/u-boot branch:next-dev-v2024.10 → BOOTPATCHDIR=legacy/u-boot-radxa-rk35xx
#   ⚠️ armbian/build 上游**没有**这块板（构建树里 config/boards/neardi-lz120.csc 一直是
#      未跟踪文件），所以没有 upstream commit 可比、也没有可复制的 diff 命令；
#      厂商/上游后续改动只能手工回合。
#   本地追加（都在文件末尾，逐条登记）：
#     1) ENABLE_EXTENSIONS=verify-boot-env,lz120-kernel-config,audio-friendly-names
#        —— 已整条删除，唯一来源改为同目录 build.env；原因见文件末尾「本地追加 1」。
#     2) PACKAGE_LIST_ADDITIONAL 追加 i2c-tools / libdrm-tests
#        —— LT8912 HDMI 通路 bring-up 用（i2cdetect 探 0x48/0x49、modetest 点屏）
#     3) post_family_tweaks__lz120_display_layout（文件末尾）
#        —— 落盘显示布局脚本 + 开关文件 + autostart/lightdm 两个入口，把原生 HDMI
#           定成主屏、LT8912 桥那路挪右侧扩展屏；含义与两条实测死路见「本地追加 3」。
#
# ── 构建 ────────────────────────────────────────────────────────────────────
#   ./compile.sh BOARD=neardi-lz120 BRANCH=vendor RELEASE=bookworm BUILD_DESKTOP=no
#   本机推荐参数见同目录 build.env。

# Rockchip RK3568 quad core 1-8GB SoC GBe eMMC USB3
BOARD_NAME="neardi lz120"
BOARDFAMILY="rk35xx"
BOARD_MAINTAINER="amazingfate"
BOOTCONFIG="neardi-lz120-rk3568_defconfig"
##BOOTCONFIG="radxa-e25-rk3568_defconfig"
KERNEL_TARGET="vendor"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3568-neardi-lz120-linux.dtb"
BOOT_SCENARIO="spl-blobs"
IMAGE_PARTITION_TABLE="gpt"

# ── 本地追加 1：扩展（已移出本文件，唯一来源是同目录 build.env）───────────────
# 这里**不能**再写 ENABLE_EXTENSIONS= 裸赋值，它是 lz120 桌面镜像起不来的根因：
#   · compile.sh 命令行（workflow 由 build.env 拼出）传进来的值只在 "early" 阶段应用；
#   · 本文件在之后的 config_source_board_file 阶段被 source，裸赋值把整串顶掉；
#   · initialize_extension_manager 只在 do_main_configuration 首次调用时读一次
#     ENABLE_EXTENSIONS，之后 enable_extension() 直接 exit 2 → 被顶掉的项目没有补救机会。
# 2026-11-22 的 lz120 X11/Wayland 两次构建因此只启用了本行那 3 项，workflow 追加的
# 8 项（desktop-dm、default-user、rkmpp-mpv、chromium-rkmpp、rk35xx-chinese-desktop、
# bluetooth-autoconnect、ntp-boot-sync、dtb-no-mac）全丢：镜像里没有
# display-manager.service（noble 的 lightdm unit 是 static 且 deb 不自带该链接）→
# 首启向导走完重启就停在文字界面，且中文字体/mpv(rkmpp)/自动登录一律缺失。
# 本板需要的 3 项已在 build.env 列名，含义见那里的注释：verify-boot-env 出厂前校验
# armbianEnv.txt 的 rootdev/fdtfile；lz120-kernel-config 把 LT8912/panel-simple 置 y；
# audio-friendly-names 无头分支只装 audio-switch。
# ⚠️ 手工跑 compile.sh 时必须自己带 ENABLE_EXTENSIONS（README 的本机参数即来自
#    build.env）；漏掉 lz120-kernel-config 不会报错，只是 LT8912 那条 HDMI 通路
#    的内核符号没置上。

# ── 本地追加 2：bring-up 工具包 ─────────────────────────────────────────────
# Bring-up tooling for the LT8912 DSI->HDMI bridge path (baseboard silkscreen HDMI Tx2;
# the native dw-hdmi is silkscreen HDMI Tx1, next to the VGA connector). modetest, i2c
# probing, weston for the second display.
PACKAGE_LIST_ADDITIONAL="$PACKAGE_LIST_ADDITIONAL i2c-tools libdrm-tests"

# ── 本地追加 3：把原生 HDMI 定成主屏（LT8912 桥那路保留为扩展屏）────────────────
# 现象（2026-11-23 在 207 板实测）：DSI→LT8912 桥没有 EDID/HPD，DRM 恒报 connected，
# 且 mutter 把它当 is-builtin（内置屏）优先选成主屏，于是桌面拼成 3840x1080：
# 接原生 Tx1 的那台只拿到没有顶栏/面板的「副屏」，主屏落到没接东西的幽灵屏上。
# 规则：两路都保持点亮，只把主屏和原点 (0,0) 换成原生 HDMI-1、桥那路挪到右边。
# ⚠️ 别改成「关掉 DSI-1」，也别改成「设备树里 disable 掉 dsi0/route-dsi0/lt8912」，两条都实测过：
#   · 运行期让 mutter 关 DSI：GetCurrentState 里 DSI-1 确实没了 is-current，但
#     /sys/kernel/debug/dri/0/state 里 DSI-1 仍挂着 video_port1，软硬状态分叉，
#     gnome-shell 从此刻起持续刷 `Page flip failed: drmModeAtomicCommit: Invalid
#     argument`，两台显示器全黑、用户会话掉线（2026-11-23 01:57 板上复现）。
#   · 换 dtb 让 DSI 链路压根不存在：/sys/class/drm 只剩 HDMI-A-1、mutter 报单屏
#     1920x1080、page flip 计数 0，但屏上只有开机 log、过会无信号 —— 这颗 SoC 上
#     vp0 单独跑 HDMI 起不来，桥那路不能从设备树里摘掉。
# 只想停掉本逻辑：/etc/default/lz120-display 写 LZ120_NATIVE_HDMI_PRIMARY=0。
# 判定走 /sys/class/drm（原生 HDMI 的 HPD 是真的，不需要任何会话权限）；执行按会话类型分支：
# X11 用 xrandr --primary，Wayland/GNOME 用 mutter 的 DisplayConfig D-Bus。两条路都得留：
# desktop 镜像现在有两种 —— X11 workflow 出 lightdm/XFCE，Wayland workflow 出 GDM/GNOME。
# ApplyMonitorsConfig 只改运行态、不落 ~/.config/monitors.xml（实测无该文件），
# 所以每次登录都要靠 autostart 重放一次；lightdm 那两个 setup-script 覆盖 X11 的 greeter，
# GDM greeter 没覆盖（那是 gdm 用户的会话，本 hook 不去碰）。
function post_family_tweaks__lz120_display_layout() {
	[[ "${BRANCH}" == "vendor" ]] || return 0
	[[ "${BUILD_DESKTOP:-no}" == "yes" ]] || return 0
	[[ -d "${SDCARD:-}" ]] || { display_alert "Extension: ${BOARD}" "SDCARD 不可用，跳过显示布局" "warn"; return 0; }

	mkdir -p "${SDCARD}/usr/local/sbin" "${SDCARD}/etc/lightdm/lightdm.conf.d" "${SDCARD}/etc/xdg/autostart" "${SDCARD}/etc/default"

	cat >"${SDCARD}/usr/local/sbin/lz120-display-layout.sh" <<'LZLAYOUT'
#!/usr/bin/env bash
# lz120-display-layout —— 原生 HDMI（丝印 Tx1）设为主屏，LT8912 桥那路（DSI-1，丝印 Tx2）挪成右侧扩展屏
# 调用点：/etc/xdg/autostart（用户会话内）+ lightdm 的 greeter/display-setup-script。
# 只交换主屏与位置，绝不关闭任何一路：关 DSI 会让 VOP2 软硬状态分叉 → 两屏全黑（见板级注释）。
# 任何一步失败都只记日志并成功退出，绝不阻断登录。
set -u
log() { logger -t lz120-display "$*" 2>/dev/null || true; }

[ -r /etc/default/lz120-display ] && . /etc/default/lz120-display
[ "${LZ120_NATIVE_HDMI_PRIMARY:-1}" = "0" ] && { log "LZ120_NATIVE_HDMI_PRIMARY=0，保持默认布局"; exit 0; }

drm_status() { cat "/sys/class/drm/card0-$1/status" 2>/dev/null || true; }

# 原生 HDMI 没接线，或桥那路不存在 → 没有可交换的对象，一律不动
[ "$(drm_status HDMI-A-1)" = "connected" ] || exit 0
[ "$(drm_status DSI-1)" = "connected" ] || exit 0

stype="${XDG_SESSION_TYPE:-}"
if [[ -z "$stype" ]]; then
	[[ -n "${WAYLAND_DISPLAY:-}" ]] && stype=wayland
	[[ -n "${DISPLAY:-}" ]] && stype=x11
fi
if [[ -z "$stype" ]]; then
	# 兜底：lightdm 的 greeter-setup-script 不带 XDG_SESSION_TYPE/DISPLAY，上面两条都会落空
	# （板上实测留下一句「识别不到会话类型，跳过」）。按服务端本身判：本用户的 runtime 目录里
	# 有 wayland 套接字就是 Wayland；否则 :0/:1 上 xrandr 通得了就是 X11。
	_rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
	for _wl in "$_rt"/wayland-*; do
		[[ -e "$_wl" ]] || continue
		stype=wayland
		export WAYLAND_DISPLAY="${_wl##*/}"
		break
	done
	if [[ -z "$stype" ]]; then
		for _d in :0 :1; do
			if DISPLAY="$_d" xrandr --query >/dev/null 2>&1; then
				stype=x11
				export DISPLAY="$_d"
				break
			fi
		done
	fi
fi

set_x11() {
	command -v xrandr >/dev/null 2>&1 || { log "没有 xrandr"; return 1; }

	# 期望态：HDMI-1 是 primary，且 DSI-1 的横向偏移不为 0。偏移 0 = 两屏叠在 (0,0)，
	# 正是厂商出厂布局；XFCE 的 xfsettingsd 会在会话起步时按自己存的布局重排一次，
	# 把 --right-of 盖回重叠，所以必须复核，不能发完两条命令就当成功。
	x11_ok() {
		local q
		q=$(xrandr --query 2>/dev/null) || return 1
		grep -q 'HDMI-1 connected primary' <<<"$q" || return 1
		grep -qE 'DSI-1 connected [0-9]+x[0-9]+\+[1-9][0-9]*\+[0-9]+\+' <<<"$q"
	}
	apply_x11() {
		xrandr --output HDMI-1 --primary --auto &&
			xrandr --output DSI-1 --auto --right-of HDMI-1
	}

	x11_ok && { log "X11 布局已是 HDMI-1 主屏 + DSI-1 右侧扩展，不动"; return 0; }

	# 有界重试，理由同 mutter 分支：不跟用户自己在显示设置里的调整无限对打。
	local n=0
	while (( n < 6 )); do
		apply_x11 || { log "xrandr 分支未生效"; return 1; }
		sleep 5
		x11_ok && { log "已把原生 HDMI-1 设为主屏，DSI-1（LT8912 桥）挪为右侧扩展屏，布局稳定"; return 0; }
		n=$((n + 1))
		log "X11 布局被会话重排，重新应用（第 $n/6 次）"
	done
	log "复核结束仍未确认 X11 布局稳定；需要时手动跑 $(basename "$0")"
	return 0
}

# GNOME 50 / mutter 的 DisplayConfig：ApplyMonitorsConfig 提交「HDMI-1 主屏@(0,0) +
# DSI-1 @(HDMI 宽度,0)」，两路都带模式 —— 不列出的输出会被 mutter 关掉，所以两路必须都写。
# 模式 id / HDMI 宽度 / 当前主屏归属都从 GetCurrentState 现取，写死会在别的分辨率面板上失败。
# 该调用只改运行态、不写 ~/.config/monitors.xml，所以每次登录都要靠 autostart 重放。
set_mutter() {
	local svc=org.gnome.Mutter.DisplayConfig obj=/org/gnome/Mutter/DisplayConfig
	command -v busctl >/dev/null 2>&1 && command -v gdbus >/dev/null 2>&1 &&
		command -v python3 >/dev/null 2>&1 || { log "缺 busctl/gdbus/python3"; return 1; }
	[[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || export XDG_RUNTIME_DIR="/run/user/$(id -u)"

	# 五行输出：serial / HDMI-1 模式 id / DSI-1 模式 id / HDMI-1 宽度 / 主屏是否已是 HDMI-1
	local py='
d = json.load(sys.stdin)["data"]
def flag(p, k):
    v = p.get(k)
    return v is not None and v.get("data") is True
def bit(v):
    return (v.get("data") if isinstance(v, dict) else v) is True
def pick(name):
    for ident, modes, props in d[1]:
        if ident[0] != name:
            continue
        cur = [m for m in modes if flag(m[6], "is-current")]
        if cur:
            return cur[0]
        pref = [m for m in modes if flag(m[6], "is-preferred")]
        return (pref or modes)[0] if modes else None
    return None
hm, dm = pick("HDMI-1"), pick("DSI-1")
if hm is None or dm is None:
    sys.exit(1)
prim = 1 if any(bit(l[4]) and any(t[0] == "HDMI-1" for t in l[5]) for l in d[2]) else 0
print(d[0])
print(hm[0])
print(dm[0])
print(hm[1])
print(prim)
'
	# 填充 SER / HMODE / DMODE / HW / HPRIM；mutter 注册到总线之前会失败，重试 10 秒
	state() {
		local i out
		for i in 1 2 3 4 5 6 7 8 9 10; do
			out=$(busctl -j --user call "$svc" "$obj" "$svc" GetCurrentState 2>/dev/null |
				python3 -c "import json,sys$py" 2>/dev/null || true)
			if [[ -n "$out" ]]; then
				{ read -r SER; read -r HMODE; read -r DMODE; read -r HW; read -r HPRIM; } <<<"$out"
				return 0
			fi
			sleep 1
		done
		return 1
	}

	apply() {
		gdbus call --session --dest "$svc" --object-path "$obj" \
			--method "$svc.ApplyMonitorsConfig" "$SER" 1 \
			"[(0, 0, 1.0, 0, true, [(\"HDMI-1\", \"$HMODE\", {})]), (${HW:-1920}, 0, 1.0, 0, false, [(\"DSI-1\", \"$DMODE\", {})])]" \
			'{}' >/dev/null 2>&1
	}

	state || { log "取不到 mutter DisplayConfig"; return 1; }
	[[ "${HPRIM:-0}" == "1" ]] && { log "原生 HDMI-1 本来就是主屏，不动"; return 0; }
	apply || { log "ApplyMonitorsConfig 调用失败"; return 1; }

	# 复核循环是必需的，不是保险：mutter 在 gnome-session 起步过程中还会排一次自动布局。
	# 板上实测两种时序 —— autostart 晚于 graphical-session.target 时一次就稳住；早于它时
	# 会话就绪那一刻 mutter 重排会把 DSI-1 顶回主屏。所以应用后按 5 秒一轮复核，被顶回去
	# 就再应用，最多 6 轮；有界重试，避免跟用户自己在显示设置里的调整无限对打。
	local n=0
	while (( n < 6 )); do
		sleep 5
		state || break
		[[ "${HPRIM:-0}" == "1" ]] && { log "已把主屏定在原生 HDMI-1，DSI-1 为右侧扩展屏且布局稳定"; return 0; }
		n=$((n + 1))
		log "mutter 又把 DSI-1 排回主屏，重新应用（第 $n/6 次）"
		apply || break
	done
	log "复核结束仍未能确认布局稳定；需要时手动跑 $(basename "$0")"
	return 0
}

case "$stype" in
	wayland) set_mutter ;;
	x11)
		# XFCE 的面板/显示插件会在会话启动时自己排一次布局，autostart 抢在它前面会被盖回去，
		# 所以默认等一下再调；lightdm 那两次调用发生在会话之前，传 0 立即执行。
		sleep "${1:-3}"
		set_x11
		;;
	*) log "识别不到会话类型，跳过" ;;
esac
exit 0
LZLAYOUT
	chmod 755 "${SDCARD}/usr/local/sbin/lz120-display-layout.sh"

	# 开关文件落一份，而不是只靠脚本里的 ${LZ120_NATIVE_HDMI_PRIMARY:-1} 缺省值：
	# 现场要关这个行为时改这一行就行，不必去翻脚本源码。
	cat >"${SDCARD}/etc/default/lz120-display" <<'LZDEFAULT'
# 1 = 原生 HDMI（丝印 Tx1）设为主屏，LT8912 桥那路（Tx2）挪成右侧扩展屏
# 0 = 完全不动，保持会话自己的布局
LZ120_NATIVE_HDMI_PRIMARY=1
LZDEFAULT
	chmod 644 "${SDCARD}/etc/default/lz120-display"

	# lightdm 读 drop-in 的顺序是 /usr/share → /etc/lightdm/lightdm.conf.d → lightdm.conf，
	# 用片段而不是 sed 主配置：幂等、也不跟 default-user 之类改动互相踩。
	cat >"${SDCARD}/etc/lightdm/lightdm.conf.d/60-lz120-display.conf" <<'LZSEAT'
[Seat:*]
greeter-setup-script=/usr/local/sbin/lz120-display-layout.sh 0
display-setup-script=/usr/local/sbin/lz120-display-layout.sh 0
LZSEAT
	chmod 644 "${SDCARD}/etc/lightdm/lightdm.conf.d/60-lz120-display.conf"

	cat >"${SDCARD}/etc/xdg/autostart/lz120-display-layout.desktop" <<'LZAUTOSTART'
[Desktop Entry]
Type=Application
Name=LZ120 native HDMI as primary
Name[zh_CN]=LZ120 原生 HDMI 设为主屏
Comment=Make the native HDMI the primary monitor and keep the LT8912 bridge as the right-hand extension
Exec=/usr/local/sbin/lz120-display-layout.sh
NoDisplay=true
X-GNOME-Autostart-Enabled=true
LZAUTOSTART
	chmod 644 "${SDCARD}/etc/xdg/autostart/lz120-display-layout.desktop"

	display_alert "Extension: ${BOARD}" "桌面主屏定在原生 HDMI（autostart + lightdm 片段，Wayland 走 mutter、X11 走 xrandr；两路都保持点亮）" "info"
	return 0
}

# ── 关于串口：本板**不需要** serialcon=ttyFIQ0 的板级 hook ────────────────────
# 仓库约定里 rk35xx vendor 板普遍要往 armbianEnv.txt 补 serialcon（boot-rk35xx.cmd
# 把 serialcon 写死成 ttyS2，而 vendor 内核根本没有 /dev/ttyS2）。
# LZ120 实测不用补：0001 补丁带的 rk3568-neardi-lz120-linux.dts 里有
#   chosen { bootargs = "earlycon=uart8250,mmio32,0xfe660000 console=ttyFIQ0"; }
# 厂商 U-Boot 会把它并进最终 bootargs，板上 /proc/cmdline 实测为
#   "... splash=verbose console=ttyFIQ0 console=tty1 consoleblank=0 loglevel=7 ..."
# 既没有 ttyS2，earlycon 也在。别再"顺手"加 hook，否则会出现两个 console= 打架。

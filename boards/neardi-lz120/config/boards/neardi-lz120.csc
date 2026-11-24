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
#   本地追加（3~5 在文件末尾，逐条登记）：
#     0) 顶部 BOOT_FDT_FILE 改指 rk3568-neardi-lz120-linux-hdmi1.dtb（单屏变体）、
#        新增 DTB_KEEP_EXTRA 保住双屏那份 —— 与厂商件在这一行起分叉，理由见「本地追加 3」。
#     1) ENABLE_EXTENSIONS=verify-boot-env,lz120-kernel-config,audio-friendly-names
#        —— 已整条删除，唯一来源改为同目录 build.env；原因见文件末尾「本地追加 1」。
#     2) PACKAGE_LIST_ADDITIONAL 追加 i2c-tools / libdrm-tests
#        —— LT8912 HDMI 通路 bring-up 用（i2cdetect 探 0x48/0x49、modetest 点屏）
#     3) post_family_tweaks__lz120_display_layout（文件末尾）
#        —— 落盘显示布局脚本 + 开关文件 + autostart/lightdm 两个入口；只在**双屏 dtb**
#           下把原生 HDMI 定成主屏、LT8912 桥那路挪右侧扩展屏（单屏 dtb 下自然早退）。
#           出厂默认走单屏 dtb；运行态死路与两份 dtb 的取舍依据见「本地追加 3」。
#     4) post_family_tweaks__lz120_can_quiet（文件末尾）
#        —— /etc/modprobe.d/99-lz120-can-quiet.conf：CAN 接口保留，只压掉
#           rk3568_can_get_berr_counter 那行 netdev_dbg 刷屏；依据见「本地追加 4」。
#     5) post_family_tweaks__lz120_bluetooth（文件末尾）
#        —— 部署 userpatches/lz120-bt-attach（rtk_hciattach 二进制 + attach 脚本 +
#           lz120-bluetooth.service）并 enable。RTL8852BS 的蓝牙在 UART1，内核没有
#           Realtek 的 UART HCI 协议，不 attach 就永远没有 hci0，GNOME 蓝牙开关点了
#           也只翻 rfkill 电源；详见「本地追加 5」。
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
# 出厂默认单屏变体（只留原生 HDMI 丝印 Tx1）；双屏那份留在镜像里，改 fdtfile 即切换。
# 两份都由 0001-lz120-dts.patch 编出来；DTB_KEEP_EXTRA 告诉 rk35xx-chinese-desktop
# 的 DTB 过滤器「这两份都是本板的，别删第二份」，详见「本地追加 3」。
BOOT_FDT_FILE="rockchip/rk3568-neardi-lz120-linux-hdmi1.dtb"
DTB_KEEP_EXTRA="rk3568-neardi-lz120-linux.dtb"
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

# ── 本地追加 3：出厂默认单屏（原生 HDMI 丝印 Tx1），双屏变体保留可随时切 ────────
# 现象（2026-11-23 在 207 板实测）：DSI→LT8912 桥没有 EDID 也没有 HPD，DRM 恒报
# card0-DSI-1 connected 1920x1080（驱动内部实际锁 720P，两边还不一致），于是
#   · GNOME「显示器」里永远多一条点不动的幽灵屏；
#   · mutter 把它当 is-builtin（内置屏）优先选成主屏，桌面拼成 3840x1080，
#     接原生 Tx1 的那台只拿到没有顶栏/面板的「副屏」。
# 出厂选择（2026-11-24 定案）：**两份 dtb 都出，默认单屏**。
#   · 默认份 = BOOT_FDT_FILE 指向的 rk3568-neardi-lz120-linux-hdmi1.dtb，由 0001 补丁里
#     rk3568-neardi-lz120-linux-hdmi1.dts 编出：整份只有「#include 基础那份 + 关掉
#     route_dsi0 / dsi0 / lt8912 三个节点」。内核不注册这条输出，幽灵屏从源头消失，
#     不用任何运行态干预。板上用 fdtput 改产物等效验过（DRM 只剩 card0-HDMI-A-1、
#     lt8912 零探测、桌面正常）；源码级两份 dtb 反编译 diff 恰好只有那三行 status。
#   · 要接 Tx2：改回另一份并重启，不用重烧镜像 ——
#     sudo sed -i 's|^fdtfile=.*|fdtfile=rockchip/rk3568-neardi-lz120-linux.dtb|' /boot/armbianEnv.txt
#     第二份由本文件顶部 DTB_KEEP_EXTRA 保住，否则会被 rk35xx-chinese-desktop 的
#     DTB 过滤器当「非本板 dtb」删掉（它只保留唯一命中的那份）。
#   · 用双屏那份时，下面这个 hook 把主屏和原点 (0,0) 换成原生 HDMI-1、桥那路挪到右边，
#     两路都保持点亮；单屏那份下它按 drm_status 检查自然早退（DSI-1 不存在 → 不动布局）。
#     只想停掉本逻辑：/etc/default/lz120-display 写 LZ120_NATIVE_HDMI_PRIMARY=0。
# ⚠️ 别在**运行期**关 DSI（xrandr --off、GNOME 显示器设置里关掉都一样）：GetCurrentState 里
#   DSI-1 确实没了 is-current，但 /sys/kernel/debug/dri/0/state 里它仍挂着 video_port1，
#   软硬状态分叉，gnome-shell 从此刻起持续刷 `Page flip failed: drmModeAtomicCommit:
#   Invalid argument`，两台显示器全黑、用户会话掉线（2026-11-23 01:57 板上复现）。
#   要单屏就换 dtb，别碰运行态。
# （历史误判留档，2026-11-24 已推翻，别据此再否掉 dtb 方案）当年换 dtb 后「屏上只有开机
#   log、过会无信号」并不是 DSI 从设备树消失导致的：单屏时 mutter 的游标同样压在 vp0 上，
#   被内核拒的还是下面那笔原子提交，根因是 cursor-win-id —— 修好之后单屏 dtb 实测正常。
# 2026-11-24 板上定位结论（207 板，冷启动可稳定复现，别再重复走这些弯路）：
#   · 根因是内核把 mutter 的原子提交拒了，与布局无关：厂商 dts 把 vp0/vp1 的 cursor-win-id
#     设成 CLUSTER0/CLUSTER1，而 rk3568 的 cluster 窗在驱动里挂
#     format_modifiers_afbc_no_linear_mode（只有 AFBC、不含 DRM_FORMAT_MOD_LINEAR）；GNOME 的
#     光标缓冲是 GBM 分配的 linear AR24，于是 drm_atomic_check_only 报
#     "[PLANE:75:Cluster0-win0] invalid pixel format AR24, modifier 0x0" —— mutter 把
#     「CRTC + 主平面 + 游标」打包成一笔 drmModeAtomicCommit，游标把整笔带崩，主平面
#     Smart0-win0 也没附上，表现就是 crtc[91] enable=1 而 plane_mask=0。vp1 那笔不含游标，
#     照常提交，所以症状固定成「Tx2 有桌面、Tx1 无信号、看不见光标」。
#   · 修法在设备树，不在本 hook：0001-lz120-dts.patch 里两个 cursor-win-id 换成
#     ESMART0/ESMART1（esmart 窗的 formats_for_rk356x_esmart 含 ARGB8888、format_modifiers
#     含 LINEAR）。换完实测 dmesg 报 "Esmart0/Esmart1-win0 as cursor plane for vp0/vp1"、
#     两路 plane_mask 分别 1/4 且 fb 都由 gnome-shell 分配、Page flip failed 归零、双屏同出
#     画面，主从也终于能按本 hook 落成 Tx1 主屏。主平面仍取 Smart0/Smart1，不受影响。
#   · 取证口径纠正（本板两次空抓就是这么来的）：这颗内核没开 CONFIG_DRM_USE_DYNAMIC_DEBUG，
#     /sys/module/drm/parameters/debug 确实有效，但 6.1 的位图是 DRM_UT_KMS=0x04、
#     DRM_UT_ATOMIC=0x10 —— 写 516（0x204）一行输出都不会有，要写 0xff。而且必须在 mutter
#     首次提交之前打开：提交内容与 mutter 缓存一致时它直接跳过、不再下发内核，所以事后重放
#     ApplyMonitorsConfig 抓不到任何 atomic 日志（D-Bus 照样返回成功、serial 都不变）。
#   · 内核与硬件通路本身没问题：停掉 gdm、把 fbcon 从帧缓冲解绑后，modetest 在同一进程里
#     同时给 178@91（原生 HDMI/vp0）和 196@131（DSI→LT8912/vp1）设 1920x1080-60，
#     两次 "setting mode" 之后没有任何 "failed to set mode"，平面分别是 mask 1 和 4。
#   · 连接器 possible crtcs 是 HDMI=0x1、DSI=0x2，管线映射严格一一对应，不存在选错 CRTC。
#     ⇒ 不要用「回退出厂布局再提交交换布局」这种强制重提交去救，实测只会把画面搞到两路全黑。
#   · 根因修好之前，唯一能同时恢复两路的手段是让 mutter 重做整套 KMS 状态：`chvt <别的VT>`
#     再 `chvt <会话VT>`（等价会话 suspend/resume，代价约 1 秒控制台闪烁）；现在不需要了。
#   · /sys/kernel/debug/dri/0/state 的 plane_mask 与肉眼不完全对应（报 mask=1 时 Tx1 仍可
#     能是黑的，因为那块平面属于 [fbcon]），所以健康判定要连 fb 归属一起看：先从 state 里
#     取 plane 的 fb id，再对 /sys/kernel/debug/dri/0/framebuffer 的 "allocated by" 看是不是
#     gnome-shell。同理 GetCurrentState 里 HDMI-1 有 is-current 也不代表它真的点亮，本 hook
#     的「布局稳定」只表示 D-Bus 层面成立。
#   · GNOME 50 的 DisplayConfig 没有 SetPowerSaveMode，`~/.config/monitors.xml` 会被 mutter
#     完全忽略（桥那路 EDID 0 字节、vendor/product/serial 全 unknown，身份无法持久化）。
#   · 顺带记一笔：gnome-shell 一直刷 "Failed to make thread 'KMS thread' high priority
#     scheduled: org.freedesktop.RealtimeKit1 does not exist"，镜像里没装 rtkit，与黑屏无关。
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
# （DSI-1 不存在 = 出厂默认的单屏 dtb rk3568-neardi-lz120-linux-hdmi1.dtb，本来就该跳过）
[ "$(drm_status HDMI-A-1)" = "connected" ] || exit 0
[ "$(drm_status DSI-1)" = "connected" ] || { log "没有 DSI-1（单屏 dtb），布局不动"; exit 0; }

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

# ── 本地追加 4：CAN 刷屏压掉（接口保留）──────────────────────────────────────
# 现象：dmesg 反复刷
#   rk3568_can fe570000.can can0: rk3568_can_get_berr_counter RX_ERR_CNT=0x00000000, TX_ERR_CNT=0x00000000
# 根因：drivers/net/can/rockchip/rk3568_can.c:339 那句是 netdev_dbg，而出厂内核默认
#   给这个 call site 打开了 dyndbg（dynamic_debug/control 里状态是 =p；全内核共 73 个点
#   开着，imx415/can_dev/mac80211 都在内，跟我们的任何改动无关）。can0/can1 即便 DOWN、
#   总线上一个设备都没有，只要有进程做 netlink 接口 dump（NetworkManager、系统监视器
#   一类，实测约 8s 一次）就各带一行，且计数恒为 0 —— 纯噪声，不是故障。
# 修法实测：echo 'file drivers/net/can/rockchip/rk3568_can.c -p' > /sys/kernel/debug/dynamic_debug/control
#   之后再 ip -details link show can0/can1，日志计数 100 → 100，一行都不再增长。
# 为什么写进 modprobe 而不是 systemd unit：6.1.172 的 rk3568_can 是模块，且**没有**
#   dyndbg 模块参数（/sys/module/rk3568_can/parameters 整个目录不存在），所以只能
#   "加载之后"把这条 call site 关掉；install 钩子天生就挂在这个时机上，比多一个 unit 轻。
#   本板 /proc/cmdline 没有 initrd= 参数（无 initrd），模块一定在真根上由 modprobe 加载，
#   install 钩子必然执行到。CAN 功能本身不受影响，只是少了调试打印。
function post_family_tweaks__lz120_can_quiet() {
	[[ "${BRANCH}" == "vendor" ]] || return 0
	[[ -d "${SDCARD:-}" ]] || { display_alert "Extension: ${BOARD}" "SDCARD 不可用，跳过 CAN 静默" "warn"; return 0; }

	mkdir -p "${SDCARD}/etc/modprobe.d"
	cat >"${SDCARD}/etc/modprobe.d/99-lz120-can-quiet.conf" <<'LZCAN'
# rk3568_can 的 rk3568_can_get_berr_counter 是 netdev_dbg，出厂内核默认把这个
# call site 的 dyndbg 打开（=p）。can0/can1 即使 DOWN，netlink 接口 dump 也会
# 反复带出 RX_ERR_CNT/TX_ERR_CNT 两行（计数恒为 0，总线是干净的）。
# 该模块在 6.1.172 里没有 dyndbg 模块参数，只能在加载完成后关掉这条 call site。
# 只压日志，CAN 功能与接口都不动；依据见 neardi-lz120.csc「本地追加 4」。
install rk3568_can /sbin/modprobe --ignore-install rk3568_can $OPTS; echo 'file drivers/net/can/rockchip/rk3568_can.c -p' > /sys/kernel/debug/dynamic_debug/control 2>/dev/null || true
LZCAN
	chmod 644 "${SDCARD}/etc/modprobe.d/99-lz120-can-quiet.conf"

	display_alert "Extension: ${BOARD}" "CAN 调试打印已压掉（/etc/modprobe.d/99-lz120-can-quiet.conf，接口保留）" "info"
	return 0
}

# ── 本地追加 5：RTL8852BS 蓝牙 attach ────────────────────────────────────────
# 症状：GNOME 蓝牙开关点了打不开。根因不在桌面，而是压根没有适配器：
#   · 模组 = RTL8852BS（SDIO 0x024c:0xb852），WiFi 由内核 rtl8852bs 驱动带起，正常；
#   · 蓝牙在 &uart1（板上 /dev/ttyS1），设备树只有厂商的 bluetooth-platdata 胶水节点
#     （提供 reset/wake/RTS 三个 GPIO），**没有** bluetooth 子节点，内核不会自动 attach；
#   · 内核 hci_uart 注册的协议里没有 Realtek UART（这板是 H4/BCSP/3WIRE/Intel/Broadcom/
#     QCA/AG6XX/AIC），bluez hciattach 没有 realtek 类型、bookworm 的 btattach 也不认，
#     btrtl.ko 认识的 8852 只有 USB 的 rtl8852cu；
#   · 拿纯 H4 手工 attach 能建出 hci0，但 RX bytes:0、
#     "Bluetooth: hci0: command 0x1003 tx timeout / Opcode 0x1003 failed: -110"
#     —— 芯片在等 Realtek 自己的 patchram 下载，H4 走不通。
# 厂商做法：external/rkwifibt/scripts/wifibt-init.sh 的 start_bt_rtk_uart()：
#     rtk_hciattach -n -s 115200 <tty> rtk_h5
# 板上实测（2026-11-24，源码取自 rkwifibt/tools/rtk_hciattach，4 个 .c 零外部依赖）：
#     跑起来即 hci0 UP RUNNING PSCAN ISCAN，BD 34:7D:E4:BF:F5:37（与 wlan0 连号），
#     bluetoothctl show 出 Controller 且 Powered: yes，scan on 正常启动，
#     pipewire 的 A2DP source/sink endpoint 全部注册。
# ⚠️ attach 之前必须做一次断电重上电（rfkill block bluetooth → 等 2s → unblock），否则
#   H5 同步握手没人应答：连打三行 "OP_H5_SYNC Transmission timeout" →
#   "Retransmission exhausts" → 退出码 1；systemd 的 on-failure 每一轮都是同样结局，
#   服务显示 active 而 /sys/class/bluetooth 始终为空 —— 这正是本 hook 第一版在板上
#   「手工跑通、服务跑不通」的差值。同一枚二进制、同一条命令行，差别只在前面有没有
#   那次 block/unblock。厂商脚本里对应的就是 bt_reset 那一步。
#   补进 lz120-bt-attach.sh 后冷启动实测两次：uptime 1 分钟即 hci0 到位、
#   Powered: yes、开机日志一行 Started、无超时无重启计数。
# ⚠️ 一次 attach 不够，脚本必须常驻看护（2026-11-24「重启后音箱没连上」追出来的第二条）：
#   patchram 是下载到芯片 RAM 的，**掉电即失效**，而 UI 的蓝牙开关、rfkill block/unblock、
#   suspend 回来走的都是 bt_rfkill 的断电重上电。之后 hci0 这个名字还挂着（tty 没关、
#   设备没注销），但芯片已经回裸片状态，任何 HCI 命令都不回：
#     hciconfig hci0 up     → Can't init device hci0: Connection timed out (110)
#     bluetoothctl power on → org.bluez.Error.Failed，Powered 恒为 no
#     bluetoothctl connect  → org.bluez.Error.NotReady br-connection-adapter-not-powered
#   一次性 attach 的服务在这条路径上完全不动作：进程活着（Restart=on-failure 不触发）、
#   hci0 又「存在」，所以「开机能连、UI 关开一次之后永远连不上」是必然结果。
#   现在 lz120-bt-attach.sh = 拉起 + 看门狗：开机 unblock+attach；之后每 10s 复查
#   ① soft-block 期间一律不动（用户自己关的，别抢开关）② block→unblock 边沿 = 芯片掉过
#   电 → 杀干净重 attach ③ hci0 没了 → 重 attach（失败退避 30s，绝不每 10s 断电一次）。
#   判活只看 hci0 存在与否、不看 attach 进程在不在：一枚抢不到 tty 的短命子进程（现场
#   调试留下的孤儿 rtk_hciattach）会把这个条件变成 10 秒一轮的死循环，实测踩过。
#   重 attach 成功后自己 power on（最多 3 次）：新注册的适配器 BlueZ 一律算未上电，
#   而回连守护要等 Powered: yes 才动手，不上电就变成「attach 成功但音箱不回连」。
# ⚠️ 光有 hci0 还不算「音箱自动连上」：BlueZ 只对 HID 做 auto-connect，A2DP 音频设备必须
#   有客户端主动 connect。本板 build.env 因此启用 bluetooth-autoconnect（rk-bluetooth-autoconnect
#   守护，20s 一轮扫 Trusted+Paired 补连）。两层各管各的：这层管 hci0，那层管音箱。
#   板上端到端实测：重启后 03:36:20 守护起来 → 03:36:30 桌面解阻断 → 03:36:43 attach 完成
#   + 适配器已上电 → 03:36:47 「已自动回连 28:37:13:41:93:4B (HUAWEI CM510)」，
#   开机约 47s 出声；UI 关开一次（rfkill block→unblock）后 12s 内同样自动回连。
#   ⚠️ 开机时 bt_default 的默认态就是 soft-blocked，桌面才会解开 —— 无头镜像没有谁来解，
#   所以脚本第一步显式 rfkill unblock，否则永远没有 hci0。
# 固件不缺：/lib/firmware/rtlbt/rtl8852bs_{fw,config} 由 armbian-firmware 提供，
#   工具读的是固定路径，所以只缺工具本体 + 开机 attach。
# 部署件在 userpatches/lz120-bt-attach/（二进制 + attach 脚本 + service），源码留档
#   在 userpatches/rtk-hciattach-src/（GPL-2.0+，上游 github.com/rockchip-linux/rkwifibt）。
#   为什么提交二进制：本板 build.env 不装工具链，构建期现编要么拖进 apt 安装要么引
#   gcc，收益不比 am60-sa12 已经提交 .ko 的既有做法更干净。
# ⚠️ 提交的那枚**必须是静态链接**的（2026-11-24 r27 出厂镜像上踩的：镜像里蓝牙开关还是
#   打不开，journal 里 rtk_hciattach 每轮都报
#   "/lib/aarch64-linux-gnu/libc.so.6: version GLIBC_2.42' not found"，attach 进程根本没跑
#   起来，守护于是稳定地「15s 等不到 hci0 → 重来」）。上一版入库的是厂商外部预编译件，
#   它按 Rockchip 构建机的新 glibc 链，而 noble 只有 2.39、bookworm 只有 2.36 —— 同一条
#   命令行、同一个芯片，换台主机就只是 exec 失败，而看门狗的报错只说「没等到 hci0」，
#   看不出根因。静态件（file: "statically linked"，855584 字节，md5 7050afc7…）在
#   noble/bookworm/trixie 上都不要再靠运行时 glibc，才是可以入库的那一枚。
#   重编（板上有 gcc/make，源码零外部依赖）：
#     gcc -O2 -Wall -c hciattach.c hciattach_rtk.c hciattach_h4.c rtb_fwc.c
#     gcc -static -o rtk_hciattach hciattach*.o rtb_fwc.o
#   验真：ldd 应回「不是动态可执行文件」，且 r27 镜像上实测 restart 后 journal 出现
#   "attach 完成，hci0 就位" + "适配器已上电"、ps 只剩 1 枚 rtk_hciattach。
function post_family_tweaks__lz120_bluetooth() {
	[[ "${BRANCH}" == "vendor" ]] || return 0
	[[ -d "${SDCARD:-}" ]] || { display_alert "Extension: ${BOARD}" "SDCARD 不可用，跳过蓝牙 attach 部署" "warn"; return 0; }

	local conf="${SRC}/userpatches/lz120-bt-attach"
	if [[ ! -d "${conf}" ]]; then
		# 不致命：缺部署件只影响蓝牙，镜像照样能起
		display_alert "Extension: ${BOARD}" "userpatches/lz120-bt-attach 不存在，跳过蓝牙 attach 部署" "warn"
		return 0
	fi

	for d in etc usr; do
		[[ -d "${conf}/${d}" ]] && cp -r "${conf}/${d}/." "${SDCARD}/${d}/"
	done
	chmod 755 "${SDCARD}/usr/local/sbin/rtk_hciattach" 2>/dev/null || true
	chmod 755 "${SDCARD}/usr/local/sbin/lz120-bt-attach.sh" 2>/dev/null || true
	chmod 644 "${SDCARD}/etc/systemd/system/lz120-bluetooth.service" 2>/dev/null || true

	# enable：优先 chroot systemctl，兜底直接建 wants 符号链接（与 h96s 同款做法）
	if [[ -x "${SDCARD}/bin/systemctl" ]]; then
		chroot "${SDCARD}" /bin/systemctl --no-reload enable lz120-bluetooth.service 2>/dev/null || true
	fi
	mkdir -p "${SDCARD}/etc/systemd/system/multi-user.target.wants"
	ln -sf "/etc/systemd/system/lz120-bluetooth.service" \
	       "${SDCARD}/etc/systemd/system/multi-user.target.wants/lz120-bluetooth.service"

	display_alert "Extension: ${BOARD}" "RTL8852BS 蓝牙 attach 已部署并 enable（rtk_hciattach /dev/ttyS1，开机建 hci0）" "info"
	return 0
}

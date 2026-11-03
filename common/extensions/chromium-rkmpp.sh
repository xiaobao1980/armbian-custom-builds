#
# SPDX-License-Identifier: GPL-2.0
# Armbian build framework extension
#
# chromium-rkmpp —— 只做一件事：让出厂镜像里自带的 chromium 就是 +rkmpp 硬解版
#                    （V4L2 VDA -> libv4l-rkmpp -> /dev/video-dec0 -> MPP -> VPU）
#
# =============================================================================
#  为什么是「薄」扩展（2026-11-02 重构，取代 _archive/mesa-vpu.sh）
# -----------------------------------------------------------------------------
#  上游 armbian/build 的 extensions/mesa-vpu.sh 已于 2026-05-09 删除
#  （commit 27c668343 "mesa-vpu: delete extension — fully covered by armbian-config"），
#  它剩下的职责被 armbian-configng 的 module_desktops 接管：
#    1. mesa 运行时 + vulkan 驱动 + glmark2/mesa-utils  -> configng common.yaml mid tier
#    2. panthor-gpu DT overlay                          -> configng _module_desktops_rockchip_multimedia stage 2
#    3. amazingfated PPA + pin 1001 + rockchip-multimedia-config / libv4l-rkmpp /
#       gstreamer1.0-rockchip / libwidevinecdm0         -> 同上 stage 1
#  但删除提交里明确留了一个 caveat：
#    "configng ... does not run a post-install apt-get dist-upgrade --allow-downgrades
#     to actively swap pre-installed chromium ... shipped images carry the
#     apt.armbian.com chromium."
#  → 出厂镜像的 chromium 仍是软解版（noble 上实测为 156 xtradeb），只有用户首次
#    `apt upgrade` 之后才会换。**这正是本扩展唯一存在的理由。**
#
#   ⚠️ 但「configng 已接管」只在设计上成立，本仓实测不成立：
#     `./compile.sh build` 的日志里既无 BOARDFAMILY 记录也无 module_desktops 调用痕迹，
#     rootfs 里能查到 PPA 源只是构建机 apt lists 的历史残留（实证见
#     boards/h96s/config/boards/h96-m9.csc 顶部「三条结论」第 2 条，2026-08-30）。
#     所以本扩展**不依赖** configng，自己幂等补装 PPA/pin/libv4l-rkmpp/
#     rockchip-multimedia-config；已装过就秒过。
#
#  ⚠️ panthor-gpu overlay：旧 mesa-vpu 会在 noble 上添加它。本扩展**默认不加** ——
#     加 overlay 会把 GPU 绑到 panthor 驱动上，而本扩展不做整机 dist-upgrade（见下），
#     无法保证发行版 mesa 有 panthor 用户态，反而可能让 GL 掉回 llvmpipe。
#     已验证可用的基线是 X11/panfrost（106 板 trixie 实测 glmark 正常）。
#     确实要走 Panthor 路线时显式设 CHROMIUM_RKMPP_PANTHOR=yes，并自行确认 mesa 版本。
#
#  所以本文件只保留三件事，其余全部交回给上游：
#    a) PPA 源 + 具名 pin 1002（修「同优先级 1001 时 apt 取版本号大者 → 装成软解 156」
#       的坑，187 实测复现，见常驻笔记 pitfalls.md）
#    b) rockchip-multimedia-config + libv4l-rkmpp（幂等补装；jammy 与「configng 没跑」
#       这两种情况下都得靠这里）
#    c) chromium/chromium-common/chromium-l10n 显式点名 + --allow-downgrades 安装，
#       装完用 dpkg-query 校验版本含 +rkmpp
#
#  ⚠️ 已刻意删除的旧代码（不要再加回来）：
#    · `dist-upgrade --allow-downgrades` —— 会换掉自编译 mpv 动态链接的
#      libplacebo/libass/libdav1d → 「镜像构建 success 但播放器报废」；上游自己也删了
#    · `apt-mark hold base-files` / `hold libdav1d7` —— 只为配合上一条的括号调用
#    · panthor-gpu overlay —— 默认不加（理由见上），需要时用 CHROMIUM_RKMPP_PANTHOR=yes
#    · libgl1-mesa-dri / mesa-utils / glmark2 全家桶 —— 发行版自带 mesa 即为基线
#      （configng 设计上会装，但本仓实测没跑，故不作为依赖）
#    · amd64 google-chrome / firefox 分支 —— ARM 镜像用不到
#
#  与 rkmpp-mpv.sh 的关系：**互不排斥，可同时启用**。本扩展只碰 apt 源与 chromium，
#  不做整机版本切换，因此不会影响 rkmpp-mpv 自编译的 mpv/ffmpeg-rockchip。
#  「一块板两件事都要」= 两个扩展同时写进 ENABLE_EXTENSIONS，无需额外开关。
#
#  可选环境变量：
#    CHROMIUM_RKMPP=no           显式关闭（其它发行版该扩展本来就自动跳过）
#    CHROMIUM_RKMPP_PANTHOR=yes  额外添加 panthor-gpu DT overlay（默认不加；
#                                需自行保证 mesa 用户态支持 panthor，否则 GL 掉 llvmpipe）
# =============================================================================

# 本扩展是否生效 —— 全文件唯一判定点
function _chromium_rkmpp__selected() {
	[[ "${CHROMIUM_RKMPP:-yes}" == "yes" ]] || return 1

	# 只有厂商内核带 mpp/rga 驱动；mainline 内核上装了也无法硬解
	[[ "${LINUXFAMILY:-}" =~ ^(rk35xx|rockchip-rk3588)$ && "${BRANCH:-}" == "vendor" ]] || return 1

	# PPA 的 chromium+rkmpp 只发布 jammy / noble（noble=132 / jammy=126）
	[[ "${RELEASE:-}" =~ ^(jammy|noble)$ ]] || return 1

	# 没有桌面就没有浏览器
	[[ "${BUILD_DESKTOP:-}" == "yes" ]] || return 1
	[[ "${BUILD_MINIMAL:-}" == "yes" ]] && return 1

	# arm64/armhf 才有 +rkmpp 构建
	[[ "${ARCH:-}" =~ ^(arm64|armhf)$ ]] || return 1

	return 0
}

function extension_prepare_config__chromium-rkmpp() {
	if ! _chromium_rkmpp__selected; then
		display_alert "Extension: ${EXTENSION}" \
			"skip (${RELEASE:-?}/${DESKTOP_ENVIRONMENT:-no-desktop}/${ARCH:-?}): chromium+rkmpp 只对 vendor 内核的 rk35xx/rk3588 桌面镜像 + jammy|noble 提供" "info"
		return 0
	fi

	# 预期版本（实测 PPA 索引，2026-11-02）：noble=132.0.6834.159-1~deb12u1+rkmpp ／
	# jammy=126.0.6478.182-1~deb12u1+rkmpp~j。jammy 不是 132，不要照抄文档。
	local _expect="132"
	[[ "${RELEASE}" == "jammy" ]] && _expect="126"
	display_alert "Extension: ${EXTENSION}" \
		"chromium ${_expect}+rkmpp (PPA, ${RELEASE}/${ARCH}) —— 出厂即硬解，不依赖用户 apt upgrade" "info"

	# panthor-gpu overlay：默认不加（理由见文件头）。显式开启时只做「加 overlay」，
	# 不负责换 mesa —— 请自行确认发行版 mesa 已支持 panthor，否则 GL 会退到 llvmpipe。
	if [[ "${CHROMIUM_RKMPP_PANTHOR:-no}" == "yes" ]]; then
		if [[ "${LINUXFAMILY}" =~ ^(rockchip-rk3588|rk35xx)$ && "${BRANCH}" == "vendor" ]]; then
			DEFAULT_OVERLAYS="${DEFAULT_OVERLAYS:+${DEFAULT_OVERLAYS} }panthor-gpu"
			display_alert "Extension: ${EXTENSION}" "panthor-gpu overlay 已按 CHROMIUM_RKMPP_PANTHOR=yes 添加" "warn"
		fi
	fi
	return 0
}

# PPA 源是否已在镜像里（configng 可能已经加过；noble 用 deb822 .sources，jammy 用 .list）
function _chromium_rkmpp__ppa_present() {
	compgen -G "${SDCARD}/etc/apt/sources.list.d/*liujianfeng1994*rockchip*" >/dev/null 2>&1 && return 0
	grep -qs "liujianfeng1994/rockchip-multimedia" "${SDCARD}/etc/apt/sources.list" 2>/dev/null && return 0
	return 1
}

function post_armbian_repo_customize_image__chromium-rkmpp() {
	_chromium_rkmpp__selected || return 0

	# ---- 1. PPA 源（幂等）----
	# configng 已在 noble 上加了源；jammy 覆盖不到，这里补。加不上不中止构建，
	# 但要留 warn —— 没有源就拿不到 +rkmpp 的 chromium，本扩展等于白跑。
	if _chromium_rkmpp__ppa_present; then
		display_alert "rockchip-multimedia PPA already present (configng), reusing" "${EXTENSION}" "info"
	elif do_with_retries 3 chroot_sdcard add-apt-repository ppa:liujianfeng1994/rockchip-multimedia --yes --no-update; then
		display_alert "Added amazingfated rockchip-multimedia PPA" "${EXTENSION}" "info"
	else
		display_alert "add-apt-repository failed: chromium 将保持发行版软解版（无网页硬解）" "${EXTENSION}" "warn"
		return 0
	fi

	# ---- 2. pin：通配 1001（与 configng 一致）+ chromium 具名 1002 ----
	# 1002 是硬解能落地的关键：armbian 自己的 noble 源同样提供 chromium（156 xtradeb，
	# 无 rkmpp），两边都是 1001 时 apt 按「版本号更大」取胜 → 装成 156 软解版。
	# apt 规则「更具体的 pin 优先」→ 具名 stanza 的 1002 稳压通配 1001。
	# 若日后想跟回发行版 chromium（会失去硬解），删掉第二个文件即可。
	cat <<- EOF > "${SDCARD}"/etc/apt/preferences.d/amazingfated-rk3588-rockchip-multimedia-pin
		Package: *
		Pin: release o=LP-PPA-liujianfeng1994-rockchip-multimedia
		Pin-Priority: 1001
	EOF
	cat <<- EOF > "${SDCARD}"/etc/apt/preferences.d/amazingfated-chromium-rkmpp-pin
		Package: chromium chromium-common chromium-l10n
		Pin: release o=LP-PPA-liujianfeng1994-rockchip-multimedia
		Pin-Priority: 1002
	EOF
	display_alert "Pinned PPA multimedia stack at 1001, chromium stack at 1002" "${EXTENSION}" "info"

	do_with_retries 3 chroot_sdcard_apt_get_update

	# ---- 3. libv4l 必须在 rockchip-multimedia-config 之前（包名随 time_t 迁移变化）----
	local v4l_pkg="libv4l-0"
	case "${RELEASE}" in
		noble | oracular | plucky | questing | resolute) v4l_pkg="libv4l-0t64" ;;
	esac
	do_with_retries 3 chroot_sdcard_apt_get_install "${v4l_pkg}" \
		|| display_alert "install ${v4l_pkg} failed; rockchip-multimedia-config may fail too" "${EXTENSION}" "warn"

	# ---- 4. chromium 硬解所需的最小集合（幂等；configng 装过就秒过）----
	do_with_retries 3 chroot_sdcard_apt_get_install "rockchip-multimedia-config" "libv4l-rkmpp" \
		|| display_alert "rockchip-multimedia-config / libv4l-rkmpp install failed: chromium 可能启动即崩或无法建 /dev/video-dec0" "${EXTENSION}" "warn"

	# ---- 5. 可选件：只装 PPA 真的提供候选的（LC_ALL=C 避免中文 locale 把
	#         「候选：」解析歪 —— 这个坑踩过）----
	local -a opt_pkgs=()
	local p
	for p in gstreamer1.0-rockchip1 libwidevinecdm0; do
		if LC_ALL=C chroot_sdcard apt-cache policy "${p}" 2>/dev/null | grep -q "LP-PPA-liujianfeng1994"; then
			opt_pkgs+=("${p}")
		fi
	done
	if [[ ${#opt_pkgs[@]} -gt 0 ]]; then
		do_with_retries 2 chroot_sdcard_apt_get_install "${opt_pkgs[@]}" \
			|| display_alert "optional PPA packages not all installed (${opt_pkgs[*]})" "${EXTENSION}" "warn"
	fi

	# ---- 6. chromium 栈：显式点名 + 允许降级 ----
	# 只写 `chromium` 时依赖解析可能装成混合版本；若桌面档已预装 156，降级必须显式允许。
	local -a chromium_pkgs=("chromium" "chromium-common" "chromium-l10n")
	display_alert "Installing browser (chromium rkmpp stack: ${chromium_pkgs[*]})" "${EXTENSION}" "info"
	if ! do_with_retries 3 chroot_sdcard_apt_get --allow-downgrades \
		-o Dpkg::Options::="--force-confold" install "${chromium_pkgs[@]}"; then
		# 兜底：宁可软解也不能没浏览器
		display_alert "chromium rkmpp stack install failed; falling back to plain 'chromium' (software decode)" "${EXTENSION}" "warn"
		do_with_retries 3 chroot_sdcard_apt_get_install "chromium" || return 0
	fi

	# ---- 6.5 pak 资源完整性（dpkg 降级 file-takeover 陷阱，187 实测踩中）----
	# 桌面档预装的 chromium-common 156(xtradeb) 提供 /usr/lib/chromium/*.pak。降级装
	# chromium 132 时 dpkg 判定这些路径「已被 chromium-common(156) 占用」而跳过写入
	# （日志 Replaced by files in installed package chromium-common ...），紧接着
	# chromium-common 156->132 又把它们删掉（132 的 common 包不含 pak）。
	# 净结果：浏览器能开、网页正常，但 chrome://settings 等 webui 把内部 JSON 当文本
	# 渲染、图标全缺，且 dpkg 不报任何错（--verify 也是干净的）。
	# 这里做幂等校验，缺就重装主包让 pak 落位（此时 156 已被 132 替换，无归属冲突）。
	local _pak_missing=no _pak
	for _pak in resources.pak chrome_100_percent.pak chrome_200_percent.pak; do
		[[ -f "${SDCARD}/usr/lib/chromium/${_pak}" ]] || _pak_missing=yes
	done
	[[ -f "${SDCARD}/usr/lib/chromium/locales/en-US.pak" ]] || _pak_missing=yes
	if [[ ${_pak_missing} == yes ]]; then
		display_alert "chromium 资源包缺失（dpkg 降级 file-takeover 陷阱），重装主包补齐" "${EXTENSION}" "warn"
		do_with_retries 3 chroot_sdcard_apt_get --reinstall \
			-o Dpkg::Options::="--force-confold" install "chromium" \
			|| display_alert "chromium --reinstall 失败：chrome://settings 等内部页面会显示原始 JSON" "${EXTENSION}" "warn"
	fi
	# 二次确认：重装后仍缺则明确留痕，避免又变成「看起来装好了」
	for _pak in resources.pak chrome_100_percent.pak; do
		[[ -f "${SDCARD}/usr/lib/chromium/${_pak}" ]] \
			|| display_alert "chromium 仍缺 ${_pak}：webui/图标会异常（检查 PPA 包是否完整）" "${EXTENSION}" "warn"
	done

	# ---- 7. 验收：装到的必须是 +rkmpp 版 ----
	# 装成发行版版本时镜像静默退化为软解，只在播 4K 时表现为 CPU 打满 —— 必须留痕。
	# ⚠ 不要写 chroot_sdcard dpkg-query -W -f='${Version}' chromium：
	# chroot_sdcard 把参数拼成字符串再交给 chroot 内的 bash **重新解析**，单引号在拼接
	# 阶段已被吃掉，于是 ${Version} 在 chroot 里被展开成空 → dpkg-query 报
	# `error in show format: may not be empty string`，版本号永远取不到（2026-11-03 CI 实测）。
	# 直接读 SDCARD 的 dpkg status，零引号/零 chroot 风险。
	local chromium_ver=""
	chromium_ver="$(awk '
		/^Package: / { pkg = ($2 == "chromium") ? 1 : 0; ins = 0; next }
		pkg && /^Status: / { ins = ($0 ~ /install ok installed/) ? 1 : 0; next }
		pkg && ins && /^Version: / { sub(/^Version: /, ""); print; exit }
	' "${SDCARD}/var/lib/dpkg/status" 2>/dev/null || true)"
	if [[ "${chromium_ver}" == *rkmpp* ]]; then
		display_alert "chromium ${chromium_ver} installed (+rkmpp): V4L2 VDA -> libv4l-rkmpp -> MPP" "${EXTENSION}" "info"
	else
		display_alert "chromium ${chromium_ver:-?} is NOT the +rkmpp build: web video falls back to FFmpegVideoDecoder (software). 检查 PPA 是否提供 ${RELEASE}/${ARCH} 的包、以及 1002 pin 是否生效" "${EXTENSION}" "warn"
	fi

	return 0
}

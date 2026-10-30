#!/bin/bash
# ============================================================
# rk35xx-chinese-desktop.sh — RK35xx 中文桌面定制（chroot 内执行器）
#
# 由 common/extensions/rk35xx-chinese-desktop.sh 在构建期
# chroot 内以 `bash /usr/local/sbin/rk35xx-chinese-desktop.sh` 调用。
# 运行根 = chroot 的 /（构建期镜像根），不依赖宿主机。
#
# 处理四件事（全部按【发行版】/【桌面环境】自适应，不写死板卡）：
#   1) root 密码 + 首次启动自动创建普通用户      → rk_cn_setup_user
#   2) Locale / 时区 / 中文字体                   → rk_cn_setup_locale_tz_fonts
#   3) 输入法（雾凇拼音 rime-ice）：
#        GNOME / Wayland → ibus-rime              → rk_cn_ime_ibus
#        X11 / XFCE 等   → fcitx5-rime            → rk_cn_ime_fcitx5
#   4) Chromium 中文界面 + 中文化策略数据          → rk_cn_setup_chromium_zh
#
# 板级差异一律由 extension 通过环境变量传入（多板编译互不影响的基石：
# 本脚本只读这些变量、只写当前镜像根，绝不触碰宿主或其它板卡）：
#
#   RK_CN_BUILD_DESKTOP  yes|no                      是否桌面镜像
#   RK_CN_DESKTOP_ENV    gnome|xfce|mate|cinnamon... 桌面环境名（决定输入法框架）
#   RK_CN_IME            auto|fcitx5|ibus            强制输入法框架（默认 auto）
#   RK_CN_USER           普通用户名（默认 xiaobao）
#   RK_CN_USER_PASS      普通用户密码（默认 123456）
#   RK_CN_ROOT_PASS      root 密码（默认 123456789）
#   RK_CN_TZ             时区（默认 Asia/Shanghai）
#   RK_CN_LOCALES_ALL    1|0  Debian 上是否装 locales-all（默认 1）
#   RK_CN_RIME_MIRROR    可选：优先使用的 rime-ice 镜像前缀（留空走内置多镜像回退）
# ============================================================

# 故意不使用 set -e：单步失败不应让整段定制中断（与已验证实现保持一致）。
# 关键步骤各自做显式断言与告警。
set -u

RK_CN_BUILD_DESKTOP="${RK_CN_BUILD_DESKTOP:-no}"
RK_CN_DESKTOP_ENV="${RK_CN_DESKTOP_ENV:-xfce}"
RK_CN_IME="${RK_CN_IME:-auto}"
RK_CN_USER="${RK_CN_USER:-xiaobao}"
RK_CN_USER_PASS="${RK_CN_USER_PASS:-123456}"
RK_CN_ROOT_PASS="${RK_CN_ROOT_PASS:-123456789}"
RK_CN_TZ="${RK_CN_TZ:-Asia/Shanghai}"
RK_CN_LOCALES_ALL="${RK_CN_LOCALES_ALL:-1}"

log() { echo ">>> [CN-Desktop] $*"; }
have_pkg() { apt-cache show "$1" >/dev/null 2>&1; }

# ============================================================
# 0. chroot 内 DNS 自检（联网装包前必须）
# ============================================================
# 真根因（多次实锤）：rootfs 缓存命中时 /etc/resolv.conf 仍是宿主
# systemd-resolved 桩文件（nameserver 127.0.0.53），chroot 内无进程监听
# 该地址 → 域名解析全灭。表现极具迷惑性：apt 缓存里已有的包照装，
# 唯独需现下载的包（ibus-rime 及其依赖）全灭，像“网络时好时坏”。
rk_cn_ensure_dns() {
	local probe="deb.debian.org"
	if getent hosts "${probe}" >/dev/null 2>&1; then
		log "DNS 自检: ${probe} 可解析，无需干预"
		return 0
	fi
	log "DNS 自检: ✗ ${probe} 解析失败，顶上构建期公共 DNS"
	printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 223.5.5.5\noptions timeout:3 attempts:2\n' \
		>/tmp/.rk-cn-resolv.conf 2>/dev/null || return 1
	if mount --bind /tmp/.rk-cn-resolv.conf /etc/resolv.conf 2>/dev/null; then
		log "DNS 自检: 已 bind-mount 临时 resolv.conf（不写穿底层）"
	elif cp /tmp/.rk-cn-resolv.conf /etc/resolv.conf 2>/dev/null; then
		log "DNS 自检: 已覆盖 /etc/resolv.conf"
	else
		log "DNS 自检: ✗ 无法修复 /etc/resolv.conf"
		return 1
	fi
	getent hosts "${probe}" >/dev/null 2>&1 && log "DNS 自检: ✓ 复验通过" || log "DNS 自检: ✗ 复验仍失败"
}

# 发行版判定（Ubuntu 有 PPA；Debian 无）
rk_cn_os_id() { ( . /etc/os-release 2>/dev/null; printf '%s' "${ID:-}" ); }
rk_cn_is_ubuntu() {
	[ "$(rk_cn_os_id)" = "ubuntu" ] && return 0
	case "${RELEASE:-}" in noble|jammy|focal|oracular|plucky|questing) return 0 ;; esac
	return 1
}

# ============================================================
# 1. root 密码 + 首次启动自动创建普通用户
# ============================================================
# 设计要点：
#   · 构建期就设好 root 密码（镜像烧录后即可 root 登录/串口调试）。
#   · 普通用户延迟到【首次启动】创建：镜像在不同板卡/不同镜像间复用 uid 1000
#     时不会因构建期残留而冲突；也便于现场统一重置。
#   · 用 rc.local（+ rc-local.service）调用，幂等（done 标记）。
#   · 必须早于显示管理器启动，否则自动登录找不到用户（见 rk_cn_autologin_order）。
rk_cn_setup_user() {
	log "设置 root 密码"
	echo "root:${RK_CN_ROOT_PASS}" | chpasswd 2>/dev/null || log "警告: root 密码设置失败"

	# 清掉 Armbian 首次登录向导标记，避免与我们的首启脚本抢用户创建
	rm -f /root/.not_logged_in_yet /root/.not_logged_in_yet~ 2>/dev/null || true
	rm -f /var/lib/armbian/firstrun 2>/dev/null || true

	log "部署首次启动建用户脚本（用户=${RK_CN_USER}）"
	mkdir -p /usr/local/sbin /var/lib
	cat > /usr/local/sbin/armbian-firstboot-user.sh <<EOF
#!/bin/bash
# 由 rk35xx-chinese-desktop 部署：首次启动创建普通用户并设密码（幂等）
[ -f /var/lib/armbian-firstboot-user.done ] && exit 0

userdel -r ${RK_CN_USER} 2>/dev/null || true
rm -rf /home/${RK_CN_USER} 2>/dev/null || true
groupadd -g 1000 ${RK_CN_USER} 2>/dev/null || true
useradd -m -s /bin/bash -u 1000 -g 1000 \\
    -G sudo,adm,plugdev,audio,video,netdev,dialout,cdrom,floppy,tape ${RK_CN_USER} 2>/dev/null || true
echo "root:${RK_CN_ROOT_PASS}" | chpasswd 2>/dev/null || true
echo "${RK_CN_USER}:${RK_CN_USER_PASS}" | chpasswd 2>/dev/null || true
chown -R ${RK_CN_USER}:${RK_CN_USER} /home/${RK_CN_USER} 2>/dev/null || true
chmod 755 /home/${RK_CN_USER} 2>/dev/null || true

# 无 RTC 电池板卡每次上电时间归零：首启立即校时（失败不阻断）
command -v ntpdate >/dev/null 2>&1 && ntpdate -u cn.pool.ntp.org >/dev/null 2>&1 || true

touch /var/lib/armbian-firstboot-user.done
EOF
	chmod 755 /usr/local/sbin/armbian-firstboot-user.sh

	# rc.local 调用（Armbian 多数镜像默认无 rc.local，这里补齐）
	if [ ! -f /etc/rc.local ]; then
		cat > /etc/rc.local <<'RCEOF'
#!/bin/bash
[ -x /usr/local/sbin/armbian-firstboot-user.sh ] && /usr/local/sbin/armbian-firstboot-user.sh
exit 0
RCEOF
		chmod 755 /etc/rc.local
	fi

	# rc-local.service（chroot 内 systemctl 不可用，直接建 wants 链接）
	if [ ! -f /etc/systemd/system/rc-local.service ]; then
		cat > /etc/systemd/system/rc-local.service <<'SVC'
[Unit]
Description=/etc/rc.local Compatibility
After=network.target

[Service]
Type=oneshot
ExecStart=/etc/rc.local
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC
	fi
	mkdir -p /etc/systemd/system/multi-user.target.wants
	ln -sf /etc/systemd/system/rc-local.service \
		/etc/systemd/system/multi-user.target.wants/rc-local.service 2>/dev/null || true
}

# 保证建用户先于显示管理器（自动登录依赖用户存在）
rk_cn_autologin_order() {
	[ "${RK_CN_BUILD_DESKTOP}" = "yes" ] || return 0
	mkdir -p /etc/systemd/system/display-manager.service.d
	cat > /etc/systemd/system/display-manager.service.d/10-after-firstboot-user.conf <<'EOF'
[Unit]
# 自动登录依赖首次启动脚本建好的用户，必须等它跑完再起 DM
After=rc-local.service
After=armbian-firstrun.service
Requires=rc-local.service
EOF
}

# ============================================================
# 2. Locale / 时区 / 中文字体
# ============================================================
rk_cn_setup_locale_tz_fonts() {
	export DEBIAN_FRONTEND=noninteractive
	rk_cn_ensure_dns

	log "写入 locale 配置（zh_CN.UTF-8）"
	cat > /etc/default/locale <<'EOF'
LANG=zh_CN.UTF-8
LANGUAGE=zh_CN:zh
LC_ALL=zh_CN.UTF-8
EOF
	# systemd / GDM 实际读 /etc/locale.conf，缺失会导致会话回落英文
	cat > /etc/locale.conf <<'EOF'
LANG=zh_CN.UTF-8
LANGUAGE=zh_CN:zh
EOF
	# locale.gen 保留英文，便于日志/排障
	{
		echo 'zh_CN.UTF-8 UTF-8'
		echo 'zh_CN.GBK GBK'
		echo 'zh_CN GB2312'
		echo 'en_US.UTF-8 UTF-8'
	} > /etc/locale.gen
	locale-gen >/dev/null 2>&1 || log "警告: locale-gen 失败"

	log "设置时区 ${RK_CN_TZ}"
	echo "${RK_CN_TZ}" > /etc/timezone
	ln -sf "/usr/share/zoneinfo/${RK_CN_TZ}" /etc/localtime 2>/dev/null || true

	# 中国 NTP 源：chrony（Armbian 默认）优先，无则 timesyncd 兜底
	if [ -d /etc/chrony ]; then
		mkdir -p /etc/chrony/sources.d /etc/chrony/conf.d
		cat > /etc/chrony/sources.d/99-china-ntp.source <<'EOF'
server ntp.aliyun.com iburst prefer
server ntp1.aliyun.com iburst
server ntp.tencent.com iburst
server cn.pool.ntp.org iburst
server ntp.ntsc.ac.cn iburst
EOF
		cat > /etc/chrony/conf.d/99-china-ntp.conf <<'EOF'
makestep 1.0 3
EOF
	fi
	mkdir -p /etc/systemd
	cat > /etc/systemd/timesyncd.conf <<'EOF'
[Time]
NTP=ntp.aliyun.com ntp1.aliyun.com ntp.tencent.com cn.pool.ntp.org
FallbackNTP=ntp.ntsc.ac.cn time.apple.com
EOF
	if [ ! -d /etc/chrony ]; then
		systemctl enable systemd-timesyncd >/dev/null 2>&1 || true
	fi

	log "安装中文语言包与中文字体"
	if rk_cn_is_ubuntu; then
		apt-get install -y -qq language-pack-zh-hans language-pack-zh-hans-base \
			language-pack-gnome-zh-hans >/dev/null 2>&1 \
			|| log "提示: language-pack-zh-hans 不可用（不影响字体/locale）"
	elif [ "${RK_CN_LOCALES_ALL}" = "1" ]; then
		apt-get install -y -qq locales-all >/dev/null 2>&1 \
			|| log "提示: locales-all 装不上，已由 locale-gen 兜底"
	fi
	# zh_CN.UTF-8 兜底生成
	if ! locale -a 2>/dev/null | grep -qiE '^zh_CN\.(utf8|UTF-8)'; then
		grep -q '^zh_CN.UTF-8' /etc/locale.gen 2>/dev/null || echo 'zh_CN.UTF-8 UTF-8' >>/etc/locale.gen
		locale-gen >/dev/null 2>&1 || true
	fi

	apt-get install -y -qq \
		fonts-noto-cjk fonts-noto-cjk-extra \
		fonts-wqy-zenhei fonts-wqy-microhei \
		fonts-arphic-uming fonts-arphic-ukai >/dev/null 2>&1 \
		|| log "警告: 部分中文字体安装失败"
	command -v fc-cache >/dev/null 2>&1 && fc-cache -f >/dev/null 2>&1 || true
}

# ============================================================
# 3. 输入法 — 雾凇拼音 rime-ice
# ============================================================
# 拉取 rime-ice：git 多镜像回退 + zip 兜底。成功返回 0 并留在 $1（默认 /tmp/rime-ice）。
rk_cn_fetch_rime_ice() {
	local dest="${1:-/tmp/rime-ice}"
	apt-get install -y -qq git unzip wget >/dev/null 2>&1 || true
	rm -rf "${dest}"
	local urls=(
		"https://gitclone.com/github.com/iDvel/rime-ice.git"
		"https://ghproxy.net/https://github.com/iDvel/rime-ice.git"
		"https://gh-proxy.com/https://github.com/iDvel/rime-ice.git"
		"https://github.com/iDvel/rime-ice.git"
	)
	[ -n "${RK_CN_RIME_MIRROR:-}" ] && urls=("${RK_CN_RIME_MIRROR%/}/iDvel/rime-ice.git" "${urls[@]}")
	local u
	for u in "${urls[@]}"; do
		if timeout 300 git clone --depth=1 "${u}" "${dest}" >/dev/null 2>&1; then
			[ -f "${dest}/default.yaml" ] && return 0
		fi
		rm -rf "${dest}"
	done
	# zip 兜底
	local z
	for z in \
		"https://ghproxy.net/https://github.com/iDvel/rime-ice/archive/refs/heads/main.zip" \
		"https://gh-proxy.com/https://github.com/iDvel/rime-ice/archive/refs/heads/main.zip" \
		"https://github.com/iDvel/rime-ice/archive/refs/heads/main.zip"; do
		if wget -q --timeout=60 "${z}" -O /tmp/rime-ice.zip 2>/dev/null \
			&& unzip -q /tmp/rime-ice.zip -d /tmp/ 2>/dev/null \
			&& mv /tmp/rime-ice-main "${dest}" 2>/dev/null; then
			rm -f /tmp/rime-ice.zip
			[ -f "${dest}/default.yaml" ] && return 0
		fi
		rm -f /tmp/rime-ice.zip
	done
	return 1
}

# ---------- 3A. X11 / XFCE → fcitx5 + rime ----------
rk_cn_ime_fcitx5() {
	log "输入法：fcitx5 + rime-ice（X11 / ${RK_CN_DESKTOP_ENV}）"
	rk_cn_ensure_dns

	# 卸掉可能冲突的 ibus 系（避免两套框架抢 GTK_IM_MODULE）
	apt-get remove -y ibus ibus-libpinyin ibus-rime fcitx fcitx-bin >/dev/null 2>&1 || true

	apt-get install -y -qq --no-install-recommends \
		fcitx5 fcitx5-rime \
		fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5 \
		fcitx5-config-qt fcitx5-module-xorg fcitx5-module-wayland \
		librime-data >/dev/null 2>&1 \
		|| log "警告: fcitx5 核心包部分安装失败"

	# 全局环境变量（X11 会话）
	mkdir -p /etc/environment.d
	cat > /etc/environment.d/90-fcitx5.conf <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF
	# /etc/environment 追加（幂等，避免覆盖已有 locale 行）
	if ! grep -q '^GTK_IM_MODULE=' /etc/environment 2>/dev/null; then
		cat >> /etc/environment <<'EOF'

# IME (fcitx5) — X11 会话
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF
	fi

	# rime-ice 部署到 fcitx5 rime 目录（/etc/skel 供新用户、/root 供 root）
	if rk_cn_fetch_rime_ice /tmp/rime-ice; then
		local d
		for d in /etc/skel /root; do
			mkdir -p "${d}/.local/share/fcitx5/rime"
			cp -r /tmp/rime-ice/* "${d}/.local/share/fcitx5/rime/" 2>/dev/null || true
		done
		log "rime-ice 已部署（fcitx5）"
		rm -rf /tmp/rime-ice
	else
		log "警告: rime-ice 下载失败，fcitx5-rime 使用默认配置"
	fi

	# fcitx5 profile：默认激活 rime
	mkdir -p /etc/skel/.config/fcitx5 /root/.config/fcitx5
	cat > /etc/skel/.config/fcitx5/profile <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=rime

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=rime
Layout=

[GroupOrder]
0=Default
EOF
	cp -f /etc/skel/.config/fcitx5/profile /root/.config/fcitx5/profile 2>/dev/null || true

	# 自动启动
	mkdir -p /etc/xdg/autostart
	cat > /etc/xdg/autostart/fcitx5.desktop <<'EOF'
[Desktop Entry]
Name=Fcitx 5
Comment=Input Method
Exec=fcitx5 --replace -d
Type=Application
X-GNOME-Autostart-enabled=true
EOF
}

# ---------- 3B. GNOME / Wayland → ibus-rime ----------
rk_cn_ime_ibus() {
	log "输入法：ibus-rime + rime-ice（GNOME / Wayland）"
	rk_cn_ensure_dns

	# 必需包与可选包分开：一条 apt 里只要有一个包名找不到，整条失败、一个不装
	local rc=1 i=0
	for i in 0 1 2; do
		apt-get install -y -qq -o Acquire::Retries=3 \
			ibus ibus-gtk3 ibus-gtk4 ibus-rime librime-data >/dev/null 2>&1
		rc=$?
		if [ "${rc}" -eq 0 ] && dpkg -s ibus-rime >/dev/null 2>&1; then
			break
		fi
		log "ibus-rime 第 $((i+1)) 次安装失败（rc=${rc}），重试"
	done
	if [ "${rc}" -ne 0 ] || ! dpkg -s ibus-rime >/dev/null 2>&1; then
		log "警告: ibus-rime 未装上，仍写 ibus 环境变量避免输入链路裸奔"
	fi

	# 可选数据包/引擎（缺一不致整体失败）
	for p in rime-data-luna-pinyin rime-data-terra-pinyin rime-data-cangjie5 \
		rime-data-wubi rime-data-bopomofo rime-data-stroke; do
		apt-get install -y -qq "${p}" >/dev/null 2>&1 || true
	done
	# 语言支持弹窗默认推荐引擎；--no-install-recommends 防止拉入 fcitx5 全家桶抢环境变量
	apt-get install -y -qq --no-install-recommends ibus-libpinyin ibus-table-wubi >/dev/null 2>&1 || true

	# rime-ice → ibus rime 目录
	if rk_cn_fetch_rime_ice /tmp/rime-ice; then
		local d
		for d in /etc/skel /root; do
			mkdir -p "${d}/.config/ibus/rime"
			cp -r /tmp/rime-ice/* "${d}/.config/ibus/rime/" 2>/dev/null || true
		done
		log "rime-ice 已部署（ibus）"
		rm -rf /tmp/rime-ice
	else
		log "警告: rime-ice 下载失败，ibus 使用默认拼音"
	fi

	# 输入法环境变量：三处兜底（profile.d / systemd user env / /etc/environment）
	# GTK_IM_MODULE 显式 ibus —— 本板候选框在 wayland IM context 下常渲染不出，
	# ibus 的 GTK IM 模块（1.5.29+ 同样走 text-input 协议）稳定可用。
	mkdir -p /etc/profile.d
	cat > /etc/profile.d/99-gnome-wayland-ime.sh <<'EOF'
export GTK_IM_MODULE=ibus
export QT_IM_MODULE=ibus
export XMODIFIERS=@im=ibus
export CLUTTER_IM_MODULE=ibus
export SDL_IM_MODULE=ibus
EOF
	mkdir -p /etc/systemd/user-environment-generators
	cat > /etc/systemd/user-environment-generators/99-zz-rk-ime <<'EOF'
#!/bin/sh
echo "GTK_IM_MODULE=ibus"
echo "QT_IM_MODULE=ibus"
echo "XMODIFIERS=@im=ibus"
echo "CLUTTER_IM_MODULE=ibus"
EOF
	chmod 755 /etc/systemd/user-environment-generators/99-zz-rk-ime
	if ! grep -q '^GTK_IM_MODULE=' /etc/environment 2>/dev/null; then
		cat >> /etc/environment <<'EOF'

# IME (ibus) — GNOME/Wayland
GTK_IM_MODULE=ibus
QT_IM_MODULE=ibus
XMODIFIERS=@im=ibus
EOF
	fi

	# GNOME 默认输入源：us + ibus(rime)，current=1 首启即停在中文
	mkdir -p /etc/dconf/db/local.d
	cat > /etc/dconf/db/local.d/10-input-sources <<'EOF'
[org/gnome/desktop/input-sources]
sources=[('xkb', 'us'), ('ibus', 'rime')]
current=uint32 1
xkb-options=['caps:escape']
EOF
	dconf update >/dev/null 2>&1 || true
}

# ============================================================
# 4. Chromium 中文界面（hardware decode 由 rkmpp-mpv / mesa-vpu 负责）
# ============================================================
rk_cn_setup_chromium_zh() {
	[ "${RK_CN_BUILD_DESKTOP}" = "yes" ] || { log "非桌面镜像，跳过 Chromium 中文化"; return 0; }

	local bin=""
	command -v chromium >/dev/null 2>&1 && bin="chromium"
	[ -z "${bin}" ] && command -v chromium-browser >/dev/null 2>&1 && bin="chromium-browser"
	if [ -z "${bin}" ]; then
		log "提示: 镜像内未安装 chromium（由 mesa-vpu/板级决定），跳过中文化"
		return 0
	fi

	log "Chromium 中文化（二进制: ${bin}）"
	# 中文语言包
	apt-get install -y -qq --allow-downgrades "${bin}-l10n" >/dev/null 2>&1 \
		|| apt-get install -y -qq chromium-l10n >/dev/null 2>&1 \
		|| log "提示: chromium-l10n 不可用，界面语由 --lang=zh-CN 保证"

	# 启动参数目录（Debian 原版 /etc/chromium.d；rkmpp 版 /etc/chromium-browser/customizations）
	mkdir -p /etc/chromium.d /etc/chromium-browser/customizations
	cat > /etc/chromium.d/99-rk-zh <<'EOF'
# 中文界面（customize: rk35xx-chinese-desktop）
# 变量一律用 ${VAR:-} 形式：若 wrapper 开了 set -u 且变量未初始化，裸引用会整条报错
export CHROMIUM_FLAGS="${CHROMIUM_FLAGS:-} --lang=zh-CN"
EOF
	chmod 644 /etc/chromium.d/99-rk-zh
	cat > /etc/chromium-browser/customizations/50-rk-zh <<'EOF'
export CHROMIUM_FLAGS="${CHROMIUM_FLAGS:-} --lang=zh-CN"
EOF
	chmod 644 /etc/chromium-browser/customizations/50-rk-zh

	# 企业策略：ApplicationLocale 比 --lang 更权威
	local pol
	for pol in /etc/chromium/policies/managed /etc/chromium-browser/policies/managed; do
		mkdir -p "${pol}"
		cat > "${pol}/locale.json" <<'EOF'
{
  "ApplicationLocale": "zh-CN"
}
EOF
	done

	# 新用户 Local State 预置（app_locale 管界面语，accept_languages 管网页语）
	local cfg
	for cfg in /etc/skel/.config/chromium /etc/skel/.config/chromium-browser /root/.config/chromium; do
		mkdir -p "${cfg}"
		cat > "${cfg}/Local State" <<'EOF'
{
  "intl": {
    "app_locale": "zh-CN",
    "accept_languages": "zh-CN,zh,en-US,en"
  }
}
EOF
	done
	log "Chromium 中文化完成"
}

# ============================================================
# main
# ============================================================
rk_cn_setup_user
rk_cn_setup_locale_tz_fonts

if [ "${RK_CN_BUILD_DESKTOP}" = "yes" ]; then
	# 输入法框架选路：显式 RK_CN_IME 优先；否则 GNOME→ibus，其余→fcitx5
	ime="${RK_CN_IME}"
	if [ "${ime}" = "auto" ]; then
		case "${RK_CN_DESKTOP_ENV}" in
			gnome) ime="ibus" ;;
			*)     ime="fcitx5" ;;
		esac
	fi
	log "桌面=${RK_CN_DESKTOP_ENV} 输入法框架=${ime}"
	case "${ime}" in
		ibus)   rk_cn_ime_ibus ;;
		fcitx5) rk_cn_ime_fcitx5 ;;
		*)      log "未知 RK_CN_IME=${ime}，按桌面自动选路"; \
		        [ "${RK_CN_DESKTOP_ENV}" = "gnome" ] && rk_cn_ime_ibus || rk_cn_ime_fcitx5 ;;
	esac
	rk_cn_setup_chromium_zh
	rk_cn_autologin_order
else
	log "server/minimal 镜像：跳过输入法与 Chromium 中文化"
fi

log "完成"
exit 0

#!/bin/bash
#
# AIO-3288C (Firefly RK3288, armhf) image customization
# arguments: $RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4

Main() {
	# 桌面板卡: 移除 VLC。Armbian 桌面任务(XFCE mid 档)默认拉入 VLC,
	# 但 RK 平台 VLC 无法走 Rockchip rkmpp 硬解, 4K60 VP9 软解会花屏+卡顿;
	# 硬解由 mpv(rkmpp) 承担。彻底从镜像剔除 VLC。
	# ⚠️ 必须写成 if，不能写 `[[ ... ]] && Func`：Armbian 用
	# `bash -e -o pipefail -c "$*"` 调用本脚本（lib/functions/logging/runners.sh:175），
	# 本函数是 Main() 唯一语句，条件为假时 `&&` 返回 1 → 整脚本 rc=1，
	# server/minimal 镜像会在 customize_image 阶段直接失败。
	if [[ "${BUILD_DESKTOP}" == "yes" ]]; then
		RemoveUnwantedPackages
	fi
}

RemoveUnwantedPackages() {
	# Armbian 桌面任务默认安装 VLC; RK 平台 VLC 无法 rkmpp 硬解, 4K60 VP9 软解会花屏+卡顿。
	# 硬解由 mpv(rkmpp) 承担, 此处彻底从镜像剔除 VLC 及其库。
	export DEBIAN_FRONTEND=noninteractive
	export APT_LISTCHANGES_FRONTEND=none
	apt-get purge -y --autoremove 'vlc*' 'libvlc*' 'libvlccore*' 2>/dev/null || true
	apt-get -y -q clean
}

Main "$@"

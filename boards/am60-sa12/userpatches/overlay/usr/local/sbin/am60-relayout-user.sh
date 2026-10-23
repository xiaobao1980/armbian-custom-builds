#!/bin/bash
# 由 udev（root）调用：切到【当前图形会话用户】的会话里重跑布局固定脚本。
# 用途：热插拔 HDMI / Type-C 之后，主屏与红外触控映射也能自动纠正。
# 注意：不能阻塞 udev，所以丢到后台执行。
set -u

# 动态探测图形会话用户（标准 Armbian 首启向导建的账户名不固定）
SESS=$(/usr/local/sbin/am60-session-user.sh) || exit 0
UID_NUM=${SESS%% *}
REST=${SESS#* }; U=${REST%% *}
RT="/run/user/${UID_NUM}"
BUS="unix:path=${RT}/bus"
[ -S "${RT}/bus" ] || exit 0
[ -x /usr/local/bin/am60-monitor-layout.py ] || exit 0

runuser -u "$U" -- env \
    DBUS_SESSION_BUS_ADDRESS="$BUS" \
    XDG_RUNTIME_DIR="$RT" \
    /usr/local/bin/am60-monitor-layout.py --wait &
exit 0

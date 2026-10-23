#!/bin/bash
# AM60 触控映射策略切换
#
# 两种策略二选一（不能同时用，否则双重变换）：
#
#  A) matrix（当前默认，已验证可用）
#     用 libinput CALIBRATION_MATRIX 把触控压到主屏那一段：a = w_main/total。
#     单屏时 total==w_main -> a=1，多屏时 a=1/2、1/3 ...
#     依赖：屏数/几何变化后必须及时重算，且要重新枚举 USB 让 libinput 重读。
#
#  B) bind（更鲁棒，需实测）
#     让 mutter 直接把触摸设备绑定到主屏输出（gsettings output=主屏EDID三元组），
#     矩阵恒为单位阵，不再随屏数变化重算。
#     依赖：mutter 支持该 schema；绑定失败则回退到"整个桌面"映射。
#
# 用法（root）：
#   am60-touch-bind-output.sh status
#   am60-touch-bind-output.sh bind     # 切到 B：绑定主屏输出 + 矩阵=1
#   am60-touch-bind-output.sh matrix   # 切回 A：删除绑定 + 恢复矩阵重算
#
# ⚠️ 单屏状态下两种策略等价（a=1 vs 单位阵），看不出差别；
#    必须【接上第二块屏】才能验证 bind 是否真的把触控锁在主屏上。
set -u
TAG=touch-bind
FLAG=/etc/am60-touch-bind-output
SCHEMA=org.gnome.desktop.peripherals.touchscreen
PATH_V="/org/gnome/desktop/peripherals/touchscreens/1101:0060/"
SPROG=/usr/local/sbin/dump_monitor_spec.py

# 动态探测图形会话用户（标准 Armbian 首启向导建的账户名不固定）
SESS=$(/usr/local/sbin/am60-session-user.sh 2>/dev/null) || { echo "!! 找不到图形会话用户，退出"; exit 1; }
UID_N=${SESS%% *}
REST=${SESS#* }; USER=${REST%% *}
REST=${REST#* }; HOME=${REST}

as_user() {
    runuser -u "$USER" -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_N/bus "$@"
}

# 从 mutter 查指定 connector 的 vendor/product/serial
# $1 = connector 名（默认 HDMI-1）
main_spec() {
    local conn="${1:-HDMI-1}"
    [ -f "$SPROG" ] || { echo ""; return 1; }
    runuser -u "$USER" -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_N/bus \
        python3 "$SPROG" 2>/dev/null | awk -v c="$conn" '
            /^  --- monitor ---/ {blk=1; v=""; p=""; s=""; name=""}
            blk && $0 ~ "spec\\[0\\] = ."c"." {name=c}
            blk && /spec\[1\] =/ {v=$0; sub(/.*spec\[1\] = /,"",v); gsub(/'"'"'/,"",v)}
            blk && /spec\[2\] =/ {p=$0; sub(/.*spec\[2\] = /,"",p); gsub(/'"'"'/,"",p)}
            blk && /spec\[3\] =/ {s=$0; sub(/.*spec\[3\] = /,"",s); gsub(/'"'"'/,"",s);
                                  if (name==c) {print v"|"p"|"s; exit}}
        '
}

case "${1:-status}" in
status)
    echo "=== 当前策略 ==="
    if [ -f "$FLAG" ]; then
        echo "  B) bind —— 输出绑定模式（矩阵恒为单位阵）"
    else
        echo "  A) matrix —— 矩阵重算模式（a = w_main/total）"
    fi
    echo "-- mutter 绑定值 --"
    as_user gsettings get "$SCHEMA:$PATH_V" output 2>&1
    echo "-- 矩阵文件 --"
    cat "${HOME}/.config/am60-touch-matrix" 2>/dev/null
    echo "-- udev 规则 --"
    grep -o 'LIBINPUT_CALIBRATION_MATRIX="[^"]*"' /etc/udev/rules.d/99-touchscreen-calibration.rules 2>/dev/null
    echo "-- 当前屏数 --"
    n=0
    for c in /sys/class/drm/card0-HDMI-A-1 /sys/class/drm/card0-HDMI-A-2 /sys/class/drm/card0-HDMI-B-1 /sys/class/drm/card0-DP-1; do
        [ -f "$c/status" ] || continue
        [ "$(cat "$c/status" 2>/dev/null)" = "connected" ] && n=$((n+1))
    done
    echo "  connected=$n"
    ;;

bind)
    SPEC=$(main_spec HDMI-1)
    if [ -z "$SPEC" ]; then
        echo "!! 查不到 HDMI-1 的 EDID 三元组（$SPROG 缺失或 mutter 未就绪）"
        exit 1
    fi
    V=${SPEC%%|*}; REST=${SPEC#*|}; P=${REST%%|*}; S=${REST#*|}
    echo "主屏 HDMI-1: vendor=$V product=$P serial=$S"
    as_user gsettings set "$SCHEMA:$PATH_V" output "['$V', '$P', '$S']"
    touch "$FLAG"
    logger -t $TAG "切换到 bind 模式: output=['$V','$P','$S']"
    echo "已启用 bind 模式；正在把矩阵置为单位阵并重新枚举触控框..."
    /usr/local/sbin/touchscreen-map.sh
    sleep 6
    echo "-- 校验绑定值 --"
    as_user gsettings get "$SCHEMA:$PATH_V" output
    echo "-- 校验矩阵（应为 1 0 0 0 1 0）--"
    grep -o 'LIBINPUT_CALIBRATION_MATRIX="[^"]*"' /etc/udev/rules.d/99-touchscreen-calibration.rules
    echo "完成。请接上第二块屏验证：触控是否仍只作用在大屏上。"
    ;;

matrix)
    as_user gsettings reset "$SCHEMA:$PATH_V" output 2>/dev/null
    rm -f "$FLAG"
    logger -t $TAG "切回 matrix 模式（a = w_main/total）"
    echo "已切回 matrix 模式；正在重算矩阵..."
    /usr/local/sbin/touchscreen-map.sh
    sleep 6
    echo "-- 校验绑定值（应为空/默认值）--"
    as_user gsettings get "$SCHEMA:$PATH_V" output
    echo "-- 校验矩阵 --"
    grep -o 'LIBINPUT_CALIBRATION_MATRIX="[^"]*"' /etc/udev/rules.d/99-touchscreen-calibration.rules
    ;;

*)
    echo "用法: $0 {status|bind|matrix}"
    exit 2
    ;;
esac

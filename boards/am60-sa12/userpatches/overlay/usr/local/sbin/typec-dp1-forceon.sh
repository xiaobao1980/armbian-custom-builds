#!/bin/bash
# Type-C 接入后强制 DP-1 上线（热插拔兜底）
# 由 /etc/udev/rules.d/99-typec-dp1.rules 在 typec 事件时触发
#
# 【2026-09-14 重要修正】必须判断"是否真的接了外设"：
#   udev 的 SUBSYSTEM=="typec" ACTION=="add" 在【port0 自身注册时】就会触发，
#   并不需要真的插线。旧版无条件 forceon，导致 DP-1 被标记 connected 但实际没屏，
#   mutter 把它当成第二个 4K 屏拼进虚拟桌面（7680x2160），
#   红外触控 0..32767 坐标被摊薄 -> 只有左上角能点中，登录/桌面点击错位。
#
# 判据：/sys/class/typec/port0-partner 存在 == 真的协商到了对端设备。
#   - 有 partner（真插了线/显示器）-> force on，出 DP 画面
#   - 无 partner            -> force off，避免"假屏"破坏触控映射

set -u
TAG=typec-dp1

# 2026-09-15 修正：调用方要传 add / remove。
#   add    = 插线（或 port0 自身注册）-> 等 partner 出现再决定 on/off
#   remove = 拔线                     -> 立即清掉假屏（旧版只有 add 规则，
#            拔线时脚本根本不跑，force-on 状态永远残留 -> Type-C 显示
#            "AM60-IFP 3840x2160" 幽灵屏，把桌面撑到 7680、触控矩阵被压成 0.5）
MODE="${1:-add}"

# 2026-09-15：内核 Plan B 补丁把 Type-C 口的连接器类型从 DisplayPort(10) 改成
# HDMIB(12)（目的是让它在 mutter 排序里排最后，GNOME 角标 = 3），
# 于是 sysfs 名字从 card0-DP-1 变成 card0-HDMI-B-1。
# 两个名字都探测 -> 换回旧内核也能正常工作。
DP=
for n in HDMI-B-1 DP-1; do
    [ -f "/sys/class/drm/card0-$n/status" ] && DP="/sys/class/drm/card0-$n/status"
done
if [ -z "$DP" ]; then
    logger -t $TAG "no Type-C drm connector found (neither HDMI-B-1 nor DP-1)"
    exit 0
fi
logger -t $TAG "Type-C connector = $DP  (mode=$MODE)"

# ---- 拔线分支：给 3 秒宽限（换线/重新协商），仍无 partner 就直接 off ----
if [ "$MODE" = "remove" ]; then
    for i in 1 2 3; do
        [ -d /sys/class/typec/port0-partner ] && {
            logger -t $TAG "remove event but partner still present; keep as-is"
            exit 0
        }
        sleep 1
    done
    if [ ! -d /sys/class/typec/port0-partner ] && [ -f "$DP" ]; then
        echo off > "$DP" 2>/dev/null
        logger -t $TAG "partner removed; forced $DP OFF (phantom screen cleared)"
    fi
    exit 0
fi

# 等 TCPM 协商完成（拔插后 partner 出现需要时间）
for i in $(seq 1 20); do
    [ -d /sys/class/typec/port0-partner ] && break
    sleep 1
done

if [ ! -d /sys/class/typec/port0-partner ]; then
    # 没接外设：确保 DP-1 不占位
    if [ -f "$DP" ]; then
        echo off > "$DP" 2>/dev/null
        logger -t $TAG "no partner; forced $DP OFF to avoid phantom screen"
    fi
    exit 0
fi

# 有 partner：等 drm probe + EDID override 完成后强制上线
for i in $(seq 1 30); do
    if [ -f "$DP" ]; then
        sleep 2
        echo on > "$DP" 2>/dev/null
        logger -t $TAG "partner attached; forced $DP on"
        break
    fi
    sleep 1
done

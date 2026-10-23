#!/bin/bash
# AM60 显示强制上线 —— 强制"无 HPD / HPD 不可靠"的口，其余交给真实 HPD。
#
# 【2026-09-14 重大修正】
# 旧版对 HDMI-A-1 / HDMI-A-2 / DP-1 三个口【无条件】forceon。
# 副作用：没接显示器的口也被标记 connected，mutter 把它们拼成
#   超宽虚拟桌面（实测 7680x2160 = 两个 4K 横向拼接）。
#   红外触控上报 0..32767 归一化坐标，被摊薄到整个虚拟桌面，
#   导致只有大屏左半边能点中，右半边点击落到"看不见的第二个屏"。
#   症状：点左上角有反应，点终端/文件管理等图标无反应。
#
# ★★★ 2026-09-16 重大更正：HDMI-A-2【绝对不要】force-on！★★★
# 曾误判"HDMI-A-2 HPD 不可靠"而把它加进 force-on，结果造成回归：
#   - force-on 会让内核【跳过真实 detect】并【缓存 EDID】；
#   - 实测：无 force 时插入 3 秒内自动 connected，读到完整 EDID（"AB TV"，
#     含 3840x2160）；加了 force 后反而显示 unknown 1920x1080（陈旧缓存），
#     显示器收到错误时序 -> "无信号"，且拔掉后不消失（假屏残留）。
# 正确结论：**HDMI-A-2 的 HPD 完全正常，交给内核自动检测即可**，热插拔本来就
#   能用（"历史版本正常"）。只给真正不回 HPD 的口加 force-on。
#
# 正确做法（勿再改回去）：
#   HDMI-A-1（大屏 OPS 口）：面板不回 HPD，【必须】强制 on。
#   HDMI-A-2（前置 HDMI）  ：HPD 正常，【不强制】，交给内核自动检测。
#   DP-1/HDMI-B-1（Type-C）：由 udev 规则 99-typec-dp1.rules 在
#                            port0-partner 出现时触发 forceon（该口显示器
#                            不给 EDID，需要固件 EDID，故需 force + partner 判据）。
#
# KMS 映射（2026-09-14 实测，勿再混淆）：
#   HDMI-A-1 = 大屏 OPS 口  (hdmi@fde80000 = hdmi0)
#   HDMI-A-2 = 前置 HDMI    (hdmi@fdea0000 = hdmi1)
#   DP-1     = 前置 Type-C  (dp0)

set -u
# 仅强制"真正不回 HPD"的口。HDMI-A-2 的 HPD 已证实正常，切勿加入！
FORCE_ON="HDMI-A-1"

for c in $FORCE_ON; do
    S=/sys/class/drm/card0-$c/status
    for i in $(seq 1 60); do
        if [ -f "$S" ]; then
            echo on > "$S" 2>/dev/null
            logger -t hdmi-forceon "forced $c on (HPD-less / unreliable HPD)"
            break
        fi
        sleep 1
    done
done

# 显示器数量已确定，据此设置红外触控的坐标映射（单屏=全屏 / 多屏=锁主屏）
[ -x /usr/local/sbin/touchscreen-map.sh ] && /usr/local/sbin/touchscreen-map.sh

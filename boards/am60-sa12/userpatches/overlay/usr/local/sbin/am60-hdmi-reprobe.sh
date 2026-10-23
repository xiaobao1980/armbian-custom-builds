#!/bin/bash
# 强制大屏 OPS 口（HDMI-A-1，无 HPD）connected，逼 mutter 用已就位的 EDID
# 重新向 KMS 提交 4K 模式。只做 on（幂等），不定 off，避免额外黑屏闪烁、
# 也避免「off 之后 on 没接住」的竞态导致大屏反而掉线。
# 仅供 am60-monitor-layout.py 以 NOPASSWD sudo 调用。
set -u
for c in HDMI-A-1; do
    s=/sys/class/drm/card0-$c/status
    [ -f "$s" ] || continue
    for i in 1 2 3; do
        echo on > "$s" 2>/dev/null
        sleep 0.5
    done
done
sleep 2

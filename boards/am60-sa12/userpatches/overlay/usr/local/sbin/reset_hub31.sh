#!/bin/bash
# 复位前置面板 USB hub 3-1，救回连坐掉线的红外触控框(1101:0060)
# ⚠️ 副作用：会短暂断开同在 3-1 下的以太网 r8152(3-1.1)，板子走 WiFi 无影响
set -u
HUB=3-1
P=/sys/bus/usb/devices/$HUB

echo "复位前："
lsusb | grep -i 1101 || echo "  触控框缺失"

echo -n "$HUB" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
sleep 2
echo -n "$HUB" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || \
    echo 1 > "$P/power/level" 2>/dev/null
sleep 5

echo "复位后："
lsusb | grep -i 1101 && echo "  触控框已恢复" || echo "  触控框仍未出现"
ls -d /sys/bus/usb/devices/3-1.2* 2>/dev/null
dmesg | tail -6

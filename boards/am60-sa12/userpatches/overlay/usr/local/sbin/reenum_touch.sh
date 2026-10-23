#!/bin/bash
# 强制重新枚举红外触控框，让 libinput 重新读取 LIBINPUT_CALIBRATION_MATRIX
set -u
DEV=3-1.2.1
P=/sys/bus/usb/devices/$DEV

echo "=== 重新枚举前 ==="
ls -d $P 2>/dev/null && echo "设备在线" || { echo "设备不存在"; exit 1; }

echo "=== unbind ==="
echo -n "$DEV" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
sleep 2
ls -d $P 2>/dev/null && echo "unbind 后目录仍在" || echo "unbind 后目录已消失"

echo "=== bind ==="
echo -n "$DEV" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || \
  echo 1 > /sys/bus/usb/devices/3-1/3-1:1.0/../power/level 2>/dev/null
sleep 3

echo "=== 结果 ==="
lsusb | grep -i 1101 || echo "!! 触控框未回来"
ls -d $P 2>/dev/null && echo "sysfs 在线" || echo "sysfs 丢失"

echo "=== dmesg ==="
dmesg | tail -8

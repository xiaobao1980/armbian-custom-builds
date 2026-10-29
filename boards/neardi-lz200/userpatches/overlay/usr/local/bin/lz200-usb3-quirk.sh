#!/bin/bash
# Neardi LZ200 — USB3 SuperSpeed 端口训练失败的自愈脚本
#
# 症状: 某条 Type-C 线缆/扩展坞的 SS(SuperSpeed) 通道训练失败时，内核每秒打印
#       "usb usb4-port1: Cannot enable. Maybe the USB cable is bad?"
#       严重时整条 xHCI 总线被注销 -> USB 声卡(扩展坞)掉线、无声。
#
# 策略: 仅在检测到该风暴(8 秒窗口内 >=3 次) 且 usb4 上没有任何 SuperSpeed 设备
#       时，才解绑 usb4 的 hub 接口，只保留 USB2 通路(音频/键鼠足够用)。
#       正常情况下(SS 训练成功或有 SS 设备在位)不做任何动作。
#
# 撤销:   echo '4-0:1.0' > /sys/bus/usb/drivers/hub/bind
# 禁用:   systemctl disable --now lz200-usb3-quirk.service
# 日志:   journalctl -u lz200-usb3-quirk.service

IFACE="4-0:1.0"
SYSFS="/sys/bus/usb/devices/${IFACE}"
BIND="/sys/bus/usb/drivers/hub/bind"
UNBIND="/sys/bus/usb/drivers/hub/unbind"
PATTERN="Cannot enable"

log() { echo "[lz200-usb3-quirk] $*"; }

# 1) usb4 hub 接口是否存在
[ -d "$SYSFS" ] || { log "usb4 hub 接口不存在，跳过"; exit 0; }

# 2) 是否已经解绑（已处理过）
[ -e "$SYSFS/driver" ] || { log "usb4 hub 已处于解绑状态，跳过"; exit 0; }

# 3) usb4 上若有 SuperSpeed 子设备(形如 usb4/4-1、4-1.1)，说明 SS 通路可用，不动
#    注意: 不能匹配 4-0:1.0 —— 那是 root hub 自身的接口，不是子设备
if compgen -G "/sys/bus/usb/devices/usb4/4-[1-9]*" >/dev/null 2>&1; then
    log "usb4 上存在 SuperSpeed 设备，SS 通路正常，跳过"
    exit 0
fi

# 4) 统计 8 秒窗口内 "Cannot enable" 增量
before=$(dmesg 2>/dev/null | grep -c "$PATTERN")
sleep 8
after=$(dmesg 2>/dev/null | grep -c "$PATTERN")
delta=$((after - before))
log "8 秒内 Cannot enable 增量 = $delta"

if [ "$delta" -lt 3 ]; then
    log "未检测到端口训练风暴，保持 USB3 启用"
    exit 0
fi

log "检测到 SS 端口训练风暴 -> 解绑 ${IFACE}，回退 USB2 通路"
echo "$IFACE" > "$UNBIND" 2>/dev/null
sleep 1
if [ -e "$SYSFS/driver" ]; then
    log "解绑失败"
    exit 1
fi
log "已解绑，USB2 通路保持可用"
exit 0

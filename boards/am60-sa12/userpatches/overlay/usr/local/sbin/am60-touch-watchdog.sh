#!/bin/bash
# AM60 红外触控框(1101:0060)USB 看门狗
# 作用：检测触控框是否掉线（拔前置 HDMI/Type-C 会连坐断电其所在的前置 hub 3-1 port2=3-1.2），
#       掉线则强制重新枚举该 hub 救回设备，并重新套用校准矩阵。
# 触发：本脚本自循环（由 systemd 拉起，Restart=always 兜底），轮询间隔 INTERVAL 秒。
# 退避：若连续恢复失败（说明前置屏确实没插/物理断电），切换到 LONG_INTERVAL 长等待，避免空转狂_RESET hub。
set -u

LOCK=/run/lock/am60-touch-watchdog.lock
HUB=3-1                       # 前置面板 hub；触控框 1101:0060 挂在其 port2（3-1.2）下，拓扑稳定故硬编码
TOUCH_VID=1101
TOUCH_PID=0060
LOG=/var/log/am60-touch-watchdog.log
INTERVAL=15                   # 正常轮询间隔（秒）
LONG_INTERVAL=120             # 连续失败后的长等待（秒）

log(){ echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; }
present(){ lsusb | grep -qi "$TOUCH_VID:$TOUCH_PID"; }
recover_hub(){
  local h=/sys/bus/usb/devices/$HUB
  [ -d "$h" ] || { log "WARN: hub $HUB 不存在，跳过重置"; return 1; }
  log "recover: unbind $HUB"; echo "$HUB" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null; sleep 2
  log "recover: bind   $HUB"; echo "$HUB" > /sys/bus/usb/drivers/usb/bind   2>/dev/null; sleep 6
}
apply_matrix(){ /usr/local/sbin/touchscreen-map.sh >> "$LOG" 2>&1 || true; }

mkdir -p /run/lock
exec 9>"$LOCK" 2>/dev/null || exit 0

fail_count=0
while true; do
  if present; then
    if [ "$fail_count" -ne 0 ]; then log "touch 已恢复（此前失败 $fail_count 次）"; fail_count=0; fi
    sleep "$INTERVAL"; continue
  fi

  # 设备缺失：抢锁后尝试恢复（防止与手动恢复并发）
  if flock -n 9; then
    log "touch 缺失 -> 尝试恢复"
    recover_hub
    if present; then log "touch 已恢复"; apply_matrix; fail_count=0; flock -u 9; sleep "$INTERVAL"; continue; fi
    recover_hub
    if present; then log "touch 已恢复(第2次)"; apply_matrix; fail_count=0; flock -u 9; sleep "$INTERVAL"; continue; fi
    fail_count=$((fail_count+1))
    flock -u 9
    if [ "$fail_count" -ge 2 ]; then
      log "touch 仍缺失（累计 $fail_count 次）；疑前置屏未插/物理断电，转入长等待 ${LONG_INTERVAL}s"
      sleep "$LONG_INTERVAL"; continue
    fi
  else
    log "skip: 另一恢复实例占用锁"
  fi
  sleep "$INTERVAL"
done

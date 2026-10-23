#!/bin/bash
# 查红外触控框当前 libinput LIVE 校准矩阵
for e in /sys/class/input/event*; do
  n=${e##*/}
  v=$(udevadm info -q property -n /dev/input/$n 2>/dev/null | grep -E '^ID_VENDOR_ID=' | cut -d= -f2)
  p=$(udevadm info -q property -n /dev/input/$n 2>/dev/null | grep -E '^ID_MODEL_ID=' | cut -d= -f2)
  if [ "$v$p" = "11010060" ]; then
    echo "== $n  (1101:0060) =="
    udevadm info -q property -n /dev/input/$n 2>/dev/null | grep -iE 'CALIBRATION|ID_INPUT_TOUCHSCREEN|NAME='
    echo "-- udev db 中的 ENV --"
    udevadm info -q all -n /dev/input/$n 2>/dev/null | grep -i calibration
  fi
done
echo "=== 期望矩阵(文件) ==="
# 矩阵文件路径跟随当前图形会话用户（标准 Armbian 首启向导建的账户名不固定）
MTXHOME=""
SESS=$(/usr/local/sbin/am60-session-user.sh 2>/dev/null)
[ -n "$SESS" ] && MTXHOME=${SESS##* }
[ -n "$MTXHOME" ] || MTXHOME=/home/xiaobao
cat "${MTXHOME}/.config/am60-touch-matrix" 2>/dev/null

#!/bin/bash
# 红外触控框 (1101:0060 C60-QD86-40P) 坐标映射自动适配
#
# 背景：触控上报 0..32767 归一化坐标，由桌面映射到【整个虚拟桌面】。
#   接 2 个 4K 屏时虚拟桌面 7680 宽，触控被摊薄 -> 只有左半边能点中。
# 做法：用 libinput calibration matrix 把触控缩放到主屏（大屏 OPS 口）那一段。
#   x' = a*x + b*y + c ;  y' = d*x + e*y + f
#
# 矩阵来源优先级：
#   1) ~/.config/am60-touch-matrix（~ 取当前图形会话用户家目录）
#      —— 由 /usr/local/bin/am60-monitor-layout.py 按【实际布局】算出来，
#         能正确处理「主屏不在最左」「各屏分辨率不同」的情况。首选。
#   2) 退化：按 connected 屏幕数取 1/N（要求所有屏同宽且主屏在最左）
#
# 本脚本以 root 运行（udev / systemd / sudo -n 调用）。

RULE=/etc/udev/rules.d/99-touchscreen-calibration.rules
TAG=touchscreen-map

# 矩阵文件路径跟随当前图形会话用户（标准 Armbian 首启向导建的账户名不固定）
MTXHOME=""
SESS=$(/usr/local/sbin/am60-session-user.sh 2>/dev/null)
if [ -n "$SESS" ]; then
    MTXHOME=${SESS##* }
fi
[ -n "$MTXHOME" ] || MTXHOME=/home/xiaobao   # 会话未就绪时退路，热插拔事件会再触发
MTXFILE="${MTXHOME}/.config/am60-touch-matrix"

M=""
MODE=""

# ---- 1) 优先读布局脚本算好的矩阵 ----
if [ -r "$MTXFILE" ]; then
    M=$(tr -d '\r\n' < "$MTXFILE" | tr -s ' ' | sed 's/^ *//;s/ *$//')
    case "$M" in
        *[0-9]*" "*[0-9]*) MODE="from layout script" ;;
        *) M="" ;;
    esac
fi

# ---- 2) 退化：按 connected 数量 ----
if [ -z "$M" ]; then
    CNT=0
    # 2026-09-15：Type-C 口改名 HDMI-B-1（内核 Plan B）；保留 DP-1 兼容旧内核
    for c in /sys/class/drm/card0-HDMI-A-1 /sys/class/drm/card0-HDMI-A-2 /sys/class/drm/card0-HDMI-B-1 /sys/class/drm/card0-DP-1; do
        [ -f "$c/status" ] || continue
        [ "$(cat "$c/status" 2>/dev/null)" = "connected" ] && CNT=$((CNT+1))
    done
    [ "$CNT" -lt 1 ] && CNT=1
    if [ "$CNT" -ge 2 ]; then
        case "$CNT" in
            2) M="0.5 0 0 0 1 0" ;;
            3) M="0.333333 0 0 0 1 0" ;;
            *) M=$(awk -v n="$CNT" 'BEGIN{printf "%.6f 0 0 0 1 0", 1/n}') ;;
        esac
        MODE="fallback: multi(${CNT} screens) -> lock to left 1/${CNT}"
    else
        M="1 0 0 0 1 0"
        MODE="fallback: single -> full screen"
    fi
fi

# ---- 2.5) 「输出绑定模式」：矩阵强制为单位阵 ----
# 启用 /etc/am60-touch-bind-output 后，由 mutter 直接把触摸设备映射到主屏输出
# （gsettings org.gnome.desktop.peripherals.touchscreen output），
# 坐标不再经过"整个虚拟桌面"，因此矩阵必须恒为单位阵，否则会【双重变换】
# （先被矩阵缩小、再被映射进主屏矩形 -> 触控只能覆盖主屏左半边）。
BIND_FLAG=/etc/am60-touch-bind-output
if [ -f "$BIND_FLAG" ]; then
    M="1 0 0 0 1 0"
    MODE="output-bound: identity matrix (mutter maps touch device to main monitor)"
fi

# ---- 3) 规则没变就不重写，避免无谓的 udev 抖动 ----
NEW='# 由 /usr/local/sbin/touchscreen-map.sh 自动生成，勿手改
# 当前: '"${MODE}"'
ACTION=="add|change", KERNEL=="event*", ATTRS{idVendor}=="1101", ATTRS{idProduct}=="0060", ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="'"$M"'"'

NEED_REENUM=0
if [ ! -f "$RULE" ] || [ "$(cat "$RULE")" != "$NEW" ]; then
    printf '%s\n' "$NEW" > "$RULE"
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=input --action=change 2>/dev/null
    logger -t $TAG "matrix='${M}' (${MODE}) [updated]"
    echo "updated matrix=${M} (${MODE})"
    NEED_REENUM=1          # 规则变了 -> 必须让 libinput 重读
else
    logger -t $TAG "matrix='${M}' (${MODE}) [unchanged]"
    echo "unchanged matrix=${M} (${MODE})"
fi

# ---- 4) 让 libinput 真正用上新矩阵：必要时强制重新枚举触控框 ----
#
# 【2026-09-16 修】libinput 只在设备 ADD 时读 LIBINPUT_CALIBRATION_MATRIX，
# 之后 change 事件不会让它重新初始化。红外框是一体机内置、不能物理拔插，
# 所以必须用 USB unbind/bind 做一次"软件重插"来强制 libinput 重新 ADD。
#
# 旧实现（2026-09-15）的致命 bug：先 udevadm control --reload-rules 把 udev
# 数据库刷成新矩阵，再让 re-enum 脚本用 udevadm info 比对"实际 vs 期望"——
# 但数据库已被刷成新值，比对永远"一致"，于是 unbind/bind 永不执行，
# libinput 一直停留在开机加载的旧压缩矩阵（如 0.333333），表现为
# "只有左上区域能点"。
#
# 新实现：不再比对（已不可信的）udev 数据库，改为以下任一条件即无条件
# 重新枚举：
#   ① 本脚本算出的矩阵与【上次实际应用值】(存 /run) 不同；
#   ② 规则文件被改写（上面已置 NEED_REENUM=1）；
#   ③ 调用方显式 force（am60-monitor-layout.py 每次布局变化都传 force，
#      以覆盖"开机加载旧矩阵但磁盘规则已正确"的隐藏失同步）。
#
# re-enum 脚本写在 /run（tmpfs，永远可写，避免根文件系统只读时写不出脚本）。
# 用 setsid 脱离 udevd 的 cgroup/会话后台执行，并用 flock 防并发重插。
case "$1" in
    force|-f|--force) NEED_REENUM=1 ;;
esac
[ "${AM60_TOUCH_FORCE:-0}" = "1" ] && NEED_REENUM=1

LAST=/run/am60-touch-last-matrix
if [ -r "$LAST" ]; then
    LAST_M=$(cat "$LAST" 2>/dev/null)
    [ "$LAST_M" = "$M" ] && NEED_REENUM=0     # 已应用过相同矩阵，跳过
fi

if [ "$NEED_REENUM" = "1" ]; then
    AM60_REENUM=/run/am60-touch-reenum.sh
    cat > "$AM60_REENUM" <<'REENUM'
#!/bin/bash
# 由 touchscreen-map.sh 生成：软件重插红外触控框，让 libinput 重读矩阵
TAG=touch-reenum
WANT="$1"
LOCK=/run/am60-touch-reenum.lock
exec 9>"$LOCK" 2>/dev/null
flock -n 9 || exit 0          # 已有重枚举在进行，跳过避免互相干扰

TOUCH=""
for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] || continue
    if [ "$(cat "$d/idVendor" 2>/dev/null)" = "1101" ] && [ "$(cat "$d/idProduct" 2>/dev/null)" = "0060" ]; then
        TOUCH="${d##*/}"
    fi
done

if [ -z "$TOUCH" ]; then
    logger -t $TAG "触控框不在 USB 总线上，跳过（下次插入时矩阵自然生效）"
    exit 0
fi

logger -t $TAG "软件重插 $TOUCH 以让 libinput 重读矩阵 '$WANT'"
echo -n "$TOUCH" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
sleep 2
echo -n "$TOUCH" > /sys/bus/usb/drivers/usb/bind 2>/dev/null
sleep 3
echo "$WANT" > /run/am60-touch-last-matrix 2>/dev/null   # 仅重插成功后才记，供下次去重
logger -t $TAG "重新枚举完成"
REENUM
    chmod 755 "$AM60_REENUM"
    setsid nohup "$AM60_REENUM" "$M" >/dev/null 2>&1 </dev/null &
    # 注意：last_applied 由 re-enum 脚本在【重插成功】后才写，避免静默失败时误标记
fi

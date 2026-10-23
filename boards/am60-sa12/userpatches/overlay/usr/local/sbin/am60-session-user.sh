#!/bin/bash
# 探测当前图形会话用户（标准 Armbian 首启向导建的账户名不固定，不写死 xiaobao）。
# 输出一行： "<UID> <用户名> <家目录>"
# 找不到图形会话时非零退出（调用方应静默退出，等下次事件再触发）。
set -u

UID_N=""

# 首选：持有 D-Bus 会话总线 socket 的用户（图形会话标志，最可靠）
for d in /run/user/*; do
    [ -S "$d/bus" ] || continue
    u=${d#/run/user/}
    case "$u" in (*[!0-9]*) continue ;; esac
    UID_N=$u
    break
done

# 兜底：占用 seat0 的 loginctl 会话
if [ -z "$UID_N" ] && command -v loginctl >/dev/null 2>&1; then
    UID_N=$(loginctl --no-legend list-sessions 2>/dev/null | awk '$4=="seat0"{print $2; exit}')
fi

[ -n "$UID_N" ] || exit 1

USER=$(id -un "$UID_N" 2>/dev/null) || exit 1
HOME=$(getent passwd "$UID_N" 2>/dev/null | cut -d: -f6) || exit 1
[ -n "$HOME" ] || exit 1

echo "$UID_N $USER $HOME"
exit 0

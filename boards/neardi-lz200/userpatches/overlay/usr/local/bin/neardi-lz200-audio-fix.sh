#!/bin/sh
# neardi-lz200-audio-fix.sh - Neardi LZ200 (RK3576) ES8323 3.5mm / 喇叭 出声修复
#
# === 根因（实测闭环，2026-10-27 / 持久化修复 2026-10-28）===
# ES8323 的模拟输出由三道 ALSA 闸门串联控制，必须全部打开音频才能到达 3.5mm：
#   1) 'Headphone Switch'  (numid=64) -> codec OUT1 (LOUT1/ROUT1, 耳机路径) 使能
#   2) 'Speaker Switch'    (numid=65) -> codec OUT2 (LOUT2/ROUT2, 喇叭路径) 使能
#   3) 'spk switch'        (numid=62) -> 外置功放 PA 供电 (spk-con GPIO) 使能
# 旧脚本只开了 (1)，且把 (3) 显式设 off、(2) 从没开 -> 三道只开一道 -> 静音。
# 另外 SAI 发送需路由到 SDO2（codec DIN 焊接在 sai1m0_sdo2 / gpio4 PB1）：
#   'SAI1 Transmit SDO2 Source Select'=0 让 lane0 -> SDO2（与 PATH_SEL 0xe4e6 一致）。
# 机器层 DAPM pin 'Headphone'/'Speaker' 驱动 hp-con/spk-con GPIO，顺手确保 on。
#
# === 持久化坑（2026-10-28 golden test 发现）===
# alsa-restore.service 会在本服务之后把 /var/lib/alsa/asound.state（默认 off）重新
#  apply，覆盖我们设的 ON。修复：① 服务 After=alsa-restore.service 确保最后跑；
#  ② 设完控件后 alsactl store 把 ON 固化进 asound.state，后续 restore 读到 ON（幂等）。
# 本脚本只动用户态 ALSA 控件，不改 DTS/驱动；控件名跨内核 numid 稳定。
set -u
ACTION="${1:-start}"
# 只走 stdout：systemd 会自动收录，避免 logger+stdout 双份重复日志
log() { echo "lz200-audio: $*"; }

# 等 ES8323 卡注册（按 codec 串 ES8323 匹配，与声卡友好名无关，改名不影响）
card=""
for i in $(seq 1 30); do
    card=$(aplay -l 2>/dev/null | awk '/ES8323/ {print $2}' | tr -d ':')
    [ -n "$card" ] && break
    sleep 1
done
[ -z "$card" ] && { log "es8388/ES8323 sound card not found; action '$ACTION' skipped"; exit 0; }

# 设置控件（带注册重试，规避 kcontrol 晚于声卡注册的竞态）
# 用法: set_ctl <name> <value> <label>
set_ctl() {
    name="$1"; val="$2"; label="$3"; tries=6
    for t in $(seq 1 $tries); do
        if amixer -c "$card" cget "name=$name" >/dev/null 2>&1; then
            if amixer -c "$card" cset "name=$name" "$val" >/dev/null 2>&1; then
                log "OK  $label ($name=$val)"; return 0
            fi
        fi
        sleep 0.5
    done
    log "WARN $label ($name) still absent after ${tries} tries"
    return 1
}

# 机器层 DAPM pin 是 simple 控件，必须用 sset/sget（cset name= 匹配不到）
# 用法: set_pin <name> <on|off> <label>
set_pin() {
    name="$1"; val="$2"; label="$3"; tries=6
    for t in $(seq 1 $tries); do
        if amixer -c "$card" sget "$name" >/dev/null 2>&1; then
            amixer -c "$card" sset "$name" "$val" >/dev/null 2>&1
            cur=$(amixer -c "$card" sget "$name" 2>/dev/null | grep -io '\[on\]\|\[off\]' | head -1)
            log "OK  $label ($name -> ${cur:-?})"; return 0
        fi
        sleep 0.5
    done
    log "WARN $label ($name) still absent after ${tries} tries"
    return 1
}

case "$ACTION" in
    start)
        # --- SAI 路由：lane0 -> SDO2（codec DIN 所在 pad）---
        set_ctl 'SAI1 Transmit SDO2 Source Select' 0 'SAI1 TX SDO2 Source (lane0->SDO2)'
        set_ctl 'SAI1 Receive SDIx Select' 1 'SAI1 RX SDIx'
        set_ctl 'SAI1 Transmit SDOx Select' 1 'SAI1 TX SDOx'

        # --- 三道输出闸门全开（关键修复）---
        set_ctl 'Headphone Switch' on "Headphone Switch (OUT1)"
        set_ctl 'Speaker Switch'   on "Speaker Switch (OUT2)"
        set_ctl 'spk switch'       on "spk switch (ext PA)"

        # --- 机器层 DAPM pin：驱动 hp-con / spk-con GPIO 供电 ---
        set_pin 'Headphone' on "DAPM Headphone pin (hp-con hi)"
        set_pin 'Speaker'  on "DAPM Speaker pin (spk-con)"

        # --- 固化：把 ON 态写入 asound.state，防止 alsa-restore 后续复位 ---
        sleep 1
        if alsactl store >/dev/null 2>&1; then
            log "alsactl store: persisted ON state to asound.state"
        else
            log "WARN alsactl store failed (non-fatal)"
        fi
        ;;
    stop)
        :   # 无需静音动作
        ;;
    *)
        log "unknown action '$ACTION'"; exit 1 ;;
esac
exit 0

#!/bin/bash
# ================================================================
#  Neardi LZ200 (RK3576) 音频设备友好名称 —— 跨发行版自动安装
#
#  支持: noble / bookworm / jammy / trixie / resolute
#  原理:
#    WirePlumber 0.4.x (jammy 22.04 / bookworm 12 / noble 24.04)
#        → /etc/wireplumber/main.lua.d/*.lua     (Lua 规则, glob 匹配)
#    WirePlumber 0.5.x (trixie 13 / resolute 25.10+)
#        → /etc/wireplumber/wireplumber.conf.d/*.conf (SPA-JSON, ~ 是正则)
#    两份配置共存是安全的：0.4 不扫描 conf.d，0.5 不认 lua.d（已实测）。
#
#  用法: sudo bash lz200-audio-names-install.sh
# ================================================================
set -u

OVERLAY_DIR="${OVERLAY_DIR:-}"   # 若脚本随 overlay 分发，可指向 overlay 根
LUA_DST=/etc/wireplumber/main.lua.d/51-lz200-audio-names.lua
CONF_DST=/etc/wireplumber/wireplumber.conf.d/51-lz200-audio-names.conf

[ "$(id -u)" -ne 0 ] && { echo "[ERR] 请用 root 运行: sudo bash $0"; exit 1; }

echo "══════ [1/5] 识别系统 ══════"
CODENAME="unknown"
[ -r /etc/os-release ] && . /etc/os-release
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-unknown}}"
echo "  发行版: ${PRETTY_NAME:-unknown}  (codename=$CODENAME)"

WP_VER=""
if command -v wireplumber >/dev/null 2>&1; then
    WP_VER="$(wireplumber --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
fi
[ -z "$WP_VER" ] && WP_VER="$(dpkg-query -W -f='${Version}' wireplumber 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
echo "  WirePlumber 版本: ${WP_VER:-未安装}"

# 决策：codename 优先，版本兜底
case "$CODENAME" in
    jammy|noble|bookworm)   KIND="lua"  ;;
    trixie|resolute)        KIND="conf" ;;
    *)
        # 未知发行版 → 按 WP 大版本判断
        MAJ="${WP_VER%%.*}"; MIN="${WP_VER#*.}"; MIN="${MIN%%.*}"
        if [ "${MAJ:-0}" -ge 1 ] || { [ "${MAJ:-0}" -eq 0 ] && [ "${MIN:-0}" -ge 5 ]; }; then
            KIND="conf"
        else
            KIND="lua"
        fi
        ;;
esac
echo "  → 采用配置类型: $KIND  (WP<0.5=lua / WP>=0.5=conf)"

echo "══════ [2/5] 写入配置（两份都放，互不干扰） ══════"
install -d /etc/wireplumber/main.lua.d /etc/wireplumber/wireplumber.conf.d

# 若随 overlay 分发则直接拷贝，否则用脚本内嵌内容
if [ -n "$OVERLAY_DIR" ] && [ -f "$OVERLAY_DIR$LUA_DST" ]; then
    install -m 0644 "$OVERLAY_DIR$LUA_DST"  "$LUA_DST"
    install -m 0644 "$OVERLAY_DIR$CONF_DST" "$CONF_DST"
else
cat > "$LUA_DST" <<'LUA_EOF'
-- Neardi LZ200 音频设备友好名称 (WirePlumber 0.4.x, glob 匹配)
alsa_monitor.rules = {
    { matches = { { { "device.name", "matches", "alsa_card.platform-es8388-sound" } } },
      apply_properties = { ["device.description"] = "3.5mm 耳机 (ES8323)", ["device.nick"] = "3.5mm 耳机" } },
    { matches = { { { "node.name", "matches", "alsa_output.platform-es8388-sound*" } } },
      apply_properties = { ["node.description"] = "3.5mm 耳机 (ES8323)", ["node.nick"] = "3.5mm 耳机",
                           ["priority.driver"] = 2000, ["priority.session"] = 2000 } },
    { matches = { { { "node.name", "matches", "alsa_input.platform-es8388-sound*" } } },
      apply_properties = { ["node.description"] = "板载麦克风 (ES8323)", ["node.nick"] = "板载麦克风",
                           ["priority.driver"] = 2000, ["priority.session"] = 2000 } },
    { matches = { { { "device.name", "matches", "alsa_card.platform-hdmi-sound" } } },
      apply_properties = { ["device.description"] = "HDMI 音频输出", ["device.nick"] = "HDMI" } },
    { matches = { { { "node.name", "matches", "alsa_output.platform-hdmi-sound*" } } },
      apply_properties = { ["node.description"] = "HDMI 音频输出", ["node.nick"] = "HDMI" } },
    { matches = { { { "device.name", "matches", "alsa_card.platform-dp0-sound" } } },
      apply_properties = { ["device.description"] = "DP (USB-C) 音频输出", ["device.nick"] = "DP" } },
    { matches = { { { "node.name", "matches", "alsa_output.platform-dp0-sound*" } } },
      apply_properties = { ["node.description"] = "DP (USB-C) 音频输出", ["node.nick"] = "DP" } },
}
LUA_EOF

cat > "$CONF_DST" <<'CONF_EOF'
# Neardi LZ200 音频设备友好名称 (WirePlumber 0.5.x, "~" = 正则)
monitor.alsa.rules = [
    { matches = [ { device.name = "alsa_card.platform-es8388-sound" } ]
      actions = { update-props = { device.description = "3.5mm 耳机 (ES8323)", device.nick = "3.5mm 耳机" } } }
    { matches = [ { node.name = "~alsa_output[.]platform-es8388-sound.*" } ]
      actions = { update-props = { node.description = "3.5mm 耳机 (ES8323)", node.nick = "3.5mm 耳机",
                                   priority.driver = 2000, priority.session = 2000 } } }
    { matches = [ { node.name = "~alsa_input[.]platform-es8388-sound.*" } ]
      actions = { update-props = { node.description = "板载麦克风 (ES8323)", node.nick = "板载麦克风",
                                   priority.driver = 2000, priority.session = 2000 } } }
    { matches = [ { device.name = "alsa_card.platform-hdmi-sound" } ]
      actions = { update-props = { device.description = "HDMI 音频输出", device.nick = "HDMI" } } }
    { matches = [ { node.name = "~alsa_output[.]platform-hdmi-sound.*" } ]
      actions = { update-props = { node.description = "HDMI 音频输出", node.nick = "HDMI" } } }
    { matches = [ { device.name = "alsa_card.platform-dp0-sound" } ]
      actions = { update-props = { device.description = "DP (USB-C) 音频输出", device.nick = "DP" } } }
    { matches = [ { node.name = "~alsa_output[.]platform-dp0-sound.*" } ]
      actions = { update-props = { node.description = "DP (USB-C) 音频输出", node.nick = "DP" } } }
]
CONF_EOF
fi
chmod 0644 "$LUA_DST" "$CONF_DST"
echo "  已写入: $LUA_DST"
echo "  已写入: $CONF_DST"

echo "══════ [3/5] 重启桌面音频栈 ══════"
restarted=0
for udir in /run/user/*; do
    [ -d "$udir" ] || continue
    uid="${udir##*/}"
    user="$(id -nu "$uid" 2>/dev/null)" || continue
    [ -S "$udir/bus" ] || continue
    echo "  桌面用户: $user (uid=$uid)"
    runuser -u "$user" -- env XDG_RUNTIME_DIR="$udir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$udir/bus" \
        systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null
    restarted=1
done
[ "$restarted" -eq 0 ] && echo "  未发现图形会话（server 镜像？）→ 配置已就位，登录后自动生效"

echo "══════ [4/5] 验证 ══════"
sleep 4
for udir in /run/user/*; do
    [ -S "$udir/bus" ] || continue
    uid="${udir##*/}"; user="$(id -nu "$uid" 2>/dev/null)" || continue
    out="$(runuser -u "$user" -- env XDG_RUNTIME_DIR="$udir" wpctl status 2>/dev/null | sed -n '/Audio/,/Video/p')"
    [ -n "$out" ] && { echo "$out" | sed 's/^/  /'; break; }
done

echo "══════ [5/5] 完成 ══════"
echo "  期望看到: 3.5mm 耳机 (ES8323) / HDMI 音频输出 / DP (USB-C) 音频输出 / 板载麦克风 (ES8323)"
echo "  若仍是 Built-in Audio: 确认 WP 版本与 KIND 是否匹配（本脚本判定为 $KIND）"

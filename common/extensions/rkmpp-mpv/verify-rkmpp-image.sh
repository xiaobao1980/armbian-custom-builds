#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# verify-rkmpp-image.sh — 烧卡后一键校验 RKMPP 硬解栈是否完整，并补齐播放配置
#
# 适用：RK35xx (RK3566/3568/3576/3588) + Armbian X11 桌面 + 本仓库 rkmpp-mpv 栈
# 用法：sudo bash verify-rkmpp-image.sh [可选: 测试片路径]
#        不带测试片 → 只做静态校验 + 补配置
#        带测试片   → 额外跑 8 秒真实播放，取 hwdec/掉帧/速度
#
# 返回值：0 = 全部通过；非 0 = 有 FAIL 项（逐项打印）
# -----------------------------------------------------------------------------
set -uo pipefail

PASS=0
FAIL=0
ok()   { echo "  [ OK ] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; }
chk()  { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi; }

echo "======================================================================"
echo " RKMPP 硬解栈烧卡后校验"
echo "======================================================================"

echo "--- 1. 板卡与内核 ---"
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
echo "  model : ${MODEL:-<unknown>}"
echo "  kernel: $(uname -r)"
echo "  os    : $(. /etc/os-release && echo "$PRETTY_NAME")"

echo "--- 2. CMA 连续内存（4K 硬解前提，须 512M）---"
CMATOTAL=$(awk '/CmaTotal/{print $2}' /proc/meminfo 2>/dev/null)
CMAMB=$((CMATOTAL / 1024))
echo "  CmaTotal: ${CMATOTAL} kB (${CMAMB} MB)"
[ "$CMAMB" -ge 500 ] && ok "CMA >= 500M" || {
  bad "CMA 仅 ${CMAMB}M，4K 可能掉帧"
  echo "        修法：在 /boot/armbianEnv.txt 追加 extraboardargs=cma=512M 后 reboot"
}
grep -q 'cma=512M' /boot/armbianEnv.txt 2>/dev/null \
  && ok "armbianEnv.txt 已固化 cma=512M" \
  || warn "armbianEnv.txt 未见 cma=512M（若重刷镜像会丢）"

echo "--- 3. VPU 设备节点与权限 ---"
# 自愈：v3.5 之前的安装只写了 mpp_service 一行（/dev/rga 停在 0600），
# 或 udev 规则存在但未在本次启动生效。这里补规则 + 重新 trigger，再逐项判定。
RULE=/etc/udev/rules.d/99-mpp.rules
if [ "$(id -u)" = "0" ]; then
  _changed=0
  [ -f "$RULE" ] || : > "$RULE"
  grep -q 'mpp_service' "$RULE" 2>/dev/null || {
    echo 'KERNEL=="mpp_service", MODE="0666"' >> "$RULE"; _changed=1; }
  grep -q '"rga"' "$RULE" 2>/dev/null || {
    echo 'KERNEL=="rga", MODE="0666"' >> "$RULE"; _changed=1; }
  if [ "$_changed" = "1" ]; then
    echo "  [自愈] 99-mpp.rules 缺项已补齐，重新触发 udev"
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
    sleep 1
  fi
fi
if [ -e /dev/mpp_service ]; then
  perm=$(stat -c '%a' /dev/mpp_service)
  echo "  /dev/mpp_service: 存在, 权限 $perm"
  case "$perm" in
    666|660) ok "/dev/mpp_service 权限可用" ;;
    *) bad "/dev/mpp_service 权限 $perm，非 root 无法硬解（udev 99-mpp.rules 未生效）" ;;
  esac
else
  bad "/dev/mpp_service 不存在（内核未开 VPU 或 DTB 不匹配）"
fi
# rga 只用于 ffmpeg 的 rkrga 缩放/格式转换滤镜，纯解码不走它，故仅告警不判失败
if [ -e /dev/rga ]; then
  perm=$(stat -c '%a' /dev/rga)
  echo "  /dev/rga: 存在, 权限 $perm"
  if [ "$perm" = "666" ] || [ "$perm" = "660" ]; then
    ok "/dev/rga 权限可用"
  elif [ "$(id -u)" = "0" ] && chmod 666 /dev/rga 2>/dev/null; then
    ok "/dev/rga 权限 ${perm}→666 已就地修正（udev 规则已补，重启后自动生效）"
  else
    warn "/dev/rga 权限 $perm —— 不影响 rkmpp 解码；只有 ffmpeg -vf scale_rkrga 等滤镜需要
         修法：echo 'KERNEL==\"rga\", MODE=\"0666\"' >> /etc/udev/rules.d/99-mpp.rules && udevadm trigger"
  fi
else
  warn "/dev/rga 不存在（rkrga 滤镜不可用，解码不受影响）"
fi

echo "--- 4. 库与解码器 ---"
PKGCFG=$(command -v pkg-config 2>/dev/null || command -v pkgconf 2>/dev/null || true)
if [ -n "$PKGCFG" ]; then
  for p in rockchip_mpp librga; do
    v=$("$PKGCFG" --modversion "$p" 2>/dev/null)
    [ -n "$v" ] && ok "$p = $v" || bad "$p 未安装"
  done
else
  # mpv 编译依赖 pkg-config，但镜像裁掉后仍可能被移除；用 .pc 文件兜底判定
  for p in rockchip_mpp librga; do
    _found=""
    for _d in /usr/local/lib/pkgconfig /usr/local/lib/*/pkgconfig; do
      [ -f "${_d}/${p}.pc" ] && { _found="${_d}/${p}.pc"; break; }
    done
    if [ -n "$_found" ]; then
      ok "$p .pc 存在（pkg-config 已移除，跳过版本号）"
    else
      bad "$p 未安装"
    fi
  done
fi

FFMPEG=""
for c in /usr/local/bin/ffmpeg /usr/bin/ffmpeg; do
  [ -x "$c" ] && { FFMPEG="$c"; break; }
done
if [ -n "$FFMPEG" ]; then
  N=$("$FFMPEG" -decoders 2>/dev/null | grep -c _rkmpp)
  echo "  ffmpeg: $FFMPEG"
  echo "  rkmpp 解码器数: $N"
  [ "$N" -ge 8 ] && ok "ffmpeg rkmpp 解码器 $N 个" || bad "ffmpeg rkmpp 解码器仅 $N 个（期望 10）"
else
  bad "未找到 ffmpeg"
fi

if command -v mpv >/dev/null; then
  echo "  mpv: $(mpv --version 2>/dev/null | head -1)"
  HN=$(mpv --hwdec=help 2>/dev/null | grep -c rkmpp)
  echo "  mpv --hwdec=help 中 rkmpp 项数: $HN"
  [ "$HN" -ge 2 ] && ok "mpv 原生 rkmpp 后端存在（$HN 项）" \
                  || bad "mpv 无 rkmpp 后端（$HN 项）——栈没编进去或装成了社区版 mpv"
  ldd "$(command -v mpv)" 2>/dev/null | grep -q 'ffmpeg-rkmpp' \
    && ok "mpv 链接到隔离 ffmpeg-rkmpp" \
    || warn "mpv 未链接 /usr/local/lib/ffmpeg-rkmpp（可能走系统 libav，硬解仍可用但需复核）"
else
  bad "未找到 mpv"
fi

echo "--- 5. 播放配置（全屏 / 播完自动退出）---"
CONF=""
for c in /etc/mpv/mpv.conf /usr/local/etc/mpv/mpv.conf; do
  [ -f "$c" ] && { CONF="$c"; break; }
done
if [ -n "$CONF" ]; then
  echo "  配置文件: $CONF"
  NEED_FS=0
  NEED_KO=0
  grep -qE '^\s*fullscreen\s*=\s*yes' "$CONF" || NEED_FS=1
  grep -qE '^\s*keep-open\s*=\s*no'  "$CONF" || NEED_KO=1
  if [ "$NEED_FS" -eq 0 ] && [ "$NEED_KO" -eq 0 ]; then
    ok "fullscreen=yes / keep-open=no 已就位"
  else
    warn "缺少配置（fullscreen=${NEED_FS} keep-open=${NEED_KO}），正在补齐…"
    if [ "$(id -u)" -eq 0 ]; then
      grep -qE '^\s*fullscreen' "$CONF" || echo 'fullscreen=yes          # 默认全屏播放' >> "$CONF"
      grep -qE '^\s*keep-open'  "$CONF" || echo 'keep-open=no            # 播完立即退出' >> "$CONF"
      # 补齐 /usr/local/etc 软链（自编译 mpv 只读 prefix 下的配置）
      if [ -d /usr/local/etc/mpv ] && [ ! -e /usr/local/etc/mpv/mpv.conf ]; then
        ln -sf /etc/mpv/mpv.conf /usr/local/etc/mpv/mpv.conf
      fi
      ok "已补齐播放配置"
    else
      bad "需 root 才能写配置，请用 sudo 重跑本脚本"
    fi
  fi
else
  bad "未找到 mpv.conf"
fi

echo "--- 5.5 桌面菜单项（开始菜单/应用查找器里能否搜到 mpv）---"
DESKTOP_FILE=/usr/share/applications/mpv.desktop
DESKTOP_ICON=/usr/share/icons/hicolor/scalable/apps/rkmpp-mpv.svg
LEGACY_ICON=/usr/share/icons/hicolor/scalable/apps/mpv.svg
DESK_OK=0
[ -f "$DESKTOP_FILE" ] && grep -q '^Exec=/usr/local/bin/mpv-desktop' "$DESKTOP_FILE" \
  && grep -q '^Icon=rkmpp-mpv' "$DESKTOP_FILE" && DESK_OK=1
if [ "$DESK_OK" = "1" ]; then
  ok "菜单项存在且指向 wrapper: $DESKTOP_FILE"
else
  if [ "$(id -u)" = "0" ]; then
    mkdir -p /usr/share/applications
    cat > "$DESKTOP_FILE" <<'DESKEOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=mpv
Name[zh_CN]=mpv 播放器
GenericName=Media Player
GenericName[zh_CN]=媒体播放器
Comment=RKMPP hardware-accelerated video player
Comment[zh_CN]=RKMPP 硬件加速视频播放器（RK35xx）
Exec=/usr/local/bin/mpv-desktop %U
TryExec=/usr/local/bin/mpv
Icon=rkmpp-mpv
Terminal=false
Categories=AudioVideo;Video;Player;
MimeType=video/mp4;video/x-matroska;video/webm;video/quicktime;video/x-msvideo;video/mp2t;video/x-flv;video/mpeg;audio/mpeg;audio/flac;audio/x-wav;audio/ogg;
Keywords=mpv;player;video;rkmpp;hardware;
StartupNotify=false
DESKEOF
    chmod 644 "$DESKTOP_FILE"
    ok "菜单项缺失或 Exec/Icon 过旧，已写入 wrapper 版本（重开应用菜单即可搜到）"
  else
    bad "缺 $DESKTOP_FILE（需 root 创建）"
  fi
fi
if [ -f "$DESKTOP_ICON" ]; then
  ok "菜单图标存在: $DESKTOP_ICON"
elif [ "$(id -u)" = "0" ]; then
  mkdir -p "$(dirname "$DESKTOP_ICON")"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">' \
    '  <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">' \
    '    <stop offset="0" stop-color="#9c27b0"/><stop offset="1" stop-color="#5e1273"/>' \
    '  </linearGradient></defs>' \
    '  <rect x="4" y="4" width="120" height="120" rx="26" fill="url(#g)"/>' \
    '  <path d="M52 38 L52 90 L94 64 Z" fill="#ffffff"/>' \
    '</svg>' > "$DESKTOP_ICON"
  chmod 644 "$DESKTOP_ICON"
  ok "菜单图标缺失，已补（Icon=rkmpp-mpv，独立命名避免被主题自带 mpv.svg 覆盖）"
else
  warn "缺 $DESKTOP_ICON —— 菜单项会显示主题的通用图标"
fi
# 旧版遗留（v3.6 及以前用 mpv.svg，会被 Numix-Circle 等主题自带同名图标顶掉）
if [ -f "$LEGACY_ICON" ] && [ "$(id -u)" = "0" ]; then
  rm -f "$LEGACY_ICON"
  ok "已清理旧图标 mpv.svg（改用 rkmpp-mpv.svg，避免与主题同名图标冲突）"
fi
# 图标缓存：GTK 只按 icon-theme.cache 查找，新增图标不重建缓存 = 菜单永远显示通用图标，
# 且没有任何报错（本栈线上真实踩过）。必须 -f 强制重建。
ICON_CACHE=/usr/share/icons/hicolor/icon-theme.cache
if [ "$(id -u)" = "0" ]; then
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -q /usr/share/icons/hicolor 2>/dev/null \
      && ok "图标缓存已强制重建（gtk-update-icon-cache -f）" \
      || warn "图标缓存重建失败，菜单可能仍显示通用图标"
  else
    rm -f "$ICON_CACHE" 2>/dev/null || true
    ok "系统无 gtk-update-icon-cache，已移除旧缓存（GTK 改为直接扫描目录）"
  fi
  command -v update-desktop-database >/dev/null && update-desktop-database /usr/share/applications 2>/dev/null || true
else
  warn "非 root，跳过图标缓存重建（菜单图标不刷新时执行：sudo gtk-update-icon-cache -f /usr/share/icons/hicolor）"
fi
WRAP=/usr/local/bin/mpv-desktop
if [ -x "$WRAP" ]; then
  ok "桌面入口 wrapper 存在: $WRAP"
elif [ "$(id -u)" = "0" ]; then
  cat > "$WRAP" <<'WEOF'
#!/bin/sh
# 桌面菜单入口（mpv 无参数会打印用法并退出，这里改成开 idle 窗口）
if [ "$#" -eq 0 ]; then
  exec /usr/local/bin/mpv --player-operation-mode=pseudo-gui --no-fullscreen --force-window=yes
fi
exec /usr/local/bin/mpv -- "$@"
WEOF
  chmod 0755 "$WRAP"
  ok "桌面入口 wrapper 缺失，已创建（无参时开 idle 窗口，可拖拽文件）"
else
  warn "缺 $WRAP —— 从菜单点开不会有窗口（需 root 创建）"
fi
if [ -f "$DESKTOP_FILE" ]; then
  if grep -q '^Exec=/usr/local/bin/mpv' "$DESKTOP_FILE" && grep -q '^\[Desktop Entry\]' "$DESKTOP_FILE"; then
    ok "菜单项 Exec 指向 /usr/local/bin/mpv*（非社区版）"
  else
    warn "菜单项 Exec 不是 /usr/local/bin/mpv，可能指向 apt 版 mpv"
  fi
  command -v update-desktop-database >/dev/null && update-desktop-database /usr/share/applications 2>/dev/null || true
fi
# 端到端：让 GTK 真正按主题链解析一次 Icon 名（这是"菜单里图标不对"的最终判据）
if [ "$(id -u)" = "0" ] && command -v python3 >/dev/null 2>&1 && python3 -c 'import gi' >/dev/null 2>&1; then
  ICON_PY=$(mktemp /tmp/iconprobe.XXXXXX.py)
  cat > "$ICON_PY" <<'PYEOF'
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk
Gtk.init([])
info = Gtk.IconTheme.get_default().lookup_icon('rkmpp-mpv', 24, 0)
print(info.get_filename() if info else '')
PYEOF
  chmod 644 "$ICON_PY"
  XPU=""
  for h in /home/*; do [ -f "$h/.Xauthority" ] && { XPU=$(basename "$h"); break; }; done
  if [ -n "$XPU" ]; then
    ICON_RES=$(runuser -u "$XPU" -- env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="/home/$XPU/.Xauthority" \
               python3 "$ICON_PY" 2>/dev/null)
    case "$ICON_RES" in
      *rkmpp-mpv.svg) ok "GTK 已能解析菜单图标 → $ICON_RES" ;;
      "") warn "GTK 解析 Icon=rkmpp-mpv 返回空（缓存未生效？先 gtk-update-icon-cache -f，再 xfce4-panel -r）" ;;
      *)  warn "GTK 把 Icon 解析到了别的文件：$ICON_RES" ;;
    esac
  fi
  rm -f "$ICON_PY"
else
  warn "无 python3-gi 或非 root，跳过 GTK 图标解析校验"
fi

echo "--- 6. 真实播放测试（可选）---"
CLIP="${1:-}"
if [ -z "$CLIP" ]; then
  echo "  （未指定测试片，跳过。用法：sudo bash $0 /path/to/4k.mp4）"
elif [ ! -f "$CLIP" ]; then
  warn "测试片不存在，跳过：$CLIP"
else
  if [ -z "${DISPLAY:-}" ]; then
    echo "  DISPLAY 未设置，自动尝试 :0"
    export DISPLAY=:0
  fi
  # root 拿不到 X 会话的 MIT cookie（.Xauthority 属登录用户），直接跑会
  # "Failed initializing any suitable GPU context!" 而误判为硬解失效。
  # 因此本脚本虽需 sudo 改配置，播放测试必须降权到 X 会话属主执行。
  RUN=()
  if [ "$(id -u)" -eq 0 ]; then
    XUSER=""
    for h in /home/*; do
      [ -f "$h/.Xauthority" ] && { XUSER=$(basename "$h"); break; }
    done
    if [ -n "$XUSER" ]; then
      echo "  降权到 X 会话属主: $XUSER"
      export XAUTHORITY="/home/$XUSER/.Xauthority"
      RUN=(runuser -u "$XUSER" -- env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY")
    else
      warn "未找到任何 /home/*/.Xauthority，以 root 直接播放（可能因无 X 权限失败）"
    fi
  fi
  OUT=$(mktemp)
  "${RUN[@]}" timeout 12 mpv --hwdec=rkmpp --no-audio --msg-level=all=info "$CLIP" >"$OUT" 2>&1
  if grep -qi 'Using hardware decoding (rkmpp)' "$OUT"; then
    ok "播放日志确认 rkmpp 硬解生效"
    grep -E 'VO: \[|Using hardware' "$OUT" | sed 's/^/         /' | head -3
    grep -q 'drm_prime' "$OUT" && ok "零拷贝帧格式 drm_prime（非 CPU 拷贝）" \
                               || warn "未见 drm_prime，可能退化为 rkmpp-copy"
  else
    bad "播放日志未见 rkmpp 硬解，可能已退化为软解"
    grep -iE 'error|fail|Using hardware' "$OUT" | head -3 | sed 's/^/         /'
  fi
  rm -f "$OUT"
fi

echo "======================================================================"
echo " 结果：PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo " ✅ 硬解栈完整可用" || echo " ❌ 有失败项，请按上方提示处理"
echo "======================================================================"
exit "$FAIL"

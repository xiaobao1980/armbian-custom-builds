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
  case "$perm" in
    666|660) ok "/dev/rga 权限可用" ;;
    *) warn "/dev/rga 权限 $perm —— 不影响 rkmpp 解码；只有 ffmpeg -vf scale_rkrga 等滤镜需要
         修法：echo 'KERNEL==\"rga\", MODE=\"0666\"' >> /etc/udev/rules.d/99-mpp.rules && udevadm trigger" ;;
  esac
else
  warn "/dev/rga 不存在（rkrga 滤镜不可用，解码不受影响）"
fi

echo "--- 4. 库与解码器 ---"
if command -v pkg-config >/dev/null; then
  for p in rockchip_mpp librga; do
    v=$(pkg-config --modversion "$p" 2>/dev/null)
    [ -n "$v" ] && ok "$p = $v" || bad "$p 未安装"
  done
else
  warn "pkg-config 不存在，跳过库版本校验"
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

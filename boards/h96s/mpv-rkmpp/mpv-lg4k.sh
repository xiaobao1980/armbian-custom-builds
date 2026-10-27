#!/usr/bin/env bash
#
# mpv-lg4k — 自动切 TTY / DRM 直出零拷贝播放 4K（VP9 / H264）视频
# ---------------------------------------------------------------------------
# 适用平台 : RK3566 / RK3568 / RK3576 / RK3588
#            已编译带 rkmpp 补丁的 mpv（见同目录 build-mpv-rkmpp.sh）
#            任意 Panfrost / Mali + mainline 或 vendor 内核
#
# 为什么要切 TTY：
#   X11 / Wayland 桌面下，mpv 的 rkmpp 硬解只能走 rkmpp-copy 路径
#   （解码帧 显存 → CPU → GPU 双拷贝）。RK3576 + VP9 4K60 实测仅 ~0.07×（卡到 4~7fps）。
#   切到本地控制台（VT）+ --gpu-context=drm 后，drmprime_rkmpp 走零拷贝：
#   rkmpp 解码帧直接送 DRM overlay plane 直出，4K60 VP9 / H264 均可满帧。
#
# 行为：
#   · 在桌面（X11/Wayland）里运行 → 自动用 openvt 切到空闲 VT 播放，结束自动切回桌面
#   · 已在本地控制台（TTY）运行   → 直接 DRM 直出
#   · 纯 SSH（pts）无显示          → 报错退出
#
# 防冻屏看门狗（关键）：
#   mpv 在 DRM 上下文拆解（teardown）阶段偶发死锁，进程不死、不退出，
#   导致 openvt -w 永远等不到结束而冻屏。本脚本在后台挂看门狗：
#   检测到日志出现 "video EOF" 后若 15s 仍不退出，强制 kill -9 mpv 并 chvt 切回桌面；
#   正常结束时 openvt -w 也会切回，双保险。本地控制台分支同样受看门狗保护。
#
# 默认播放 ~/Videos/LG-UHD-4K_60FPS.mkv（无参数时）
# ---------------------------------------------------------------------------

set -uo pipefail   # 注意：不用 -e，避免 mpv 异常退出码误杀后续 chvt 兜底逻辑

# ========================= 配置 =========================
DEFAULT_VIDEO="${HOME}/Videos/LG-UHD-4K_60FPS.mkv"
# 可选：固定 DRM connector，如 HDMI-A-1 / DSI-1（多屏时避免选错屏）
DRM_CONNECTOR="${DRM_CONNECTOR:-}"

# mpv 二进制探测（优先级：环境变量 > /opt/mpv-rkmpp > /usr/local/bin > PATH）
detect_mpv() {
  local c
  for c in "${MPV:-}" /opt/mpv-rkmpp/bin/mpv /usr/local/bin/mpv "$(command -v mpv 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

usage() {
  cat <<'EOF'
mpv-lg4k — DRM 直出零拷贝 4K 播放器

用法:
  mpv-lg4k [选项] [视频文件]

选项:
  -x, --x11        不切 TTY，直接在当前桌面会话用 rkmpp-copy 播放（慢但方便）
  -v, --verbose    显示 vd / vo=gpu / hwdec 详细日志（用于确认零拷贝是否生效）
  -c, --connector  指定 DRM connector（如 HDMI-A-1），多屏时必填
  -h, --help       显示本帮助

说明:
  默认在 X11/Wayland 下会自动切到空闲 TTY 用 --gpu-context=drm 直出，
  走 drmprime_rkmpp 零拷贝（4K60 VP9 满帧）；播放结束自动切回桌面。
  无任何外部干预时若 mpv 在拆解阶段卡死，后台看门狗会强制结束并切回桌面，不会冻屏。
  无参数时播放 ~/Videos/LG-UHD-4K_60FPS.mkv。
EOF
}

# ========================= 会话检测 =========================
is_x11() {
  [ -n "${DISPLAY:-}" ] && [ -e "/tmp/.X11-unix/X${DISPLAY#:}" ]
}
is_wayland() { [ -n "${WAYLAND_DISPLAY:-}" ]; }
# 本地控制台：/dev/ttyN（N 为数字），排除 SSH 的 /dev/pts/N
is_local_console() {
  local t; t="$(tty 2>/dev/null)" || return 1
  [[ "$t" =~ ^/dev/tty[0-9]+$ ]]
}

# 取当前板子活跃 VT 编号（输出到板子物理显示时用），优先读 sysfs（SSH 下也可用）
home_vt() {
  local a
  a="$(cat /sys/class/tty/tty0/active 2>/dev/null)"
  case "$a" in
    tty[0-9]*) echo "${a#tty}" ;;
    *) echo 7 ;;
  esac
}

# ========================= 参数解析 =========================
VERBOSE=0
FORCE_X11=0
VIDEO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -x|--x11)      FORCE_X11=1 ;;
    -v|--verbose)  VERBOSE=1 ;;
    -c|--connector) shift; DRM_CONNECTOR="$1" ;;
    -h|--help)     usage; exit 0 ;;
    --) shift; VIDEO="${VIDEO:-$1}"; break ;;
    -*) echo "未知选项: $1" >&2; usage; exit 1 ;;
    *)  VIDEO="${VIDEO:-$1}" ;;
  esac
  shift
done
VIDEO="${VIDEO:-$DEFAULT_VIDEO}"

# ========================= 前置检查 =========================
MPV_BIN="$(detect_mpv)" || {
  echo "错误: 找不到带 rkmpp 的 mpv（已查 /opt/mpv-rkmpp/bin/mpv、/usr/local/bin/mpv、PATH）。" >&2
  echo "       请先运行同目录 build-mpv-rkmpp.sh 编译安装。" >&2
  exit 1
}

if ! "$MPV_BIN" --hwdec=help 2>/dev/null | grep -q rkmpp; then
  echo "警告: 该 mpv 的 --hwdec=help 不含 rkmpp，硬解未生效，将退化为软解（CPU 吃满且 4K 必卡）。" >&2
fi

if [ ! -f "$VIDEO" ]; then
  echo "错误: 视频文件不存在: $VIDEO" >&2
  exit 1
fi

command -v openvt >/dev/null 2>&1 || \
  echo "警告: openvt 缺失（apt install util-linux），桌面下将无法自动切 TTY。" >&2

# ========================= 组装 mpv 参数 =========================
# mode: drm（零拷贝直出） | x11（rkmpp-copy，慢）
build_args() {
  local mode="$1"
  MPV_ARGS=( "$VIDEO" --hwdec=rkmpp --vo=gpu --fs --keep-open=no )
  if [ "$mode" = "drm" ]; then
    MPV_ARGS+=( --gpu-context=drm )
    [ -n "$DRM_CONNECTOR" ] && MPV_ARGS+=( --drm-connector="$DRM_CONNECTOR" )
  fi
  if [ "$VERBOSE" -eq 1 ]; then
    # 注意：mpv 的 msg-level 模块名含 '/' 须写成 vo/gpu，不能写 vo=gpu=info（会报参数解析失败）；
    # 这里只用无歧义模块 vd/hwdec/statusline，零拷贝证据在 vd 模块的 "Using hardware decoding" 行。
    MPV_ARGS+=( --msg-level=vd=v,hwdec=v,statusline=v )
  else
    MPV_ARGS+=( --really-quiet )
  fi
}

# ========================= mpv 执行 + 看门狗 =========================
# run_mpv [home_vt]
#   后台跑 mpv（MPV_ARGS 已由 build_args 构建），并挂看门狗防拆解死锁；
#   home_vt 非空时，播完/强杀后都会 chvt 切回该 VT（桌面场景）。
run_mpv() {
  local home_vt="${1:-}"
  local log
  if [ -n "${MPV_LG4K_LOG:-}" ]; then
    log="$MPV_LG4K_LOG"
  else
    log="$(mktemp /tmp/mpv-lg4k.XXXX.log)"
  fi
  MPV_ARGS+=( --log-file="$log" )

  "$MPV_BIN" "${MPV_ARGS[@]}" &
  local mpvpid=$!
  local wdpid

  # 看门狗：检测到 "video EOF" 后 15s 仍不退出 → 强制 kill -9
  (
    set +e
    local t=0
    while kill -0 "$mpvpid" 2>/dev/null; do
      if grep -q "video EOF" "$log" 2>/dev/null; then
        sleep 15
        if kill -0 "$mpvpid" 2>/dev/null; then
          echo "[watchdog] mpv 在 DRM 拆解阶段卡死，强制结束" >> "$log"
          kill -9 "$mpvpid" 2>/dev/null
        fi
        break
      fi
      sleep 2
      t=$((t + 2))
      # 6 小时硬上限，防止任何意外长挂
      if [ "$t" -ge 21600 ]; then
        kill -9 "$mpvpid" 2>/dev/null
        break
      fi
    done
    [ -n "$home_vt" ] && chvt "$home_vt" 2>/dev/null
    [ -z "${MPV_LG4K_LOG:-}" ] && rm -f "$log"
  ) &
  wdpid=$!

  wait "$mpvpid" 2>/dev/null || true
  [ -n "$home_vt" ] && chvt "$home_vt" 2>/dev/null
  wait "$wdpid" 2>/dev/null || true
  return 0
}

# ========================= openvt 切 VT + DRM 直出（需 root） =========================
# 逻辑：后台 openvt 切到空闲 VT 跑 mpv（脚本在目标 VT 上会走 is_local_console 分支）；
#       外层挂看门狗，mpv 拆解卡死时强杀并切回 home VT；正常结束由 openvt -w 切回。
#       支持 SSH 触发：输出到板子物理 HDMI/屏，而非 SSH 会话本身（已验证 openvt 在 SSH 下可切板子物理显示）。
do_openvt_dance() {
  command -v openvt >/dev/null 2>&1 || {
    echo "错误: 缺少 openvt（apt install util-linux），无法自动切 TTY。" >&2
    exit 1
  }
  export MPV_LG4K_HOME_VT="${MPV_LG4K_HOME_VT:-$(home_vt)}"
  export MPV_LG4K_LOG="$(mktemp /tmp/mpv-lg4k.XXXX.log)"
  openvt -s -w -- "$0" "$@" &
  OPID=$!
  (
    set +e
    while kill -0 "$OPID" 2>/dev/null; do
      if grep -q "video EOF" "$MPV_LG4K_LOG" 2>/dev/null; then
        sleep 15
        if kill -0 "$OPID" 2>/dev/null; then
          echo "[watchdog] mpv 拆解阶段卡死，强制结束并切回桌面" >> "$MPV_LG4K_LOG"
          pkill -9 -f 'gpu-context=drm' 2>/dev/null
        fi
      fi
      sleep 2
    done
    chvt "$MPV_LG4K_HOME_VT" 2>/dev/null
  ) &
  WD=$!
  wait "$OPID" 2>/dev/null || true
  kill -9 "$WD" 2>/dev/null
  chvt "$MPV_LG4K_HOME_VT" 2>/dev/null
  rm -f "$MPV_LG4K_LOG"
  exit 0
}

# ========================= 执行分支 =========================
# 1) 显式要求桌面模式（rkmpp-copy 预览，慢但方便；同样受看门狗保护）
if [ "$FORCE_X11" -eq 1 ]; then
  echo "（X11 模式：rkmpp-copy，4K60 VP9 会卡，仅作方便预览）" >&2
  build_args x11
  run_mpv
  exit 0
fi

# 2) 桌面会话（X11 / Wayland）：需 root 切到本地 TTY 做 DRM 直出
if is_x11 || is_wayland; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "检测到桌面会话，需 root 权限切到本地 TTY 进行 DRM 直出零拷贝..." >&2
    if command -v pkexec >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
      exec pkexec env MPV_LG4K_HOME_VT="$(home_vt)" "$0" "$@"
    else
      exec sudo env MPV_LG4K_HOME_VT="$(home_vt)" "$0" "$@"
    fi
  fi
  do_openvt_dance "$@"
fi

# 3) 已在本地控制台（被 openvt 切过来，或直接在本地点火）：直接 DRM 直出
if is_local_console; then
  build_args drm
  # 不传 home_vt：本分支已在目标 VT，切回交给外层 openvt -w / 外层看门狗
  run_mpv
  exit 0
fi

# 4) 其它（SSH / headless）：只要板子接了显示且能切 VT，仍可驱动物理屏做 DRM 直出
#    （输出到板子 HDMI/屏，而非 SSH 会话本身；之前已验证 openvt 在 SSH 下可切板子物理显示）
if command -v openvt >/dev/null 2>&1 && { [ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null 2>&1; }; then
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo env MPV_LG4K_HOME_VT="$(home_vt)" "$0" "$@"
  fi
  do_openvt_dance "$@"
fi

# 5) 兜底：真无任何可输出显示设备
echo "错误: 当前环境无法输出到显示设备（非桌面、非本地控制台，且无 openvt/sudo）。" >&2
echo "       如需在板子物理屏播放，请在板子本地 TTY/桌面运行，或确保板子已接显示器且可用 openvt 切 VT。" >&2
exit 1

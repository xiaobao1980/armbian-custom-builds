#!/usr/bin/env bash
# =============================================================================
# install-rkmpp-stack.sh — 单板一键安装 RK35xx RKMPP + mpv 硬解栈
# -----------------------------------------------------------------------------
# 用途：在任意一块已具备「vendor BSP 内核 + X11」的 RK35xx 板上，
#       自动安装 rkmpp+mpv 用户态栈，无需每次都从源码编译。
#
# 原理（与 CI 的 2.5a 守卫一致）：
#   1. 探测 架构 / 发行版（arch + /etc/os-release）。
#   2. 按 (发行版, 架构) 匹配 GitHub Release 上的预编译 deb：
#        rkmpp-stack-v<VER>-<codename>-<arch>   （跨发行版/跨架构命名）
#        rkmpp-stack-v<VER>-<codename>
#        rkmpp-stack-v<VER>-2 / -1              （仅 trixie/arm64 历史命名）
#   3. 拉到 deb 后**必须**校验其内 build-info 的 ARCH/DISTRO_CODENAME 与本品一致，
#      不一致即丢弃、尝试下一个 tag —— 绝不把错误发行版的包硬装上去。
#   4. 拉不到且 RKMPP_ALLOW_REBUILD=yes → 本地重编重打（耗时，需网络+编译依赖）。
#   5. dpkg -i 安装，做硬解自检（rkmpp 解码器数 / 设备节点 / 库路径）。
#
# 重要前提（deb 不含，本脚本只警告不修复）：
#   * vendor BSP 内核提供 /dev/mpp_service、/dev/rga
#   * CMA=512M（/boot/armbianEnv.txt 写 extraboardargs=cma=512M 并 reboot）
#   * X11 会话（mpv 走 vo=gpu）
#
# 用法：
#   sudo bash install-rkmpp-stack.sh                 # 探测+拉包+装+自检
#   sudo bash install-rkmpp-stack.sh --check         # 只做前置检查+已装自检，不安装
#   sudo RKMPP_DEB=/path/to.deb bash install-rkmpp-stack.sh   # 用本地 deb
#   sudo GH_TOKEN=ghp_xxx bash install-rkmpp-stack.sh          # 指定 token 拉私有 Release
#   sudo RKMPP_ALLOW_REBUILD=yes bash install-rkmpp-stack.sh   # 无预编译包时允许本地重编
#
# 环境变量：
#   RKMPP_DEB            本地 deb 路径（最高优先级，跳过网络）
#   GH_TOKEN            GitHub token（私有仓库拉 Release 必需；也可 gh auth login）
#   RKMPP_ALLOW_REBUILD yes 才允许在无预编译包时本地重编（默认否，避免意外长编译）
#   RKMPP_SRC           源码目录（重编回退用，默认脚本同级仓库根）
# =============================================================================
set -uo pipefail

STACK_VER="${STACK_VER:-0.41.0}"
REPO="${REPO:-xiaobao1980/armbian-custom-builds}"
PKG=rkmpp-stack
WORKDIR="$(mktemp -d)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- 不是 root 则提权重跑（显式透传需要的 env，避免 sudo -E 被 env_keep 限制）----
# 仅在作为脚本直接执行时才提权/运行 main；被 source 时不触发（便于单测函数）。
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "$(id -u)" -ne 0 ]; then
  exec sudo RKMPP_DEB="${RKMPP_DEB:-}" GH_TOKEN="${GH_TOKEN:-}" \
            RKMPP_ALLOW_REBUILD="${RKMPP_ALLOW_REBUILD:-}" RKMPP_SRC="${RKMPP_SRC:-}" \
            bash "$0" "$@"
fi

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "  ⚠️  $*" >&2; }
ok()   { echo "  ✅ $*"; }
die()  { echo "  ❌ $*" >&2; exit 1; }

ARCH=""; DISTRO_ID=""; DISTRO_CODENAME=""; GLIBC=""

detect_target() {
  command -v dpkg >/dev/null 2>&1 || die "本脚本面向 Debian/Ubuntu 系（需要 dpkg），当前系统不支持"
  ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    DISTRO_ID="$(. /etc/os-release; echo "${ID:-}")"
    DISTRO_CODENAME="$(. /etc/os-release; echo "${VERSION_CODENAME:-${DEBIAN_CODENAME:-}}")"
  fi
  [ -n "$DISTRO_CODENAME" ] || warn "无法从 /etc/os-release 取得发行版代号，跨发行版匹配可能失败"
  GLIBC="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  log "目标板: arch=${ARCH} distro=${DISTRO_ID}/${DISTRO_CODENAME} glibc=${GLIBC}"
}

# ---- 前置检查（只警告，不阻断：deb 可装，但硬解需这些）----
check_prereqs() {
  echo "== 前置检查（缺失仅影响硬解，不阻断安装）=="
  if [ -e /dev/mpp_service ]; then ok "/dev/mpp_service 存在（vendor 内核）"; else warn "/dev/mpp_service 缺失 → 需 vendor BSP 内核"; fi
  if [ -e /dev/rga ]; then
    local perms; perms="$(stat -c '%a' /dev/rga 2>/dev/null)"
    if [ "$perms" = "666" ]; then ok "/dev/rga 存在且权限 666"; else warn "/dev/rga 权限为 $perms（期望 666，udev 规则应修正）"; fi
  else warn "/dev/rga 缺失 → 需 vendor BSP 内核 + rga 驱动"; fi
  local cma=0
  if grep -q 'cma=512M' /boot/armbianEnv.txt 2>/dev/null; then ok "armbianEnv.txt 含 cma=512M"; else warn "armbianEnv.txt 未设 cma=512M（4K 硬解需 512M，否则掉帧/失败）"; fi
  cma="$(awk '/^CmaTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  if [ -n "$cma" ] && [ "$cma" -ge 524288 ] 2>/dev/null; then ok "CmaTotal=${cma}kB (>=512M)"; else warn "CmaTotal=${cma:-?}kB (<512M)"; fi
  if [ -n "${DISPLAY:-}" ] || pgrep -x Xorg >/dev/null 2>&1; then ok "检测到 X11 会话"; else warn "未检测到 X11 会话（mpv 走 vo=gpu，需 X）"; fi
}

# ---- 候选 Release tag ----
candidate_tags() {
  echo "rkmpp-stack-v${STACK_VER}-${DISTRO_CODENAME}-${ARCH}"
  echo "rkmpp-stack-v${STACK_VER}-${DISTRO_CODENAME}"
  if [ "${DISTRO_CODENAME}" = "trixie" ] && [ "${ARCH}" = "arm64" ]; then
    echo "rkmpp-stack-v${STACK_VER}-2"
    echo "rkmpp-stack-v${STACK_VER}-1"
  fi
}

# ---- 从私有 Release 用 curl+GH_TOKEN 拉取匹配 deb 的下载 URL ----
gh_release_asset_url() {
  local tag="$1" token="$2"
  local api="https://api.github.com/repos/${REPO}/releases/tags/${tag}"
  local hdr=( "-H" "Accept: application/vnd.github+json" )
  [ -n "$token" ] && hdr+=( "-H" "Authorization: Bearer ${token}" )
  local json; json="$(curl -fsSL "${hdr[@]}" "$api" 2>/dev/null)" || return 1
  # 提取匹配 rkmpp-stack_*_<ARCH>.deb 的 browser_download_url（不依赖 jq）
  echo "$json" | grep -oE '"browser_download_url":[[:space:]]*"[^"]*rkmpp-stack_[^"]*_'"${ARCH}"'\.deb"' \
    | sed -E 's/.*"browser_download_url":[[:space:]]*"([^"]+)".*/\1/' | head -1
}

# ---- 校验 deb 内 build-info 的 ARCH/DISTRO_CODENAME 与本品一致 ----
deb_buildinfo_ok() {
  local deb="$1" tmp info dt b_arch b_distro
  tmp="$(mktemp -d)"; ( cd "$tmp" && ar x "$deb" ) 2>/dev/null || { rm -rf "$tmp"; return 1; }
  dt="$(ls "$tmp"/data.tar.* 2>/dev/null | head -1)"; [ -z "$dt" ] && { rm -rf "$tmp"; return 1; }
  info="$(tar -xOf "$dt" ./usr/local/share/rkmpp-stack/build-info 2>/dev/null)"
  rm -rf "$tmp"
  [ -z "$info" ] && return 1
  b_arch="$(echo "$info" | sed -n 's/^ARCH=//p')"
  b_distro="$(echo "$info" | sed -n 's/^DISTRO_CODENAME=//p')"
  [ "$b_arch" = "$ARCH" ] && [ "$b_distro" = "$DISTRO_CODENAME" ]
}

# ---- 解析出可安装的 deb（本地 > 网络预编译 > 重编）----
resolve_deb() {
  # 1) 本地指定
  if [ -n "${RKMPP_DEB:-}" ]; then
    [ -f "$RKMPP_DEB" ] || die "RKMPP_DEB 指向不存在: $RKMPP_DEB"
    if deb_buildinfo_ok "$RKMPP_DEB"; then echo "$RKMPP_DEB"; return 0; fi
    warn "本地 deb 的 build-info 与本品(${ARCH}/${DISTRO_CODENAME})不符，仍尝试使用"
    echo "$RKMPP_DEB"; return 0
  fi

  # 2) 从 Release 拉预编译包（逐一候选 tag，校验通过即用）
  local token="${GH_TOKEN:-}"
  command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && token="${token:-$(gh auth token 2>/dev/null)}"
  if [ -z "$token" ] && ! command -v gh >/dev/null 2>&1; then
    warn "未提供 GH_TOKEN 且未安装/未登录 gh，无法访问私有 Release；请用 RKMPP_DEB 指定本地包，或设 GH_TOKEN"
  else
    local tag url out
    for tag in $(candidate_tags); do
      log "尝试 Release: $tag"
      out="$WORKDIR/${PKG}_${STACK_VER}_${ARCH}.deb"
      if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh release download "$tag" --repo "$REPO" --pattern "rkmpp-stack_*_${ARCH}.deb" --dir "$WORKDIR" >/dev/null 2>&1 \
          && out="$(ls -1 "$WORKDIR"/rkmpp-stack_*_"${ARCH}".deb 2>/dev/null | head -1)"
      else
        url="$(gh_release_asset_url "$tag" "$token")"
        if [ -n "$url" ]; then curl -fsSL -H "Authorization: Bearer ${token}" -o "$out" "$url" 2>/dev/null && [ -s "$out" ] || out=""; fi
      fi
      if [ -s "${out:-}" ]; then
        if deb_buildinfo_ok "$out"; then ok "命中匹配预编译包: $tag"; echo "$out"; return 0; fi
        warn "$tag 的包 build-info 不符（$(tar -xOf "$(ls "$WORKDIR"/data.tar.* 2>/dev/null|head -1)" ./usr/local/share/rkmpp-stack/build-info 2>/dev/null | sed -n 's/^DISTRO_CODENAME=//p')），跳过"
        rm -f "$out"
      fi
    done
    warn "未找到与本品(${ARCH}/${DISTRO_CODENAME})匹配的预编译 deb"
  fi

  # 3) 重编回退（需显式允许）
  if [ "${RKMPP_ALLOW_REBUILD:-}" = "yes" ]; then
    rebuild_and_install && return 0
  fi
  die "没有可用的预编译 deb。请：① 设 RKMPP_DEB=/path/to.deb；② 或设 GH_TOKEN 拉私有 Release；③ 或设 RKMPP_ALLOW_REBUILD=yes 本地重编"
}

rebuild_and_install() {
  local build="$SCRIPT_DIR/rk35xx-rkmpp-mpv-build.sh"
  [ -f "$build" ] || die "未找到编译脚本 $build（重编需完整源码树）"
  log "本地重编并打包（耗时较长，依赖网络与编译工具链）..."
  bash "$build" build BUILD_DEB=yes || return 1
  bash "$SCRIPT_DIR/mkdeb-rkmpp-stack.sh" --outdir "$WORKDIR/debs" || return 1
  local deb; deb="$(ls -1 "$WORKDIR/debs"/rkmpp-stack_*.deb 2>/dev/null | head -1)"
  [ -n "$deb" ] && { echo "$deb"; return 0; }
  return 1
}

install_deb() {
  local deb="$1"
  log "安装: $deb"
  dpkg -i "$deb" || apt-get -f install -y || die "安装失败"
  ldconfig 2>/dev/null || true
}

# ---- 安装后自检 ----
verify_install() {
  echo "== 安装自检 =="
  local mpv_bin; mpv_bin="$(command -v mpv 2>/dev/null)"
  [ -n "$mpv_bin" ] || { warn "mpv 不在 PATH"; return 1; }
  ok "mpv: $($mpv_bin --version 2>/dev/null | head -1)"
  local n; n="$(mpv --hwdec=help 2>/dev/null | grep -c rkmpp)"
  if [ "$n" -ge 20 ] 2>/dev/null; then ok "rkmpp 解码后端: $n 项 (>=20)"; else warn "rkmpp 解码后端仅 $n 项（期望 >=20）"; fi
  if ldd "$mpv_bin" 2>/dev/null | grep -q 'libavcodec.*ffmpeg-rkmpp'; then ok "mpv 链接到隔离 ffmpeg-rkmpp"; else warn "mpv 未链接 /usr/local/lib/ffmpeg-rkmpp 的 libavcodec"; fi
  for dev in /dev/mpp_service /dev/rga; do [ -e "$dev" ] && ok "$dev 存在" || warn "$dev 缺失"; done
  return 0
}

is_installed() {
  dpkg -s "$PKG" >/dev/null 2>&1
}

main() {
  local check_only=0
  for a in "$@"; do case "$a" in --check) check_only=1;; -h|--help) sed -n '2,40p' "$0"; exit 0;; esac; done

  detect_target
  check_prereqs

  if is_installed; then
    local iv; iv="$(dpkg -s "$PKG" | sed -n 's/^Version: //p')"
    log "已安装 $PKG $iv"
  fi

  if [ "$check_only" -eq 1 ]; then
    verify_install
    exit 0
  fi

  if is_installed; then
    ok "已安装，跳过（如需重装请先 dpkg -r $PKG）"
    verify_install
    exit 0
  fi

  local deb; deb="$(resolve_deb)" || exit 1
  install_deb "$deb"
  verify_install
  log "完成。下次新板卡直接 sudo bash install-rkmpp-stack.sh 即可，无需编译。"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi

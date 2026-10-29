#!/usr/bin/env bash
# =============================================================================
# mkdeb-rkmpp-stack.sh — 把「已安装」的 RKMPP+mpv 栈打包成当前发行版/架构的 .deb
# -----------------------------------------------------------------------------
# 背景：rkmpp-stack_*.deb 是**发行版 + 架构绑定**的（Depends 由 dpkg-shlibdeps 从
#       当前系统的 SONAME 算出，二进制由当前发行版的 glibc 链接）。所以：
#         * 换发行版（trixie → noble/bookworm/deepin）必须重编（再重打）
#         * 换架构（arm64 → 任意其它）必须重编（无法交叉复用）
#       本脚本替代早期板上一次性脚本 mkdeb2.sh，纳入版本控制，可复现。
#
# 前提：栈已在本机安装好（/usr/local/bin/mpv 能跑、/etc/mpv/mpv.conf 在）。
#       通常流程是：rk35xx-rkmpp-mpv-build.sh build 之后再跑本脚本；
#       或直接 `rk35xx-rkmpp-mpv-build.sh build`（BUILD_DEB=yes）自动调用。
#
# 用法：
#   sudo bash mkdeb-rkmpp-stack.sh [--outdir DIR] [--prefix DIR] [--version VER]
#   sudo OUTDIR=/root/rkmpp-debs bash mkdeb-rkmpp-stack.sh
#
# 产物：$OUTDIR/rkmpp-stack_<ver>_<arch>.deb，内置
#       /usr/local/share/rkmpp-stack/build-info（记录 ARCH/DISTRO/GLIBC/版本），
#       供 rkmpp-mpv 扩展判断「预编译包是否适用当前目标板」，不匹配即回退源码编译。
# =============================================================================
set -euo pipefail

PREFIX=/usr/local
OUTDIR="${OUTDIR:-/root/rkmpp-debs}"
PKG=rkmpp-stack
VERSION_OVERRIDE=""
MULTIARCH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --outdir)   OUTDIR="$2"; shift 2 ;;
    --prefix)   PREFIX="$2"; shift 2 ;;
    --version)  VERSION_OVERRIDE="$2"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

log() { echo "[mkdeb $(date +%H:%M:%S)] $*"; }
die() { echo "[mkdeb] 错误: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "需要 root（要读 /etc 并打包系统路径）"
command -v dpkg-deb >/dev/null || die "缺少 dpkg-deb"
command -v dpkg-shlibdeps >/dev/null || die "缺少 dpkg-shlibdeps（dpkg-dev）"

ARCH="$(dpkg --print-architecture)"
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo "${ARCH}-linux-gnu")"
[ -r /etc/os-release ] && . /etc/os-release
DISTRO_ID="${ID:-unknown}"
DISTRO_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
# 注意：`set -o pipefail` + `head -1` 铁律——上游一次 write 多行时 head 提前退出关闭管道，
# 上游收到 SIGPIPE，pipefail 把整条命令判为 141，`set -e` 直接中止（曾导致打包静默失败）。
# 统一改用 `sed -n 1p`（读完整个流，不会引发 SIGPIPE）。
GLIBC="$(ldd --version 2>/dev/null | sed -n 1p | awk '{print $NF}')"

# ---- 0. 前置检查：栈必须完整装好 ----
[ -x "$PREFIX/bin/mpv" ]  || die "$PREFIX/bin/mpv 不存在，请先 build"
[ -x "$PREFIX/bin/ffmpeg" ] || die "$PREFIX/bin/ffmpeg 不存在，请先 build"
[ -d "$PREFIX/lib/ffmpeg-rkmpp" ] || die "$PREFIX/lib/ffmpeg-rkmpp 不存在，请先 build"
[ -f /etc/mpv/mpv.conf ] || die "/etc/mpv/mpv.conf 不存在，请先 build（configure_runtime）"

MPV_RAW="$("$PREFIX/bin/mpv" --version 2>/dev/null | sed -n 1p | awk '{print $2}')"
MPV_BASE="${MPV_RAW%%-*}"                      # v0.41.0-dirty -> v0.41.0
MPV_BASE="${MPV_BASE#v}"                       # -> 0.41.0（dpkg 版本号不能以 v 开头）
VERSION="${VERSION_OVERRIDE:-${MPV_BASE:-0.41.0}-1}"
PKGCFG="$(command -v pkg-config 2>/dev/null || command -v pkgconf 2>/dev/null || true)"
MPP_VER="$([ -n "$PKGCFG" ] && "$PKGCFG" --modversion rockchip_mpp 2>/dev/null || echo unknown)"
RGA_VER="$([ -n "$PKGCFG" ] && "$PKGCFG" --modversion librga 2>/dev/null || echo unknown)"
FFMPEG_VER="$("$PREFIX/bin/ffmpeg" -hide_banner -version 2>/dev/null | sed -n 1p | awk '{print $3}')"

log "目标: $PKG $VERSION  arch=$ARCH multiarch=$MULTIARCH  distro=$DISTRO_CODENAME($DISTRO_ID) glibc=$GLIBC"

WORK="$(mktemp -d /tmp/rkmpp-deb.XXXXXX)"
STAGE="$WORK/${PKG}_${VERSION}_${ARCH}"
mkdir -p "$STAGE" "$OUTDIR" "$WORK/debian"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. 收集文件（与线上验证过的 deb 同构；目录用 multiarch 自适应跨架构）----
shopt -s nullglob
SRC=()
add() { local p; for p in "$@"; do [ -e "$p" ] && SRC+=("$p"); done; }

add "$PREFIX/bin/mpv" "$PREFIX/bin/ffmpeg" "$PREFIX/bin/ffprobe"
add "$PREFIX"/lib/ffmpeg-rkmpp/*
add "$PREFIX"/lib/librockchip_mpp.so* "$PREFIX"/lib/librockchip_vpu.so*
add "$PREFIX"/lib/"$MULTIARCH"/librga.so* "$PREFIX"/lib/"$MULTIARCH"/pkgconfig/*
add "$PREFIX"/lib/pkgconfig/*.pc
add /etc/mpv/mpv.conf /etc/udev/rules.d/99-mpp.rules /etc/ld.so.conf.d/99-ffmpeg-rockchip.conf
add "$PREFIX/etc/mpv/mpv.conf"          # 软链（若存在）
add /usr/share/applications/mpv.desktop                        # 桌面菜单项
add /usr/share/icons/hicolor/scalable/apps/mpv.svg             # 菜单图标
add "$PREFIX/bin/mpv-desktop"                                  # 菜单入口 wrapper（无参开 idle 窗口）

[ "${#SRC[@]}" -gt 0 ] || die "未收集到任何文件"
log "收集 ${#SRC[@]} 个路径，复制到 staging…"
( cd / && cp -a --parents "${SRC[@]}" "$STAGE" )

# ---- 2. 写入 build-info（供扩展做发行版/架构守卫）----
mkdir -p "$STAGE/usr/local/share/rkmpp-stack"
cat > "$STAGE/usr/local/share/rkmpp-stack/build-info" <<EOF
PKG=$PKG
VERSION=$VERSION
ARCH=$ARCH
MULTIARCH=$MULTIARCH
DISTRO_ID=$DISTRO_ID
DISTRO_CODENAME=$DISTRO_CODENAME
GLIBC=$GLIBC
MPV=$MPV_RAW
MPP=$MPP_VER
RGA=$RGA_VER
FFMPEG=$FFMPEG_VER
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILT_ON=$(hostname 2>/dev/null || echo unknown)
EOF

# ---- 3. dpkg-shlibdeps 计算运行库依赖（用 live 二进制，系统 ldconfig 可见隔离库）----
# --ignore-missing-info: 我们自己编的 libav*/librga/librockchip_mpp 无 dpkg 归属，
# 不忽略会直接报错；忽略后只保留系统级依赖，与已验证 deb 的 Depends 一致。
cat > "$WORK/debian/control" <<EOF
Source: $PKG
Section: video
Priority: optional
Maintainer: xiaobao <xiaobao@local>
Standards-Version: 4.6.2

Package: $PKG
Architecture: $ARCH
Depends: \${shlibs:Depends}
Description: RK35xx RKMPP hardware decoding stack (mpp+rkrga+ffmpeg-rockchip+mpv rkmpp)
 Prebuilt stack for RK3566/3568/3576/3588 on $DISTRO_CODENAME X11 desktop.
 Built by rk35xx-rkmpp-mpv-build.sh on $(date -u +%Y-%m-%d).
EOF
cat > "$WORK/debian/changelog" <<EOF
$PKG ($VERSION) unstable; urgency=medium

  * Prebuilt RKMPP stack for $DISTRO_CODENAME/$ARCH.

 -- xiaobao <xiaobao@local>  $(date -R)
EOF

log "计算 Depends（dpkg-shlibdeps，覆盖全部 ELF：bin + 全部 .so，取完整运行库闭包）…"
# 只喂 3 个 bin 会漏掉 libavcodec 的传递依赖（libx264/libx265/libdav1d/libgnutls…），
# 导致装到目标板后运行时缺库。这里把 bin 与所有真实 .so 一起喂进去，得到完整闭包。
SHLIB_INPUTS=()
while IFS= read -r _f; do
  head -c 4 "$_f" 2>/dev/null | grep -qa 'ELF' && SHLIB_INPUTS+=("${_f#$STAGE}")
done < <(find "$STAGE$PREFIX/bin" "$STAGE$PREFIX/lib" -type f 2>/dev/null)
[ "${#SHLIB_INPUTS[@]}" -gt 0 ] || die "staging 中未找到任何 ELF 文件"
log "  ELF 输入: ${#SHLIB_INPUTS[@]} 个"
DEPS="$(cd "$WORK" && dpkg-shlibdeps --ignore-missing-info -O \
          "${SHLIB_INPUTS[@]}" \
          -l"$PREFIX/lib/ffmpeg-rkmpp" -l"$PREFIX/lib" -l"$PREFIX/lib/$MULTIARCH" 2>"$WORK/shlibdeps.err" \
        | sed -n 's/^shlibs:Depends=//p' || true)"
if [ -z "$DEPS" ]; then
  echo "--- dpkg-shlibdeps stderr ---"; sed -n '1,20p' "$WORK/shlibdeps.err" >&2 || true
  die "Depends 计算失败（shlibdeps 为空）"
fi
log "Depends: $DEPS"

# ---- 4. DEBIAN 控制文件 ----
mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Section: video
Priority: optional
Architecture: $ARCH
Maintainer: xiaobao <xiaobao@local>
Depends: $DEPS
Description: RK35xx RKMPP hardware decoding stack (mpp+rkrga+ffmpeg-rockchip+mpv rkmpp)
 Prebuilt stack for RK3566/3568/3576/3588 on $DISTRO_CODENAME X11 desktop.
 mpp $MPP_VER (jellyfin-mpp), rkrga $RGA_VER (jellyfin-rga), ffmpeg-rockchip
 isolated in $PREFIX/lib/ffmpeg-rkmpp, mpv $MPV_RAW + rkmpp backend patch.
 Ships /etc/mpv/mpv.conf (hwdec=rkmpp, fullscreen=yes, keep-open=no),
 udev rule 99-mpp.rules (mpp_service/rga 0666) and ld.so.conf.d entry.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
ldconfig
mkdir -p /usr/local/etc/mpv
[ -e /usr/local/etc/mpv/mpv.conf ] || ln -sf /etc/mpv/mpv.conf /usr/local/etc/mpv/mpv.conf
if [ -d /run/udev ] || [ -d /dev/.udev ]; then
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger 2>/dev/null || true
fi
# 桌面菜单项刷新（XFCE/GNOME 才能立即搜到 mpv）
command -v update-desktop-database >/dev/null && update-desktop-database /usr/share/applications 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t /usr/share/icons/hicolor 2>/dev/null || true
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

# ---- 5. 打包 + 自检 ----
DEB="$OUTDIR/${PKG}_${VERSION}_${ARCH}.deb"
log "打包 → $DEB"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB" >/dev/null

log "自检："
dpkg-deb -f "$DEB" Package Version Architecture | sed 's/^/    /'
# 先落文件再 grep：避免 `dpkg-deb -c | grep -q` 在 pipefail 下因 SIGPIPE 误报缺文件
dpkg-deb -c "$DEB" > "$WORK/deb.list" 2>/dev/null
local_n=$(wc -l < "$WORK/deb.list" | tr -d ' ')
log "    文件条目: $local_n"
for need in ./usr/local/bin/mpv ./usr/local/bin/ffmpeg ./usr/local/lib/ffmpeg-rkmpp ./etc/mpv/mpv.conf \
            ./usr/local/share/rkmpp-stack/build-info ./usr/share/applications/mpv.desktop \
            ./usr/share/icons/hicolor/scalable/apps/mpv.svg ./usr/local/bin/mpv-desktop; do
  grep -q " $need" "$WORK/deb.list" || die "产物缺少 $need"
done
log "    关键路径齐全"
if command -v sha256sum >/dev/null; then sha256sum "$DEB" | sed 's/^/    /'; fi
log "完成。部署：sudo apt-get install -y $DEB   或   sudo dpkg -i $DEB && sudo ldconfig"

#!/usr/bin/env bash
# =============================================================================
# RK35xx X11 RKMPP + mpv 一键编译脚本（实测版 v3，官方 mpv + rkmpp 补丁路线）
# -----------------------------------------------------------------------------
# 适用 : RK3566 / RK3568 / RK3576 / RK3588，Armbian vendor 6.1 BSP 内核，X11 桌面
# 发行版: X11 桌面下支持 noble / bookworm / trixie / jammy / resolute / deepin25
#         （Wayland 会话不适用；meson<1.1 的发行版 jammy/bookworm 会自动 pip 升级）
# 路线 : mpp(gitee jellyfin-mpp) -> rkrga(gitee jellyfin-rga)
#        -> ffmpeg-rockchip(gitee, 隔离 /usr/local/lib/ffmpeg-rkmpp)
#        -> mpv(官方主线 v0.41.0 + nyanmisaka/boogiepop rkmpp 后端补丁 mpp.patch)
# 说明 : mpv 官方主线 v0.41.0 的 video/out/hwdec/ 仅有 drmprime 帧格式后端，
#        不含 rkmpp 解码后端（无 hwdec_rkmpp.c / ra_hwdec_drmprime_rkmpp.c）。
#        故必须用补丁（或等价 fork）注入 rkmpp 后端。github.com/nyanmisaka/mpv
#        不存在(404)，但其 rkmpp 工作以补丁形式由本仓库 mpp.patch 提供（PATCH 2/3
#        作者即 nyanmisaka），对官方 v0.41.0 应用 == 获得 fork 同款 rkmpp 后端。
# 注意 : 本板 github 被网络层封锁，mpv 源码 + 补丁需提前从可访问 github 的主机
#        放到 MPV_TARBALL / MPV_PATCH 指向的路径（默认 /home/xiaobao/rkmpp-src/）。
#        若 tarball 不存在，脚本会尝试 gitee 镜像作为兜底。
# 用法 : sudo bash rk35xx-rkmpp-mpv-build.sh [build|uninstall|pack]
#         build     编译并安装；BUILD_DEB=yes 时顺带打包当前发行版/架构的 .deb
#         pack      仅打包（把已安装的栈打成 deb；跨发行版/跨架构重编后发布用）
#         uninstall 卸载本栈
# 注意 : 生成的 rkmpp-stack_*.deb 绑定「当前发行版 + 当前架构」（Depends 由
#        dpkg-shlibdeps 从本机 SONAME 算出）。换发行版或换架构必须在本机重编重打，
#        不能复用他处产物。
# =============================================================================
set -euo pipefail

BUILD_BASE="${BUILD_BASE:-/home/xiaobao/rkmpp-build}"
SRC_DIR="$BUILD_BASE/src"
MPV_TARBALL="${MPV_TARBALL:-/home/xiaobao/rkmpp-src/mpv-0.41.0.tar.gz}"
MPV_PATCH="${MPV_PATCH:-/home/xiaobao/rkmpp-src/mpp.patch}"
MPV_TAG=v0.41.0
FFMPEG_LIBDIR=/usr/local/lib/ffmpeg-rkmpp
LOG="$BUILD_BASE/build.log"
VIDEO_DIR=/home/xiaobao/Videos

mkdir -p "$BUILD_BASE" "$SRC_DIR"
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date +%H:%M:%S)] $*"; }

# -----------------------------------------------------------------------------
# git clone 健壮化：多源兜底 + 重试（解决 CI 弱网下 gitee 大仓库 early EOF）
#   顺序：github 优先（CI Actions 原生可达），gitee 兜底（板上 github 被封时）。
#   每个 URL 重试 5 次，失败后清理重来；全部失败返回非 0。
# 用法: git_clone_retry <branch|""> <dest> <url1> [url2 ...]
# -----------------------------------------------------------------------------
setup_git_resilience() {
  git config --global http.postBuffer 1048576000          # 1GB, 避免大仓库 early EOF
  git config --global http.lowSpeedLimit 0
  git config --global http.lowSpeedTime 999999
  git config --global core.compression 0                  # 关压缩降 CPU/超时
  git config --global http.maxRequestBuffer 1048576000
  git config --global protocol.version 2
}
git_clone_retry() {
  local branch="${1:-}"; local dest="$2"; shift 2
  local urls=("$@")
  local bflag=""
  [ -n "$branch" ] && bflag="-b $branch"
  setup_git_resilience
  for url in "${urls[@]}"; do
    for attempt in 1 2 3 4 5; do
      log "[clone] 尝试 $attempt/5: $url"
      rm -rf "$dest"
      if git clone --depth=1 $bflag "$url" "$dest" >"/tmp/clone-$$.log" 2>&1; then
        if [ -d "$dest/.git" ] || [ -d "$dest" ]; then
          log "[clone] 成功: $url"
          return 0
        fi
      fi
      log "[clone] 失败 ($(tail -n1 "/tmp/clone-$$.log" 2>/dev/null)); 清理重试"
      rm -rf "$dest"
      sleep 8
    done
  done
  log "[clone] 所有源/重试均失败"
  return 1
}

# -----------------------------------------------------------------------------
# 发行版探测（支持 noble / bookworm / trixie / jammy / resolute，仅 X11 桌面）
# -----------------------------------------------------------------------------
SUPPORTED_DISTROS="jammy noble bookworm trixie resolute deepin25"
detect_distro() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
    DISTRO_DESC="${PRETTY_NAME:-unknown}"
  else
    DISTRO_ID="unknown"; DISTRO_CODENAME="unknown"; DISTRO_DESC="unknown"
  fi
  # deepin25 的 VERSION_CODENAME 多为 crimson，这里额外放行 ID=deepin
  if [ "$DISTRO_ID" = "deepin" ]; then
    DISTRO_CODENAME="deepin25"
  fi
  log "检测到发行版: $DISTRO_DESC (id=$DISTRO_ID codename=$DISTRO_CODENAME)"
  local ok=0
  for d in $SUPPORTED_DISTROS; do
    [ "$d" = "$DISTRO_CODENAME" ] && ok=1
  done
  if [ "$ok" -eq 0 ]; then
    log "警告: 当前 codename '$DISTRO_CODENAME' 不在已验证列表 [$SUPPORTED_DISTROS]。"
    log "       脚本按通用 Debian/Ubuntu/Deepin X11 路径继续，但未经该发行版实测。"
  else
    log "已验证发行版: $DISTRO_CODENAME（X11 桌面支持）"
  fi
  # 桌面会话检查：仅 X11 走 rkmpp-copy；Wayland 下本脚本不适用
  if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
    log "警告: 当前为 Wayland 会话，本脚本面向 X11。请切到 X11 桌面后运行，或自行调整 mpv.conf。"
  fi
  # meson 版本兜底（bookworm=1.0.1 / jammy=0.61 均需升级；trixie/noble/resolute 用系统版）
  local mv; mv="$(meson --version 2>/dev/null || echo 0)"
  if dpkg --compare-versions "$mv" lt "1.1"; then
    log "meson $mv < 1.1，将通过 pip 升级（所需发行版: jammy/bookworm 常见）"
  else
    log "meson $mv >= 1.1，使用系统版本"
  fi
}

# -----------------------------------------------------------------------------
# 卸载旧 rkmpp + mpv 栈（彻底清掉旧安装，保证干净重建）
# -----------------------------------------------------------------------------
do_uninstall() {
  log "== 卸载旧 rkmpp + mpv 栈 =="
  # mpv 二进制
  rm -f /usr/local/bin/mpv
  # 旧的 ffmpeg-rockchip（散落在 /usr/local/lib 的 8.x 库 + 二进制）
  rm -f /usr/local/bin/ffmpeg /usr/local/bin/ffprobe /usr/local/bin/ffplay
  rm -f /usr/local/lib/libavcodec.so* /usr/local/lib/libavformat.so* \
        /usr/local/lib/libavutil.so* /usr/local/lib/libavfilter.so* \
        /usr/local/lib/libswscale.so* /usr/local/lib/libswresample.so* \
        /usr/local/lib/libpostproc.so* /usr/local/lib/libavdevice.so* \
        /usr/local/lib/libavresample.so* 2>/dev/null || true
  # 旧 ffmpeg pkg-config
  rm -f /usr/local/lib/pkgconfig/libav*.pc /usr/local/lib/pkgconfig/libpostproc*.pc \
        /usr/local/lib/pkgconfig/libsw*.pc 2>/dev/null || true
  # mpp / rga 旧库
  rm -f /usr/local/lib/librockchip_mpp.so* /usr/local/lib/librga.so* 2>/dev/null || true
  # 旧的 ffmpeg-rkmpp 隔离目录
  rm -rf /usr/local/lib/ffmpeg-rkmpp 2>/dev/null || true
  # ld.so / udev / mpv 配置
  rm -f /etc/ld.so.conf.d/99-ffmpeg-rockchip.conf 2>/dev/null || true
  rm -f /etc/udev/rules.d/99-mpp.rules 2>/dev/null || true
  rm -f /etc/mpv/mpv.conf /usr/local/etc/mpv/mpv.conf 2>/dev/null || true
  rmdir /etc/mpv /usr/local/etc/mpv 2>/dev/null || true
  # 桌面菜单项与图标
  rm -f /usr/share/applications/mpv.desktop \
        /usr/share/icons/hicolor/scalable/apps/mpv.svg \
        /usr/local/bin/mpv-desktop 2>/dev/null || true
  # 构建标记（跨发行版/架构重编的判断依据）
  rm -rf /usr/local/share/rkmpp-stack 2>/dev/null || true
  ldconfig
  log "== 卸载完成 =="
}

# -----------------------------------------------------------------------------
# 依赖
# -----------------------------------------------------------------------------
install_deps() {
  log "== 安装构建依赖 =="
  apt-get update -qq
  apt-get install -y -qq \
    git cmake meson ninja-build pkg-config \
    gcc g++ make yasm nasm \
    libdrm-dev libdisplay-info-dev libx11-dev libxext-dev libxrandr-dev libxv-dev \
    libx11-xcb-dev libxcb-shm0-dev libxcb-xfixes0-dev \
    libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev \
    libass-dev libfreetype6-dev libfontconfig1-dev \
    liblua5.1-0-dev libuchardet-dev \
    libx264-dev libx265-dev libdav1d-dev \
    libvorbis-dev libogg-dev libmp3lame-dev libopus-dev \
    libpulse-dev libpipewire-0.3-dev libasound2-dev \
    libgnutls28-dev \
    libplacebo-dev \
    libxss-dev libxpresent-dev
  # mpv >= 0.38 起 libplacebo 是硬依赖（meson.build: dependency('libplacebo', version: '>=6.338.2')）。
  # 发行版对照：trixie 7.349 ✓ / noble 6.338.2 ✓ / bookworm 5.229 ✗ / jammy ✗
  # 版本不足时提前报错，避免 meson 以 "Dependency not found" 形式难查地崩溃。
  if pkg-config --exists libplacebo; then
    local _plv; _plv=$(pkg-config --modversion libplacebo)
    log "libplacebo: $_plv"
    if dpkg --compare-versions "$_plv" lt "6.338.2"; then
      log "错误: 发行版自带 libplacebo $_plv < 6.338.2，mpv $(echo "$MPV_TAG" | tr -d v) 硬依赖不满足。"
      log "      请改用 trixie/noble 及以上发行版，或手动源码编译 libplacebo>=6.338.2 后重试。"
      exit 1
    fi
  else
    log "错误: libplacebo-dev 安装后 pkg-config 仍不可见，中止"; exit 1
  fi
  if dpkg --compare-versions "$(meson --version 2>/dev/null || echo 0)" lt "1.1"; then
    pip3 install --break-system-packages -U meson ninja 2>/dev/null || pip3 install -U meson ninja
  fi
}

# -----------------------------------------------------------------------------
# 依赖前置体检：把「干净环境才暴露的硬依赖」一次性查清
# 背景：gnutls / libplacebo / xscrnsaver / xpresent 都是同一类病——历史装过 dev 包的
# 主机一直正常，一上干净 chroot 或新烧板就炸，且 meson 只会报 "Dependency not found"
# 不报该装哪个包，导致每次都要靠一轮 20min 板端/3h CI 去猜。这里开工前统一体检。
# -----------------------------------------------------------------------------
check_build_libs() {
  log "== 依赖前置体检 =="
  local miss=0 p libs
  libs=(
    "libdrm:libdrm-dev"
    "libdisplay-info:libdisplay-info-dev"
    "libplacebo:libplacebo-dev"
    "xscrnsaver:libxss-dev"
    "xpresent:libxpresent-dev"
    "x11:libx11-dev"
    "gl:libgl1-mesa-dev"
    "egl:libegl1-mesa-dev"
  )
  for p in "${libs[@]}"; do
    if pkg-config --exists "${p%%:*}"; then
      log "  ✓ ${p%%:*}"
    else
      log "  ✗ ${p%%:*} 缺失 → 请安装 ${p##*:}"
      miss=1
    fi
  done
  [ "$miss" -eq 0 ] || {
    log "错误: 依赖体检未通过，请先安装上面列出的包（apt-get install -y ...）后重试"; exit 1; }
}

# -----------------------------------------------------------------------------
# mpp (gitee jellyfin-mpp)
# -----------------------------------------------------------------------------
build_mpp() {
  log "== 编译 mpp (gitee jellyfin-mpp) =="
  cd "$SRC_DIR"
  git_clone_retry jellyfin-mpp mpp \
    https://github.com/nyanmisaka/mpp.git \
    https://gitee.com/nyanmisaka/mpp.git
  cd mpp && mkdir -p build && cd build
  cmake -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON -DBUILD_TEST=OFF ..
  make -j"$(nproc)"
  make install
  ldconfig
  pkg-config --exists rockchip_mpp && log "MPP OK: $(pkg-config --modversion rockchip_mpp)" \
    || { log "MPP pkg-config 缺失，中止"; exit 1; }
}

# -----------------------------------------------------------------------------
# rkrga (gitee jellyfin-rga)
# -----------------------------------------------------------------------------
build_rga() {
  log "== 编译 rkrga (gitee jellyfin-rga) =="
  cd "$SRC_DIR"
  # 注：rga 的 jellyfin-rga 分支仅在 gitee 维护（github 无同名仓库，
  # nyanmisaka/librga 也无该分支），故只用 gitee，靠重试解决偶发 early EOF。
  git_clone_retry jellyfin-rga rkrga \
    https://gitee.com/nyanmisaka/rga.git
  cd rkrga
  meson setup build --prefix=/usr/local --buildtype=release \
    --default-library=shared -Dlibdrm=false -Dlibrga_demo=false
  ninja -C build
  ninja -C build install
  ldconfig
  pkg-config --exists librga && log "RGA OK: $(pkg-config --modversion librga)" \
    || { log "RGA pkg-config 缺失，中止"; exit 1; }
}

# -----------------------------------------------------------------------------
# ffmpeg-rockchip (gitee, 隔离安装)
# -----------------------------------------------------------------------------
build_ffmpeg() {
  log "== 编译 ffmpeg-rockchip (gitee) 隔离安装 =="
  cd "$SRC_DIR"
  # in-tree 编译产物 rkmppdec.o 存在即视为已编译，跳过 clone/configure/make（省 ~10 分钟）
  if [ -f ffmpeg-rockchip/libavcodec/rkmppdec.o ]; then
    log "ffmpeg-rockchip 已编译（含 rkmpp 解码器），跳过 clone/configure/make，直接安装"
    cd ffmpeg-rockchip
  else
    git_clone_retry "" ffmpeg-rockchip \
      https://github.com/nyanmisaka/ffmpeg-rockchip.git \
      https://gitee.com/nyanmisaka/ffmpeg-rockchip.git
    cd ffmpeg-rockchip
    # mpp/rga 装在 /usr/local，Debian 的 pkg-config 默认不搜 /usr/local/lib/pkgconfig，
    # 不导出会导致 configure 静默 disable rkmpp（编出 ffmpeg 却无 *_rkmpp 解码器）。
    export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}
    ./configure --prefix=/usr/local \
      --libdir=$FFMPEG_LIBDIR \
      --enable-gpl --enable-version3 --enable-nonfree \
      --enable-shared --disable-static \
      --enable-libdrm --enable-rkmpp --enable-rkrga \
      --enable-libx264 --enable-libx265 --enable-libdav1d \
      --enable-gnutls \
      --extra-cflags="-I/usr/local/include" \
      --extra-ldflags="-L/usr/local/lib -Wl,-rpath,$FFMPEG_LIBDIR" \
      --disable-doc --disable-debug --disable-ffplay
    make -j"$(nproc)"
  fi
  make install
  echo "$FFMPEG_LIBDIR" > /etc/ld.so.conf.d/99-ffmpeg-rockchip.conf
  ldconfig
  # ★ 装后验证：用 LD_LIBRARY_PATH 兜底库路径（规避 ldconfig 缓存时序导致二进制启动失败误报），
  #   且不再吞 stderr，失败时可看到真实错误。
  export LD_LIBRARY_PATH="$FFMPEG_LIBDIR:${LD_LIBRARY_PATH:-}"
  local FF=/usr/local/bin/ffmpeg
  # 输出落到文件再 grep，彻底规避 set -o pipefail + grep -q + SIGPIPE 的管道误报
  "$FF" -hide_banner -decoders 2>/dev/null > /tmp/ffmpeg-decoders.txt || true
  if ! grep -qE 'h264_rkmpp|hevc_rkmpp|vp9_rkmpp|av1_rkmpp' /tmp/ffmpeg-decoders.txt; then
    log "rkmpp 解码器缺失（--enable-rkmpp 未生效）。调试信息:"
    grep -i rkmpp /tmp/ffmpeg-decoders.txt | head -5 || echo "(无 rkmpp 解码器输出)"
    "$FF" -hide_banner -version 2>&1 | head -2
    exit 1
  fi
  log "rkmpp 解码器校验通过: $(grep -cE '_rkmpp' /tmp/ffmpeg-decoders.txt) 个"
  log "ffmpeg-rkmpp 安装完成 -> $FFMPEG_LIBDIR"
}

# -----------------------------------------------------------------------------
# mpv 源码准备（优先用 Mac 预置 tarball，兜底 gitee 镜像）
#   然后注入 nyanmisaka/boogiepop rkmpp 后端补丁（官方主线不含该后端）
# -----------------------------------------------------------------------------
prepare_mpv() {
  log "== 准备 mpv 源码 ($MPV_TAG) + 应用 rkmpp 补丁 =="
  cd "$SRC_DIR"
  local from_tarball=1
  if [ -f "$MPV_TARBALL" ]; then
    log "使用预置 tarball: $MPV_TARBALL"
    rm -rf mpv && mkdir -p mpv && tar -xzf "$MPV_TARBALL" -C mpv --strip-components=1
  else
    log "未找到预置 tarball，尝试 gitee 镜像兜底..."
    rm -rf mpv
    for url in https://github.com/mpv-player/mpv.git \
               https://gitee.com/src-openeuler/mpv.git \
               https://gitee.com/mirrors/mpv.git; do
      if git clone -b "$MPV_TAG" --depth=1 "$url" mpv 2>/dev/null && [ -d mpv/.git ]; then
        log "gitee 镜像克隆成功: $url"; from_tarball=0; break
      fi
      rm -rf mpv
    done
    if [ ! -d mpv/.git ]; then
      log "无法获取 mpv 源码（本板 github 被封且 gitee 镜像无 v$MPV_TAG）。"
      log "请将 mpv v$MPV_TAG 的 tarball 放到 $MPV_TARBALL 后重试。"
      exit 1
    fi
  fi
  cd mpv
  # 若从 git 克隆，先确保切到正确 tag（tarball 已固定版本，无需切）
  if [ "$from_tarball" -eq 0 ] && [ -d .git ] && git rev-parse "$MPV_TAG" >/dev/null 2>&1; then
    git checkout "$MPV_TAG" 2>/dev/null || true
  fi
  # 注入 rkmpp 解码/渲染后端（等价于 nyanmisaka/boogiepop mpv fork 的 rkmpp 分支）
  if [ -f "$MPV_PATCH" ]; then
    if grep -q "ra_hwdec_drmprime_rkmpp" video/out/hwdec/hwdec_drmprime.c 2>/dev/null; then
      log "rkmpp 补丁已存在，跳过"
    else
      log "应用 rkmpp 补丁: $MPV_PATCH"
      git init -q . 2>/dev/null || true
      git add -A 2>/dev/null || true
      git -c user.email=build@local -c user.name=build commit -qm base 2>/dev/null || true
      if ! git apply "$MPV_PATCH" 2>/tmp/mpv-patch.err; then
        log "git apply 失败，回退 patch -p1："; head -20 /tmp/mpv-patch.err
        patch -p1 < "$MPV_PATCH" || { log "补丁应用失败，中止"; exit 1; }
      fi
      log "rkmpp 补丁已应用"
    fi
  else
    log "警告: 未找到 rkmpp 补丁 $MPV_PATCH，将编出无 rkmpp 后端的 mpv（hwdec=rkmpp 不会出现）"
  fi
  log "mpv 源码就绪: $(cat MPV_VERSION 2>/dev/null || echo unknown)"
}

# -----------------------------------------------------------------------------
# mpv 编译（官方主线 v0.41.0 + rkmpp 补丁，链 ffmpeg-rockchip）
# -----------------------------------------------------------------------------
build_mpv() {
  log "== 编译 mpv (官方主线 $MPV_TAG + rkmpp 补丁) =="
  cd "$SRC_DIR/mpv"
  # rkmpp 渲染后端在 video/out/hwdec/hwdec_drmprime.c，受 features['drm'] 控制；
  # 显式 -Ddrm=enabled 强制开启（依赖 libdrm + libdisplay-info，已在 install_deps 装好），
  # 否则 meson 自动探测失败会让该文件不编译 -> 补丁白打、hwdec=rkmpp 不出现。
  export PKG_CONFIG_PATH=$FFMPEG_LIBDIR/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}
  rm -rf build
  meson setup build --prefix=/usr/local --buildtype=release \
    -Dx11=enabled -Dgl-x11=enabled -Degl-x11=enabled \
    -Ddrm=enabled -Dwayland=disabled -Dlibmpv=true
  ninja -C build -j"$(nproc)"
  # 硬校验：rkmpp 驱动对象确实被编译出来（补丁生效 + ffmpeg-rockchip 头文件可见）
  if ! grep -q "rkmpp" build/video/out/hwdec/libmpv_static.a 2>/dev/null && \
     ! grep -rqs "ra_hwdec_drmprime_rkmpp" build/ 2>/dev/null; then
    log "错误: 编译产物中未找到 rkmpp 驱动符号，补丁或 ffmpeg-rockchip 头文件可能未生效，中止"
    exit 1
  fi
  ninja -C build install
  ldconfig
  log "mpv 链接的 libavcodec: $(ldd build/mpv | grep libavcodec)"
  mpv --hwdec=help 2>/dev/null > /tmp/mpv-hwdec.txt || true
  local n; n=$(grep -c rkmpp /tmp/mpv-hwdec.txt)
  log "rkmpp hwdec 项数: $n"
  [ "$n" -ge 1 ] || { log "rkmpp hwdec 未出现（补丁未生效或 ffmpeg-rockchip 头文件未找到），中止"; exit 1; }
}

# -----------------------------------------------------------------------------
# 桌面集成：.desktop 菜单项 + 图标（缺这两个，XFCE/GNOME 开始菜单里搜不到 mpv）
# -----------------------------------------------------------------------------
install_desktop_entry() {
  local APPDIR=/usr/share/applications
  local ICONROOT=/usr/share/icons/hicolor
  mkdir -p "$APPDIR" "$ICONROOT/scalable/apps"
  # 菜单入口 wrapper：mpv 无参数会打印用法并退出（点了等于没反应），
  # 无参时开 idle 窗口（非全屏、可拖拽文件），带参时按 mpv.conf 正常全屏播放。
  cat > /usr/local/bin/mpv-desktop <<'EOF'
#!/bin/sh
# 桌面菜单入口（由 rkmpp-mpv 栈安装）
if [ "$#" -eq 0 ]; then
  exec /usr/local/bin/mpv --player-operation-mode=pseudo-gui --no-fullscreen --force-window=yes
fi
exec /usr/local/bin/mpv -- "$@"
EOF
  chmod 0755 /usr/local/bin/mpv-desktop
  cat > "$APPDIR/mpv.desktop" <<'EOF'
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
Icon=mpv
Terminal=false
Categories=AudioVideo;Video;Player;
MimeType=video/mp4;video/x-matroska;video/webm;video/quicktime;video/x-msvideo;video/mp2t;video/x-flv;video/mpeg;audio/mpeg;audio/flac;audio/x-wav;audio/ogg;
Keywords=mpv;player;video;rkmpp;hardware;
StartupNotify=false
EOF
  chmod 644 "$APPDIR/mpv.desktop"
  # 自带图标：避免依赖 Icon=mpv 在发行版主题里恰好存在（trixie 的 hicolor 没有）
  cat > "$ICONROOT/scalable/apps/mpv.svg" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <rect x="4" y="4" width="120" height="120" rx="22" fill="#7b1fa2"/>
  <path d="M50 36 L50 92 L96 64 Z" fill="#ffffff"/>
</svg>
EOF
  chmod 644 "$ICONROOT/scalable/apps/mpv.svg"
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPDIR" 2>/dev/null || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$ICONROOT" 2>/dev/null || true
  # 可选：把视频/音频默认打开方式设为 mpv（MPV_SET_DEFAULT=yes 才动，避免覆盖用户偏好）
  if [ "${MPV_SET_DEFAULT:-no}" = "yes" ]; then
    mkdir -p /etc/xdg
    cat > /etc/xdg/mimeapps.list <<'EOF'
[Default Applications]
video/mp4=mpv.desktop
video/x-matroska=mpv.desktop
video/webm=mpv.desktop
video/quicktime=mpv.desktop
video/x-msvideo=mpv.desktop
video/mp2t=mpv.desktop
audio/mpeg=mpv.desktop
audio/flac=mpv.desktop
EOF
    log "已把视频/音频默认打开方式设为 mpv（/etc/xdg/mimeapps.list）"
  fi
  log "桌面菜单项: $APPDIR/mpv.desktop（菜单里搜 \"mpv\" 或 \"播放器\"）"
}

# -----------------------------------------------------------------------------
# 运行时配置：mpv.conf / udev / CMA
# -----------------------------------------------------------------------------
configure_runtime() {
  log "== 配置 mpv.conf / udev / CMA =="
  mkdir -p /etc/mpv
  cat > /etc/mpv/mpv.conf <<'EOF'
# RK35xx X11 — RKMPP 硬件加速配置
# 桌面走 rkmpp-copy（双拷贝）；TTY/DRM 零拷贝见 mpv-lg4k.sh
fullscreen=yes          # 默认全屏播放（命令行临时退出全屏：mpv --fs=no <file>）
keep-open=no            # 播完立即自动退出，不留住最后一帧窗口
hwdec=rkmpp
hwdec-codecs=all
vo=gpu                  # 0.41 起默认 gpu-next 渲染器
gpu-api=opengl          # Panfrost Mali 不支持 Vulkan，强制 OpenGL
profile=fast           # 轻量预设；追求画质可改 gpu-hq
cache=yes
cache-secs=60
demuxer-max-bytes=50M
sub-font-size=35
sub-color="#FFFFFFFF"
sub-border-color="#FF000000"
EOF
  mkdir -p /usr/local/etc/mpv
  ln -sfn /etc/mpv/mpv.conf /usr/local/etc/mpv/mpv.conf
  install_desktop_entry
  # mpp_service = 硬解必需；rga = ffmpeg rkrga 缩放/格式转换滤镜（非解码必需，一并放开）
  echo 'KERNEL=="mpp_service", MODE="0666"' > /etc/udev/rules.d/99-mpp.rules
  echo 'KERNEL=="rga", MODE="0666"' >> /etc/udev/rules.d/99-mpp.rules
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger 2>/dev/null || true
  echo 1000 > /proc/mpp_service/load_interval 2>/dev/null || true
  # CMA 512M（4K 流畅前提；重刷默认 256M 会卡）
  if [ -f /boot/armbianEnv.txt ]; then
    if grep -q 'cma=' /boot/armbianEnv.txt; then
      sed -i -E 's/(cma=)[0-9]+M/\1512M/' /boot/armbianEnv.txt
    else
      sed -i '1i extraboardargs=cma=512M' /boot/armbianEnv.txt
    fi
    log "已设置 cma=512M（需 reboot 生效）"
  else
    log "未找到 /boot/armbianEnv.txt，跳过 CMA 设置"
  fi
}

# -----------------------------------------------------------------------------
# 写构建标记：记录本栈是用哪个发行版 / 架构 / glibc 编的
# 背景：rkmpp-stack.deb 的 Depends 由 dpkg-shlibdeps 从当前系统 SONAME 算出，
#       二进制也由当前发行版 glibc 链接 —— 所以跨发行版、跨架构都无法复用，
#       必须在本机重编。此标记既供人查，也供 rkmpp-mpv 扩展判断预编译包是否适用。
# -----------------------------------------------------------------------------
write_build_info() {
  local d=/usr/local/share/rkmpp-stack
  mkdir -p "$d"
  local mlib; mlib="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo "$(dpkg --print-architecture)-linux-gnu")"
  . /etc/os-release 2>/dev/null || true
  cat > "$d/build-info" <<EOF
PKG=rkmpp-stack
ARCH=$(dpkg --print-architecture)
MULTIARCH=$mlib
DISTRO_ID=${ID:-unknown}
DISTRO_CODENAME=${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}
GLIBC=$(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')
MPV=$(/usr/local/bin/mpv --version 2>/dev/null | head -1 | awk '{print $2}')
MPP=$(pkg-config --modversion rockchip_mpp 2>/dev/null || echo unknown)
RGA=$(pkg-config --modversion librga 2>/dev/null || echo unknown)
FFMPEG=$(/usr/local/bin/ffmpeg -hide_banner -version 2>/dev/null | head -1 | awk '{print $3}')
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILT_ON=$(hostname 2>/dev/null || echo unknown)
EOF
  log "构建标记: $(grep -E '^(ARCH|DISTRO_CODENAME|GLIBC)=' "$d/build-info" | tr '\n' ' ')"
}

# -----------------------------------------------------------------------------
# 打包成「当前发行版 + 当前架构」的 .deb（跨发行版/跨架构重编后的分发件）
# -----------------------------------------------------------------------------
do_pack() {
  local here mk
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mk="$here/mkdeb-rkmpp-stack.sh"
  [ -f "$mk" ] || { log "错误: 找不到 $mk（打包脚本应与本脚本同目录）"; exit 1; }
  local od="${OUTDIR:-$BUILD_BASE/debs}"
  log "== 打包 deb → $od =="
  bash "$mk" --outdir "$od"
}

# -----------------------------------------------------------------------------
# 验证
# -----------------------------------------------------------------------------
verify() {
  log "== 验证 =="
  mpv --hwdec=help 2>&1 | grep -iE 'rkmpp' | head || { log "rkmpp hwdec 未出现"; exit 1; }
  local t="$VIDEO_DIR/4K-Chimei-inn-60mbps.mp4"
  if [ -f "$t" ]; then
    mpv --vo=null --hwdec=rkmpp-copy --frames=120 "$t" 2>&1 \
      | grep -iE "Using hardware decoding|Using software decoding" | head -1
  else
    log "测试片不存在，跳过播放验证: $t"
  fi
  log "==== 全部完成 ===="
}

# -----------------------------------------------------------------------------
# 入口
# -----------------------------------------------------------------------------
case "${1:-build}" in
  uninstall)
    do_uninstall
    exit 0
    ;;
  pack)
    do_pack
    exit 0
    ;;
  build|"")
    log "######## RK35xx RKMPP+mpv 一键编译开始 ########"
    detect_distro
    do_uninstall
    install_deps
    check_build_libs
    build_mpp
    build_rga
    build_ffmpeg
    prepare_mpv
    build_mpv
    configure_runtime
    write_build_info
    verify
    if [ "${BUILD_DEB:-no}" = "yes" ]; then
      do_pack
    fi
    log "######## 完成。如需 4K 满帧请 reboot 使 cma=512M 生效 ########"
    ;;
  *)
    echo "用法: $0 [build|uninstall|pack]"
    echo "  build     编译并安装（BUILD_DEB=yes 时顺带打包 deb）"
    echo "  pack      仅把已安装的栈打包成当前发行版/架构的 .deb（OUTDIR 可指定输出目录）"
    echo "  uninstall 卸载本栈"
    exit 1
    ;;
esac

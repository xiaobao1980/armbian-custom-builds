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
# 用法 : sudo bash rk35xx-rkmpp-mpv-build.sh [build|uninstall]
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
    libgnutls28-dev
  if dpkg --compare-versions "$(meson --version 2>/dev/null || echo 0)" lt "1.1"; then
    pip3 install --break-system-packages -U meson ninja 2>/dev/null || pip3 install -U meson ninja
  fi
}

# -----------------------------------------------------------------------------
# mpp (gitee jellyfin-mpp)
# -----------------------------------------------------------------------------
build_mpp() {
  log "== 编译 mpp (gitee jellyfin-mpp) =="
  cd "$SRC_DIR"
  rm -rf mpp && git clone -b jellyfin-mpp --depth=1 https://gitee.com/nyanmisaka/mpp.git
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
  rm -rf rkrga && git clone -b jellyfin-rga --depth=1 https://gitee.com/nyanmisaka/rga.git rkrga
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
    rm -rf ffmpeg-rockchip && git clone --depth=1 https://gitee.com/nyanmisaka/ffmpeg-rockchip.git
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
  log "== 准备 mpv 源码 (v$MPV_TAG) + 应用 rkmpp 补丁 =="
  cd "$SRC_DIR"
  local from_tarball=1
  if [ -f "$MPV_TARBALL" ]; then
    log "使用预置 tarball: $MPV_TARBALL"
    rm -rf mpv && mkdir -p mpv && tar -xzf "$MPV_TARBALL" -C mpv --strip-components=1
  else
    log "未找到预置 tarball，尝试 gitee 镜像兜底..."
    rm -rf mpv
    for url in https://gitee.com/src-openeuler/mpv.git https://gitee.com/mirrors/mpv.git; do
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
# 运行时配置：mpv.conf / udev / CMA
# -----------------------------------------------------------------------------
configure_runtime() {
  log "== 配置 mpv.conf / udev / CMA =="
  mkdir -p /etc/mpv
  cat > /etc/mpv/mpv.conf <<'EOF'
# RK35xx X11 — RKMPP 硬件加速配置
# 桌面走 rkmpp-copy（双拷贝）；TTY/DRM 零拷贝见 mpv-lg4k.sh
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
  echo 'KERNEL=="mpp_service", MODE="0666"' > /etc/udev/rules.d/99-mpp.rules
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
  build|"")
    log "######## RK35xx RKMPP+mpv 一键编译开始 ########"
    detect_distro
    do_uninstall
    install_deps
    build_mpp
    build_rga
    build_ffmpeg
    prepare_mpv
    build_mpv
    configure_runtime
    verify
    log "######## 完成。如需 4K 满帧请 reboot 使 cma=512M 生效 ########"
    ;;
  *)
    echo "用法: $0 [build|uninstall]"
    exit 1
    ;;
esac

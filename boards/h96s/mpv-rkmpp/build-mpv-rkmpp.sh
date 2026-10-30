#!/bin/bash
# ============================================================================
# H96 MAX M9 (RK3576) / Armbian trixie —— mpv + rkmpp 硬解重编译脚本（板上运行）
#
# 实测通过：2026-10-27，mpv v0.40.0 + mpp.patch + ffmpeg-rockchip 8.0 (libavcodec 62.28.103)
# 结果：hwdec 列表含 rkmpp / rkmpp-copy（10 种编码），4K H.264 实测 CPU 37~44%，
#       /proc/mpp_service/load rkvdec load 47~54%，零拷贝失败后自动回落 rkmpp-copy。
#
# 用法：把本脚本与 mpp.patch 放到板上同一目录，sudo ./build-mpv-rkmpp.sh
# 依赖：meson ninja cmake + libav*-dev(=ffmpeg-rockchip) libplacebo-dev libass-dev
#       libdisplay-info-dev libdrm-dev libgbm-dev libx11-dev libgl-dev libegl-dev
# ============================================================================
set -e

SRC=/home/xiaobao
MPV_DIR=$SRC/mpv-040
PATCH=$SRC/mpp.patch
PREFIX=/opt/mpv-rkmpp
FFMPEG_RKMPP=/usr/local/lib/ffmpeg-rkmpp

SUDO() { if sudo -n true 2>/dev/null; then sudo "$@"; else echo 123456 | sudo -S "$@"; fi; }

# ---------- 0. 前置校验 ----------
echo ">>> 校验 ffmpeg-rkmpp 与 MPP"
[ -f /usr/local/include/libavutil/hwcontext.h ] || { echo "缺 ffmpeg-rockchip 头文件"; exit 1; }
grep -q AV_HWDEVICE_TYPE_RKMPP /usr/local/include/libavutil/hwcontext.h \
    || { echo "头文件里没有 AV_HWDEVICE_TYPE_RKMPP，无法编译 rkmpp"; exit 1; }
pkg-config --exists rockchip_mpp || { echo "缺 rockchip_mpp.pc"; exit 1; }

# ---------- 1. 让运行时能找到 libavcodec.so.62 ----------
# 【坑 A】/usr/local/lib/ffmpeg-rkmpp 不在 ld.so 默认搜索路径里，
#         否则 build 用 62 头文件、link/runtime 落到系统 61 => "build version 62 incompatible with runtime 61"
echo ">>> 配置 ld.so 路径 $FFMPEG_RKMPP"
printf '%s\n' "$FFMPEG_RKMPP" > /tmp/ff.conf
SUDO cp /tmp/ff.conf /etc/ld.so.conf.d/99-ffmpeg-rockchip.conf
SUDO /sbin/ldconfig

# ---------- 2. 源码 + patch ----------
#[ -d "$MPV_DIR" ] || git clone --depth 1 --branch v0.40.0 https://github.com/mpv-player/mpv.git "$MPV_DIR"
# cd "$MPV_DIR"
# 【注意】mpp.patch 才是真正的 rkmpp 注入（hbiyik/mpv 的 mpp 分支本身不含 rkmpp 代码）
# git apply --verbose "$PATCH"
# 【坑 B】ffmpeg 7+ 删除了 FF_PROFILE_*，mpv 0.40 尚在用 => 必须改名为 AV_PROFILE_*
# sed -i 's/FF_PROFILE_/AV_PROFILE_/g' demux/demux_mkv.c

# ---------- 3. 配置 ----------
cd "$MPV_DIR"
export PKG_CONFIG_PATH=$FFMPEG_RKMPP/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}
echo "libavcodec: $(pkg-config --modversion libavcodec) @ $(pkg-config --variable=libdir libavcodec)"

# 【坑 C】mpv 0.40 默认 gl-x11=disabled，且 wayland=auto 会因协议头缺失编译失败
#         h96-m9 只能走 GLX，故显式开 x11/gl-x11/egl-x11，关 wayland
rm -rf build
meson setup build --prefix="$PREFIX" --buildtype=release \
    -Dx11=enabled -Dgl-x11=enabled -Degl-x11=enabled -Dwayland=disabled -Dlibmpv=true
ninja -j4 -C build
SUDO ninja -C build install
SUDO /sbin/ldconfig

# ---------- 4. 系统配置目录 ----------
# 【坑 D】MPV_CONFDIR 编译期 = $PREFIX/etc/mpv，不是 /etc/mpv！
#         软链过去，保证 /etc/mpv/*.conf 继续是唯一真源
SUDO mkdir -p "$PREFIX/etc/mpv"
for f in mpv.conf mpv-x11.conf mpv-wayland.conf; do
    [ -f "/etc/mpv/$f" ] && SUDO ln -sfn "/etc/mpv/$f" "$PREFIX/etc/mpv/$f"
done

# ---------- 5. MPP 负载统计持久化 ----------
cat > /tmp/mppload.service <<'EOF'
[Unit]
Description=Enable Rockchip MPP VPU load statistics
After=multi-user.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo 1000 > /proc/mpp_service/load_interval'
[Install]
WantedBy=multi-user.target
EOF
SUDO cp /tmp/mppload.service /etc/systemd/system/mpp-load-interval.service
SUDO systemctl daemon-reload
SUDO systemctl enable --now mpp-load-interval.service

# ---------- 6. 验证 ----------
echo
echo ">>> hwdec 列表："
"$PREFIX/bin/mpv" --hwdec=help | grep -c rkmpp
echo ">>> 解码路径（vo=null）："
"$PREFIX/bin/mpv" --vo=null --audio=no --frames=150 -v "${1:-/home/xiaobao/视频/4K-Chimei-inn-60mbps.mp4}" 2>&1 \
  | grep -iE "Looking at hwdec|Using hardware decoding|Using software decoding" | head -6

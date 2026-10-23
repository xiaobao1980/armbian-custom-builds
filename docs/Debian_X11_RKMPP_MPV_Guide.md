# Debian X11 RKMPP + mpv 硬件加速完整方案

> 适用：Debian bookworm/trixie + X11 (XFCE/GNOME/Deepin) + Rockchip RK3566/RK3568/RK3588
> 内核：vendor_6.1.x (BSP 内核)
> 日期：2026-07-16

---

## 一、核心原理

### 1.1 为什么 apt 安装的 mpv 不支持 rkmpp？

```
Debian apt 仓库的 mpv  →  链接到 Debian 官方 ffmpeg  →  无 rkmpp 支持
                         ↓
                    动态加载 libavcodec.so.60
                         ↓
                    官方 ffmpeg 没有 h264_rkmpp 解码器
```

**解决方案**：让 mpv 加载 ffmpeg-rockchip 的库（包含 rkmpp 解码器）。

### 1.2 两种实现方式

| 方式 | 复杂度 | 稳定性 | 适用场景 |
|------|--------|--------|----------|
| **A. mpv Wrapper** (LD_LIBRARY_PATH) | 低 | 高 | 快速部署，推荐 |
| **B. 重新编译 mpv** | 高 | 高 | 长期稳定，最佳 |

---

## 二、方案 A：mpv Wrapper（推荐，5分钟部署）

### 2.1 编译安装 ffmpeg-rockchip（库隔离到 /usr/local）

```bash
#!/bin/bash
set -e

# 安装依赖
sudo apt update
sudo apt install -y -qq \
    git cmake meson ninja-build pkg-config \
    gcc g++ make libdrm-dev libx11-dev \
    libfdk-aac-dev libmp3lame-dev libopus-dev \
    libx264-dev libx265-dev libass-dev \
    yasm nasm

# 编译 MPP
cd /tmp
rm -rf rkmpp
git clone -b jellyfin-mpp --depth=1 https://github.com/nyanmisaka/mpp.git rkmpp
cd rkmpp && mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_SHARED_LIBS=ON -DBUILD_TEST=OFF ..
make -j$(nproc) && sudo make install && sudo ldconfig

# 编译 RGA
cd /tmp
rm -rf rkrga
git clone -b jellyfin-rga --depth=1 https://github.com/nyanmisaka/rk-mirrors.git rkrga
cd rkrga
meson setup build --prefix=/usr/local --buildtype=release \
    --default-library=shared -Dlibdrm=false -Dlibrga_demo=false
ninja -C build && sudo ninja -C build install && sudo ldconfig

# 编译 ffmpeg-rockchip（库隔离到 /usr/local/lib/ffmpeg-rkmpp）
cd /tmp
rm -rf ffmpeg-rockchip
git clone --depth=1 https://github.com/nyanmisaka/ffmpeg-rockchip.git ffmpeg-rockchip
cd ffmpeg-rockchip
./configure \
    --prefix=/usr/local \
    --libdir=/usr/local/lib/ffmpeg-rkmpp \
    --enable-gpl --enable-version3 \
    --enable-libdrm --enable-rkmpp --enable-rkrga \
    --enable-shared --disable-static \
    --extra-ldflags="-Wl,-rpath,/usr/local/lib/ffmpeg-rkmpp" \
    --enable-nonfree
make -j$(nproc) && sudo make install && sudo ldconfig

# 设置 alternatives（优先使用自定义 ffmpeg）
for cmd in ffmpeg ffprobe ffplay; do
    sudo update-alternatives --install /usr/bin/$cmd $cmd /usr/local/bin/$cmd 100
    sudo update-alternatives --set $cmd /usr/local/bin/$cmd
done

echo "=== ffmpeg-rockchip 安装完成 ==="
```

### 2.2 创建 mpv Wrapper

```bash
#!/bin/bash
# 安装系统 mpv（依赖系统 ffmpeg，但 wrapper 会加载自定义库）
sudo apt install -y -qq mpv

# 备份原 mpv
sudo mv /usr/bin/mpv /usr/bin/mpv.distrib

# 创建 wrapper：加载 ffmpeg-rockchip 库
sudo tee /usr/bin/mpv << 'EOF'
#!/bin/bash
# mpv wrapper — 加载 ffmpeg-rockchip 自定义库以启用 rkmpp 硬件加速
export LD_LIBRARY_PATH=/usr/local/lib/ffmpeg-rkmpp:/usr/local/lib:${LD_LIBRARY_PATH}
exec /usr/bin/mpv.distrib "$@"
EOF
sudo chmod +x /usr/bin/mpv

# 创建显式快捷命令
sudo tee /usr/local/bin/mpv-rkmpp << 'EOF'
#!/bin/bash
export LD_LIBRARY_PATH=/usr/local/lib/ffmpeg-rkmpp:/usr/local/lib:${LD_LIBRARY_PATH}
exec /usr/bin/mpv.distrib "$@"
EOF
sudo chmod +x /usr/local/bin/mpv-rkmpp

echo "=== mpv wrapper 创建完成 ==="
```

### 2.3 mpv 配置（Debian X11）

```bash
sudo mkdir -p /etc/mpv
sudo tee /etc/mpv/mpv.conf << 'EOF'
# Debian X11 — RKMPP 硬件加速配置
# 适用：XFCE / GNOME / Deepin + Panfrost (Mali GPU)

# ========== 硬件解码 ==========
# 使用 auto 让 mpv 自动检测 ffmpeg 的 rkmpp 解码器
hwdec=auto
hwdec-codecs=all

# ========== 视频输出 ==========
vo=gpu
# 强制 OpenGL（Panfrost Mali 不支持 Vulkan）
gpu-api=opengl

# ========== 渲染质量（性能优化）==========
# 4K 视频降低质量以减少 GPU 负载
profile=fast
scale=bilinear

# ========== 缓冲 ==========
cache=yes
cache-secs=60
demuxer-max-bytes=50M

# ========== 字幕 ==========
sub-font-size=35
sub-color="#FFFFFFFF"
sub-border-color="#FF000000"
EOF

# 用户级配置
mkdir -p ~/.config/mpv
cp /etc/mpv/mpv.conf ~/.config/mpv/mpv.conf
```

### 2.4 验证

```bash
# 1. 验证 ffmpeg 硬解码
ffmpeg -hwaccel rkmpp -i video.mp4 -f null -
# CPU 应 < 20%

# 2. 验证 mpv 加载了正确的库
ldd $(which mpv) | grep libav
# 应看到 /usr/local/lib/ffmpeg-rkmpp/libavcodec.so

# 3. 验证 mpv 硬件解码
mpv --msg-level=vd=debug video.mp4 2>&1 | grep -iE "hwdec|Using|Decoder"
# 应看到 "Using hardware decoding" 和 h264_rkmpp

# 4. 播放测试
mpv video.mp4
# 按 i 键查看 OSD 信息，确认 "hwdec: auto" 和 "VO: gpu"
```

---

## 三、方案 B：重新编译 mpv（最佳性能）

如果 wrapper 方案不稳定，直接编译 mpv 链接到 ffmpeg-rockchip：

```bash
#!/bin/bash
set -e

# 卸载系统 mpv
sudo apt remove -y mpv

# 安装编译依赖
sudo apt install -y -qq \
    git meson ninja-build pkg-config \
    libdrm-dev libx11-dev libxext-dev \
    libgl1-mesa-dev libegl1-mesa-dev \
    libwayland-dev libwayland-egl-backend-dev \
    libass-dev libfreetype6-dev libfontconfig1-dev \
    liblua5.1-0-dev libuchardet-dev \
    libjpeg-dev libpng-dev

# 编译 mpv（链接到 /usr/local 的 ffmpeg-rockchip）
cd /tmp
rm -rf mpv
git clone --depth=1 https://github.com/mpv-player/mpv.git mpv
cd mpv

export PKG_CONFIG_PATH=/usr/local/lib/ffmpeg-rkmpp/pkgconfig:/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH

meson setup build \
    --prefix=/usr \
    -Dlibmpv=true \
    -Dlua=enabled \
    -Ddrm=enabled \
    -Dx11=enabled \
    -Dwayland=disabled \
    -Dgl-x11=enabled \
    -Degl-x11=enabled \
    -Degl-drm=enabled

ninja -C build
sudo ninja -C build install
sudo ldconfig

echo "=== mpv 编译完成 ==="
```

编译后的 mpv 直接链接到 ffmpeg-rockchip，无需 wrapper。

---

## 四、4K 视频优化

### 4.1 问题

Mali-G52 (RK3568) 或 Mali-G610 (RK3588) 通过 X11 渲染 4K 会丢帧：

```
Audio/Video desynchronisation detected!
Dropped: 83
```

### 4.2 解决方案

**方案 1：RGA 缩放到 1080p（推荐）**

```bash
# 使用 ffplay 硬件解码 + RGA 缩放
ffplay -hwaccel rkmpp -hwaccel_output_format drm_prime -afbc rga \
    -i 4K-video.mp4 -vf "scale_rkrga=w=1920:h=1080" -fs

# 或使用 ffmpeg 转码到 1080p
ffmpeg -hwaccel rkmpp -hwaccel_output_format drm_prime -afbc rga \
    -i 4K-video.mp4 -c:v h264_rkmpp -vf "scale_rkrga=w=1920:h=1080" \
    -b:v 4M -c:a copy 1080p-output.mp4
```

**方案 2：DRM 直接输出（绕过 X11，性能最佳）**

```bash
# 进入 TTY（Ctrl+Alt+F3）
mpv --vo=drm --hwdec=auto 4K-video.mp4
```

**方案 3：降低 mpv 渲染质量**

```bash
# 在 mpv.conf 中
profile=fast
scale=bilinear
# 禁用高级滤镜
dither-depth=no
# 降低色彩精度（如果支持）
# target-trc=bt.1886
```

---

## 五、一键安装脚本

```bash
#!/bin/bash
# Debian X11 RKMPP + mpv 一键安装
# 用法：sudo ./install-debian-rkmpp-mpv.sh

set -e

if [ "$EUID" -ne 0 ]; then
    echo "请使用 sudo 运行"
    exit 1
fi

echo "=== Debian X11 RKMPP + mpv 安装 ==="

# 1. 编译 ffmpeg-rockchip
echo "[1/3] 编译 ffmpeg-rockchip..."
# ...（上方 2.1 的代码）...

# 2. 创建 mpv wrapper
echo "[2/3] 创建 mpv wrapper..."
# ...（上方 2.2 的代码）...

# 3. 配置 mpv
echo "[3/3] 配置 mpv..."
# ...（上方 2.3 的代码）...

echo "=== 安装完成 ==="
echo ""
echo "验证命令："
echo "  ffmpeg -decoders | grep rkmpp"
echo "  mpv --msg-level=vd=debug video.mp4 2>&1 | grep hwdec"
echo ""
echo "4K 播放建议："
echo "  ffplay-hw 4K-video.mp4        # 缩放到 1080p"
echo "  mpv --profile=fast 4K-video.mp4 # 降低质量"
```

---

## 六、常见问题

### Q1: `hwdec=auto` 没有调用 rkmpp？

检查 mpv 是否加载了 ffmpeg-rockchip 的库：
```bash
ldd $(which mpv) | grep libavcodec
# 应看到 /usr/local/lib/ffmpeg-rkmpp/libavcodec.so
# 而不是 /usr/lib/aarch64-linux-gnu/libavcodec.so
```

### Q2: `gpu-api=opengl` 报错？

某些旧版 mpv 不支持 `gpu-api` 选项，改为：
```bash
vo=gpu
gpu-context=x11
```

### Q3: 画面撕裂？

```bash
# 在 X11 配置中启用 TearFree
sudo tee /etc/X11/xorg.conf.d/20-tearfree.conf << 'EOF'
Section "Device"
    Identifier "Mali-GPU"
    Driver "modesetting"
    Option "TearFree" "true"
EndSection
EOF
```

### Q4: 音频不同步？

```bash
# 增加音频缓冲
audio-buffer=1.0
# 或禁用音频同步（仅测试）
# no-audio-sync
```

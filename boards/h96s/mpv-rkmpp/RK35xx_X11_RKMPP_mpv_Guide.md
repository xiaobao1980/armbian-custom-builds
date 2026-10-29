# RK35xx X11 RKMPP + mpv 硬件加速指南（实测版 v3 — 官方 mpv v0.41.0 + rkmpp 后端补丁）

> **适用**：RK3566 / RK3568 / RK3576 / RK3588
> **系统**：Debian / Ubuntu / Armbian（vendor 6.1 BSP 内核），X11 桌面（XFCE / GNOME / Deepin + Panfrost Mali GPU）
> **实测平台**：H96 MAX M9（RK3576）Armbian trixie，kernel 6.1.172-vendor-rk35xx，Mali-G52 / Mesa 25.0.7
> **版本**：2026-10-27 v3（mpv 官方 v0.41.0 源码 + nyanmisaka/boogiepop rkmpp 后端补丁 `mpp.patch`）
> **路线**：mpp(jellyfin-mpp) → rkrga(jellyfin-rga) → ffmpeg-rockchip → **官方 mpv v0.41.0 源码 + `mpp.patch`（注入 rkmpp 解码后端）**

---

## 〇、前提与权威结论（2026-10-27 校正）

1. **内核 `6.1.172-vendor-rk35xx` 没问题**：它是 Armbian 的 Rockchip BSP vendor 内核，`/dev/mpp_service` 存在，rkmpp 全套前提已满足。
2. **mpv 官方主线 v0.41.0 只含 drmprime *帧格式* 支持，不含 rkmpp *解码后端***。wiki 列的三个 mpv 补丁（NV16 / P010 / P210）对应的是 `hwdec_drmprime` 的**帧格式**支持，这部分确已合并进主线（源码 `video/out/hwdec/hwdec_drmprime.c` 在）。但 rkmpp 的**解码后端**（`AV_HWDEVICE_TYPE_RKMPP` 设备、`ra_hwdec_drmprime_rkmpp` 渲染驱动、`hwdec=rkmpp` 选项）**从未进官方主线** —— 铁证：v0.41.0 源码 `video/out/hwdec/` 目录下**没有 `hwdec_rkmpp.c`**，且 `--hwdec=help` 的 rkmpp 项数为 0。**必须用补丁或等价 fork 注入该后端**。锁定 `v0.41.0`（2025-12 最新稳定版；0.41 起 `--vo=gpu` 默认 gpu-next 渲染器，X11 下渲染参数更简），对其应用 `mpp.patch`（nyanmisaka + boogiepop 联合维护的 rkmpp 后端补丁）即获得 fork 同款能力。
3. **`mpp.patch` 是本路线的核心，不是过时方案**。github.com/nyanmisaka/mpv 这个 fork 仓库不存在（404），但 nyanmisaka 的 rkmpp 工作以补丁形式提供（PATCH 2/3 作者即 nyanmisaka）。对官方 v0.41.0 应用 `mpp.patch` ≡ 使用 nyanmisaka/boogiepop 的 rkmpp fork 后端，已在 RK3576/RK3568 板实测通过。
4. 仍需 **ffmpeg-rockchip** 提供 `h264_rkmpp` / `hevc_rkmpp` / `vp9_rkmpp` / `av1_rkmpp` 解码器；mpv 只负责把 rkmpp 解码出的 `drm_prime` 帧上传 GPU。
5. **vendor 基线内核缺两颗 wiki 补丁**（rga3 10bit 修复、vop2 修复），**只影响 10bit 播放和 Kodi GBM 模式；8bit 播放完全不受影响**。10bit 花屏就退到 `force_yuv=8bit` 动态转 8bit 绕开。详见第十二节。
6. 真正还需留意的补丁只剩：**内核侧 rga3（仅 10bit 涉及）**、**librga（nyanmisaka 的 jellyfin-rga 分支已自带修复）**。

---

## 一、核心原理

```
┌─────────────┐   hwdec=rkmpp/rkmpp-copy    ┌──────────────────────┐
│  mpv 播放器  │ ── rkmpp 后端(mpp.patch 注入) ─▶│ ffmpeg-rockchip        │
│ (官方主线编译) │                              │  h264_rkmpp 等解码器  │
└─────────────┘ ◀── drm_prime 帧 ─────────────└──────────────────────┘
       │ 上传到 GPU（GLX/EGL，由 ffmpeg-rockchip 的 RKMPP 提供解码）
       ▼
  Panfrost / Mesa 渲染输出到 X11
```

- **X11 桌面下**：mpv 的 rkmpp 自动选 `rkmpp-copy`（显存→CPU→GPU 双拷贝）。可用，但有带宽开销。
- **TTY + `--gpu-context=drm`**：走 `drmprime_rkmpp` **零拷贝**直出（rkmpp 帧直接送 DRM overlay plane），性能最佳但仅 TTY 生效。

---

## 二、安装构建依赖

```bash
sudo apt update
sudo apt install -y -qq \
    git cmake meson ninja-build pkg-config \
    gcc g++ make yasm nasm \
    libdrm-dev libdisplay-info-dev libx11-dev libxext-dev libxrandr-dev libxv-dev \
    libx11-xcb-dev libxcb-shm0-dev libxcb-xfixes0-dev \
    libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev \
    libass-dev libfreetype6-dev libfontconfig1-dev \
    liblua5.1-0-dev libuchardet-dev \
    libx264-dev libx265-dev libdav1d-dev \
    libvorbis-dev libogg-dev libmp3lame-dev libopus-dev \
    libpulse-dev libpipewire-0.3-dev libasound2-dev

# ⚠️ 关键：libdisplay-info-dev 必须装！mpv 的 features['drm'] 依赖 libdisplay-info>=0.1.1，
# 否则 meson 自动探测关闭 DRM -> video/out/hwdec/hwdec_drmprime.c（rkmpp 驱动所在文件）不编译
# -> 即使打了 mpp.patch，--hwdec=rkmpp 也永远不会出现。

# 若 meson < 1.1（Debian bookworm 常见），从 pip 升级
if dpkg --compare-versions "$(meson --version)" lt "1.1"; then
    pip3 install --break-system-packages -U meson ninja 2>/dev/null || pip3 install -U meson ninja
fi
```

> 不要动系统 ffmpeg（`apt remove ffmpeg` 会影响浏览器等组件）。ffmpeg-rockchip 将隔离安装到 `/usr/local/lib/ffmpeg-rkmpp`。

---

## 三、编译 rkmpp（Rockchip MPP 解码库）

```bash
cd /tmp
rm -rf mpp && git clone -b jellyfin-mpp --depth=1 https://gitee.com/nyanmisaka/mpp.git
cd mpp && mkdir -p build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON \
      -DBUILD_TEST=OFF ..
make -j"$(nproc)"
sudo make install
sudo ldconfig
pkg-config --exists rockchip_mpp && echo "MPP OK: $(pkg-config --modversion rockchip_mpp)"
```

> ⚠️ **别用厂商 / BSP 镜像自带的旧 mpp deb**。wiki 明确警告：旧 mpp 与最新 ffmpeg-rockchip 版本差太大，运行 rkmpp 解码会**段错误**。必须自己编 jellyfin-mpp 分支。

---

## 四、编译 rkrga（2D 图像加速，缩放/色彩转换用）

```bash
cd /tmp
rm -rf rkrga && git clone -b jellyfin-rga --depth=1 https://gitee.com/nyanmisaka/rga.git rkrga
cd rkrga
meson setup build --prefix=/usr/local --buildtype=release \
    --default-library=shared -Dlibdrm=false -Dlibrga_demo=false
ninja -C build
sudo ninja -C build install
sudo ldconfig
pkg-config --exists librga && echo "RGA OK: $(pkg-config --modversion librga)"
```

> 此分支 **已自带 rga3 / librga 修复**（10bit、AFBC 转换必需），无需额外打补丁。

---

## 五、编译 ffmpeg-rockchip（硬解核心，隔离安装）

```bash
cd /tmp
rm -rf ffmpeg-rockchip && git clone --depth=1 https://github.com/nyanmisaka/ffmpeg-rockchip.git
cd ffmpeg-rockchip

./configure --prefix=/usr/local \
    --libdir=/usr/local/lib/ffmpeg-rkmpp \
    --enable-gpl --enable-version3 --enable-nonfree \
    --enable-shared --disable-static \
    --enable-libdrm --enable-rkmpp --enable-rkrga \
    --enable-libx264 --enable-libx265 --enable-libdav1d \
    --enable-gnutls \
    --extra-ldflags="-Wl,-rpath,/usr/local/lib/ffmpeg-rkmpp" \
    --disable-doc --disable-debug --disable-ffplay

make -j"$(nproc)"

# ★ 装前先验证 rkmpp 解码器存在（必须在 make install 之前、build 目录里跑）
./ffmpeg -hide_banner -decoders 2>/dev/null | grep -E 'h264_rkmpp|hevc_rkmpp|vp9_rkmpp|av1_rkmpp'
# 应输出 4 行 *_rkmpp 解码器；若为空，说明 --enable-rkmpp 没生效（检查 mpp/rga 是否先装好且 pkg-config 可见）

sudo make install
sudo ldconfig

# 让运行时（不仅限于编译期）能找到这个隔离的 libavcodec
echo '/usr/local/lib/ffmpeg-rkmpp' | sudo tee /etc/ld.so.conf.d/99-ffmpeg-rockchip.conf
sudo ldconfig
```

---

## 六、编译 mpv（官方 v0.41.0 源码 + rkmpp 后端补丁 mpp.patch）

> **关键**：官方 mpv v0.41.0 主线**不含 rkmpp 解码后端**（仅含 drmprime 帧格式），`--hwdec=rkmpp` 选项数为 0。必须用 `mpp.patch`（nyanmisaka + boogiepop 维护）注入 `ra_hwdec_drmprime_rkmpp` / `AV_HWDEVICE_TYPE_RKMPP` 等后端。对官方 v0.41.0 应用此补丁 ≡ 使用 nyanmisaka/boogiepop 的 rkmpp fork 后端（github.com/nyanmisaka/mpv 仓库本身 404，以补丁形式提供）。

```bash
cd /tmp
rm -rf mpv && git clone https://github.com/mpv-player/mpv.git
cd mpv

# 锁定 v0.41.0（2025-12 最新稳定版；0.41 起默认 gpu-next 渲染器，X11 渲染参数更简）
MPV_TAG=v0.41.0
git checkout "$MPV_TAG"

# ★ 注入 rkmpp 解码后端（必须用 git apply；该补丁是 3 段 git 序列，patch -p1 会因同文件多 diff 段失败）
#   mpp.patch 来源：armbian-custom-builds/boards/h96s/mpv-rkmpp/mpp.patch（同仓库）
git apply /path/to/mpp.patch || patch -p1 < /path/to/mpp.patch

# 让 meson 找到隔离的 ffmpeg-rockchip
export PKG_CONFIG_PATH=/usr/local/lib/ffmpeg-rkmpp/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}

# RK35xx 桌面走 GLX：显式开 x11/gl-x11/egl-x11；
# ⚠️ -Ddrm=enabled 必须显式开：rkmpp 渲染驱动位于 video/out/hwdec/hwdec_drmprime.c，
#    受 features['drm'] 控制，依赖 libdrm + libdisplay-info（第二节已装）。不强制则自动探测失败 -> rkmpp 不编译。
rm -rf build
meson setup build --prefix=/usr/local --buildtype=release \
    -Dx11=enabled -Dgl-x11=enabled -Degl-x11=enabled \
    -Ddrm=enabled -Dwayland=disabled -Dlibmpv=true
ninja -C build -j"$(nproc)"
sudo ninja -C build install
sudo ldconfig

# ★ 验证：确认 mpv 链的是新的 ffmpeg-rockchip（而非系统 61）
ldd build/mpv | grep libavcodec
# 应指向 /usr/local/lib/ffmpeg-rkmpp/libavcodec.so.62（不是 /usr/lib/.../libavcodec.so.61）

# 验证 rkmpp hwdec 后端存在
mpv --hwdec=help 2>/dev/null | grep -c rkmpp
# 应 >= 1（正常为 rkmpp / rkmpp-copy 多项，连同各 *_rkmpp 解码器约 20 项）
```

> 安装到 `/usr/local` 后，默认 `mpv` 命令即为此构建。`MPV_CONFDIR` 默认为 `/usr/local/etc/mpv`；若想以 `/etc/mpv` 为真源，软链即可：
> ```bash
> sudo mkdir -p /usr/local/etc/mpv
> sudo ln -sfn /etc/mpv/mpv.conf /usr/local/etc/mpv/mpv.conf
> ```

---

## 七、配置 CMA（4K 流畅的前提）

RK 平台 4K 解码需要足够的 CMA（连续内存）。**重刷后默认常为 256M，4K 会卡/掉帧**，建议设 `cma=512M`。

- **Armbian**：编辑 `/boot/armbianEnv.txt`，在 `extraargs=` 后追加（无则新增一行）：
  ```
  extraargs=cma=512M
  ```
  保存后 `sudo reboot`。
- **其它固件**：在 `/boot/uEnv.txt`、`/boot/boot.ini` 或内核 cmdline 加 `cma=512M`。
- **校验**：
  ```bash
  dmesg | grep -i cma
  grep CmaTotal /proc/meminfo
  ```
  > 若重启后 CmaTotal 仍是 256M，说明 CMA 在设备树（dts）里被写死，需重编内核或找厂商 dts 调整。

---

## 八、mpv.conf（X11 桌面）

```bash
sudo mkdir -p /etc/mpv
sudo tee /etc/mpv/mpv.conf >/dev/null <<'EOF'
# RK35xx X11 — RKMPP 硬件加速配置
# 桌面走 rkmpp-copy（双拷贝）；TTY/DRM 走零拷贝请见第十一节

# ========== 硬件解码 ==========
hwdec=rkmpp
hwdec-codecs=all

# ========== 视频输出 ==========
vo=gpu                  # 0.41 起默认 gpu-next 渲染器，X11 下无需额外调渲染参数
gpu-api=opengl          # Panfrost Mali 不支持 Vulkan，强制 OpenGL 上下文
profile=fast           # 轻量预设；追求画质可改 gpu-hq（更吃 GPU）

# ========== 缓冲 ==========
cache=yes
cache-secs=60
demuxer-max-bytes=50M

# ========== 字幕 ==========
sub-font-size=35
sub-color="#FFFFFFFF"
sub-border-color="#FF000000"
EOF
```

---

## 九、udev 设备权限

```bash
echo 'KERNEL=="mpp_service", MODE="0666"' | sudo tee /etc/udev/rules.d/99-mpp.rules
# rga 不参与解码，但 ffmpeg -vf scale_rkrga 等滤镜需要；v3.5 起脚本会一并写入
echo 'KERNEL=="rga", MODE="0666"' | sudo tee -a /etc/udev/rules.d/99-mpp.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
# 启用 MPP 负载统计（可选）
echo 1000 | sudo tee /proc/mpp_service/load_interval
```

> 早期安装（v3.3）只写了 `mpp_service` 一行，`/dev/rga` 会停在 `crw-------`。
> `verify-rkmpp-image.sh` 第 3 段现已自愈：缺行自动补 + reload/trigger，仍不生效则 `chmod 666` 兜底。

---

## 九·五、桌面菜单里找不到 mpv（XFCE/GNOME）

**症状**：终端里 `mpv` 能跑，但开始菜单/应用查找器搜不到 "mpv"。原因不在 PATH，
而是栈只装了 `/usr/local/bin/mpv`，**没有 `.desktop` 菜单项**（发行版的 mpv 包才会带）。

栈（v3.6 起）会在 `configure_runtime` 阶段安装三样东西：

| 文件 | 作用 |
|---|---|
| `/usr/share/applications/mpv.desktop` | 菜单项，`Name=mpv` / `Name[zh_CN]=mpv 播放器`，类别 AudioVideo;Video;Player，`Icon=rkmpp-mpv` |
| `/usr/share/icons/hicolor/scalable/apps/rkmpp-mpv.svg` | 菜单图标（**独立命名**，见下方「图标有两个坑」） |
| `/usr/local/bin/mpv-desktop` | 菜单入口 wrapper：**无参时开 idle 窗口**（非全屏、可拖拽文件），带参时按 `mpv.conf` 正常全屏播放 |

为什么需要 wrapper：`mpv` 不带参数会打印用法后立即退出，菜单项直接 `Exec=mpv %U` 点了"像没反应"。

装完刷新（XFCE 通常重开菜单即生效）：

```bash
sudo update-desktop-database /usr/share/applications 2>/dev/null
sudo gtk-update-icon-cache -f /usr/share/icons/hicolor        # 必须 -f，理由见下
DISPLAY=:0 XAUTHORITY=/home/$USER/.Xauthority xfce4-panel -r  # 让面板重新解析图标
# 验证菜单项能真正拉起窗口（无参 → idle 窗口常驻）
DISPLAY=:0 XAUTHORITY=/home/$USER/.Xauthority /usr/local/bin/mpv-desktop   # Ctrl+C/q 退出
```

### 图标有两个坑（v3.7 实测确认，都会静默失败）

**坑 1：`Icon=mpv` 会被主题自带图标顶掉。**
发行版主题里可能自带 `mpv.svg`（如 `Numix-Circle/48/apps/mpv.svg`，官方 8bit 小图标），
主题目录优先级高于 hicolor，于是菜单显示的是主题那个、不是栈自带的。
→ 栈改用独立名 `Icon=rkmpp-mpv`，任何主题都不会有同名文件，必然落到 hicolor。

**坑 2：`icon-theme.cache` 不重建 = 图标永远不生效，且无任何报错。**
GTK 只要发现 `/usr/share/icons/hicolor/icon-theme.cache` 存在，就**只按缓存查图标，不重扫目录**。
新增图标文件后若不重建缓存，`Gtk.IconTheme.lookup_icon("mpv",24)` 直接返回 `NULL`，
菜单静默回退到主题的通用图标（Numix 下是蓝色 `applications-multimedia` 方块）——
看起来就像"图标文件没装"，实际文件好好的。
注意 `-t` 不是"更新"（它是 `--ignore-theme-index`），必须用 **`-f` 强制重建**；没有该工具时删掉旧缓存也行（无缓存 GTK 会直接扫目录）。

自查（这条能直接判死）：

```bash
python3 - <<'EOF'
import gi; gi.require_version('Gtk','3.0')
from gi.repository import Gtk; Gtk.init([])
i = Gtk.IconTheme.get_default().lookup_icon('rkmpp-mpv', 24, 0)
print(i.get_filename() if i else 'NULL ← 缓存没重建，或名字被主题覆盖')
EOF
```

想把视频/音频默认打开方式设为 mpv（可选，会写 `/etc/xdg/mimeapps.list`）：

```bash
sudo MPV_SET_DEFAULT=yes bash rk35xx-rkmpp-mpv-build.sh build   # 重跑配置阶段
```

---

## 十、验证硬解

```bash
# 1) rkmpp hwdec 后端应存在
mpv --hwdec=help 2>&1 | grep -i rkmpp

# 2) 解码路径验证（无显示也能跑：vo=null 隔离解码链）
mpv --vo=null --hwdec=rkmpp-copy --frames=150 \
    /home/xiaobao/Videos/4K-Chimei-inn-60mbps.mp4 2>&1 \
    | grep -iE "Looking at hwdec|Using hardware decoding|Using software decoding"
# 应输出 "Using hardware decoding (rkmpp-copy)"

# 3) 真实播放（X11 桌面开窗口）
mpv /home/xiaobao/Videos/4K-Chimei-inn-60mbps.mp4
# 按 i 看 OSD：hwdec: rkmpp-copy，VO: gpu

# 4) 看 rkvdec 负载（另开终端）
watch -n1 cat /proc/mpp_service/load
```

---

## 十一、X11 下的性能真相（重要，避免误判）

| 编码 / 场景 | 模式 | RK3576 X11 实测 |
|---|---|---|
| H.264 4K@30 | `rkmpp-copy` | **满帧 7.61×**，流畅 |
| VP9 4K@60 | `rkmpp-copy` | **~0.07×（卡）**——双拷贝带宽墙 + VP9 解码重 |
| VP9 4K@60 | 零拷贝（`--gpu-context=drm`，TTY） | **满帧 59.94fps** |

**结论**：
- 普通 H.264/HEVC 4K 在 X11 桌面用 `rkmpp-copy` 已流畅，无需折腾。
- **VP9 4K60 在 X11 下必然卡**（双拷贝带宽限制），这是硬件/架构限制，不是配置问题。**根治 = 零拷贝直出**（见下）。
- 重刷后若 H.264 也卡，优先查 **CMA 是否仍是 256M**（第七节）。

### 零拷贝进阶（VP9 4K60 满帧，可选）

仅在 **TTY（无 X）** 下生效：

```bash
# 本地 TTY（Ctrl+Alt+F3）登录后
mpv --hwdec=rkmpp --gpu-context=drm \
    /home/xiaobao/Videos/LG-UHD-4K_60FPS.mkv
# 日志应见：Using overlay plane N as drmprime plane  → 零拷贝直出
```

> ⚠️ **已知坑**：mpv 在 DRM teardown（播完退出拆解）阶段可能**死锁**，进程不退、屏幕冻在最后一帧，需手动重启。可改用带看门狗的 `mpv-lg4k.sh`（自动切空闲 TTY + `--gpu-context=drm` + 退出卡死时 15s 内强杀切回桌面），位于 `armbian-custom-builds/boards/h96s/mpv-rkmpp/mpv-lg4k.sh`。桌面环境下也可直接调用它（SSH 有 openvt+sudo 时驱动板子物理屏）。

---

## 十二、10bit 与 vendor 内核补丁注意事项

`6.1.172-vendor-rk35xx` 是 vendor 基线，**wiki 那两颗内核补丁大概率没带**：

| 补丁 | 影响范围 | 8bit 播放 | 10bit 播放 | Kodi GBM |
|---|---|---|---|---|
| rga3 10bit 修复 | 10bit 色彩/格式转换 | 不受影响 | 可能花屏/异常 | 受影响 |
| vop2 修复 | 显示路径 / 多屏 | 不受影响 | 受影响 | 受影响 |

- **8bit 内容完全不受影响**，按本指南正常硬解即可。
- **10bit 花屏的绕过**：在 `mpv.conf` 里加 `force-yuv=8bit`（动态把 10bit 转 8bit 输出，放弃 10bit 精度换流畅）：
  ```bash
  echo 'force-yuv=8bit' | sudo tee -a /etc/mpv/mpv.conf
  ```
- 若要在 10bit 下真正修复，需自行把 rga3 10bit 补丁打到内核（仅 10bit 场景需要，8bit 用户无需动内核）。
- **librga 的对应修复**：已包含在第三节的 `jellyfin-rga` 分支里，用户态无需额外处理。

---

## 十三、故障排查表

| 现象 | 根因 | 解决 |
|---|---|---|
| `--hwdec=help` 无 rkmpp | ①没打 `mpp.patch`（v0.41.0 主线不含 rkmpp 后端）②没显式 `-Ddrm=enabled` 且缺 libdisplay-info（DRM 特性关闭→hwdec_drmprime.c 不编译）③没链上 ffmpeg-rockchip | 重做第六节：先 `git apply mpp.patch`；确认 `-Ddrm=enabled` 且 `libdisplay-info-dev` 已装；`ldd build/mpv \| grep libavcodec` 应为 ffmpeg-rkmpp 的 62 |
| `ldd build/mpv` 链到系统 libavcodec.so.61 | meson 用了系统 ffmpeg 的 .pc | 确认 `PKG_CONFIG_PATH` 把 `/usr/local/lib/ffmpeg-rkmpp/pkgconfig` 放最前，且 `pkg-config --modversion libavcodec` 显示 62 |
| `build version 62 incompatible with runtime 61` | 编译用 62 头文件，运行时落到系统 61 | 确认 `/etc/ld.so.conf.d/99-ffmpeg-rockchip.conf` 含 `/usr/local/lib/ffmpeg-rkmpp` 且已 `ldconfig` |
| `./ffmpeg -decoders \| grep rkmpp` 为空 | `--enable-rkmpp` 未生效 | 检查 mpp/rga 是否先装好且 `pkg-config` 可见；重做第五节 |
| `Using software decoding`（X11 下） | mpv 未链上 ffmpeg-rockchip（用了系统 ffmpeg 无 rkmpp 解码器） | 见上，确保 mpv 链到 ffmpeg-rkmpp 的 libavcodec |
| 4K 播放掉帧/卡 | CMA 不足（默认 256M）或 VP9 4K60 双拷贝带宽墙 | 设 `cma=512M`（第七节）；VP9 4K60 改零拷贝（第十一节） |
| 10bit 花屏 | vendor 内核缺 rga3 10bit 修复 | `force-yuv=8bit` 绕开（第十二节）；或打内核 rga3 补丁 |
| `/dev/mpp_service` 权限拒绝 | udev 规则未生效 | 第九节重载 udev；或临时 `sudo chmod 666 /dev/mpp_service` |
| meson 报 `wayland ... not found` | 误开了 wayland | 确认 `-Dwayland=disabled`（第六节） |
| rkmpp 解码段错误 | 用了厂商旧 mpp deb（版本不匹配） | 按第三节用 gitee jellyfin-mpp 重编 mpp，不要用系统 mpp 包 |

---

## 附：为什么"apt mpv + LD_LIBRARY_PATH wrapper"仍不推荐

该思路误以为"让 mpv 加载 ffmpeg-rockchip 库，hwdec=auto 就会自动用 rkmpp"。现状已变化：

- **mpv 官方主线 v0.41.0 仍缺 rkmpp 解码后端**（仅含 drmprime 帧格式，无 `hwdec_rkmpp.c`），`--hwdec=rkmpp` 选项数为 0。必须用 `mpp.patch` 注入后端（见第六节），所以"mpv 缺后端"依然是核心问题之一。
- **另一卡点**在 ffmpeg 侧：Debian/Ubuntu 的 apt mpv 链接的是**发行版 ffmpeg**（如 libavcodec 61，**没有** `h264_rkmpp` 解码器）。即使给 mpv 打了 rkmpp 后端，没有解码器驱动，hwdec=rkmpp 也会回落软解。
- 因此必须让 mpv 用上 **ffmpeg-rockchip**（含 rkmpp 解码器），两条路：
  1. **推荐（本指南）**：自己编译官方 mpv，编译期 `PKG_CONFIG_PATH` 指向 ffmpeg-rockchip → 干净、可复现。
  2. 不推荐：用 `LD_LIBRARY_PATH` wrapper 让 apt mpv 指向 ffmpeg-rockchip —— 仅当 apt mpv 版本足够新（含 rkmpp 后端）时才可能生效，且易因版本漂移/符号冲突翻车。
- 结论：**wrapper 换库对"旧版 apt mpv"无效；编译官方 mpv + 链 ffmpeg-rockchip 才是正路。**

---

## 十四、跨发行版 / 跨架构：必须重编 + 重打包（v3.5）

### 14.1 为什么不能复用现成的 `rkmpp-stack_*.deb`

`rkmpp-stack_0.41.0-1_arm64.deb` 是**发行版 + 架构双重绑定**的产物，不是通用包：

| 绑定项 | 原因 |
|---|---|
| 架构（arm64） | 二进制由该架构的 gcc 编译、glibc 链接；armhf/其它架构无法复用 |
| 发行版（trixie） | `Depends` 由 `dpkg-shlibdeps` **从编译机当前系统的 SONAME 现场算出**：`libplacebo349`、`libx264-164`、`libx265-215`、`libdav1d7`、`libc6 (>= 2.38)` 等。换发行版这些名字就变 |
| glibc | 二进制要求运行系统 glibc ≥ 编译机；bookworm（2.36）直接装不上 `libc6>=2.38` |

因此：**换发行版 → 必须重编；换架构 → 必须重编。** 不存在"拿 trixie 包塞进 noble/bookworm"的捷径。

### 14.2 哪些平台能编

- **架构**：仅 `arm64`（RK3288 是 32 位 ARMv7，不在本栈范围）。
- **SoC**：RK3566 / RK3568 / RK3576 / RK3588（vendor BSP 内核，需有 `/dev/mpp_service`、`/dev/rga`）。
- **发行版**：trixie ✅ / noble ✅ / deepin25 ✅（同源 trixie 时）/ bookworm、jammy ⚠️ —— 后两者自带 `libplacebo` < 6.338.2，mpv 0.41 硬依赖不满足，需先自编 libplacebo 或改用 trixie/noble。
- **桌面**：X11（Wayland 不适用）。

### 14.3 在目标板重编 + 重打包（一条命令）

```bash
# 编译 + 安装 + 自动重打「当前发行版/架构」的 deb
sudo BUILD_DEB=yes bash rk35xx-rkmpp-mpv-build.sh build
# 产物（默认）：/home/xiaobao/rkmpp-build/debs/rkmpp-stack_0.41.0-1_<arch>.deb

# 若栈已装好，只想重打包（如重刷发行版后）
sudo bash mkdeb-rkmpp-stack.sh --outdir /root/debs

# 或走 pack 子命令
sudo OUTDIR=/root/debs bash rk35xx-rkmpp-mpv-build.sh pack
```

`mkdeb-rkmpp-stack.sh` 会：按 `dpkg --print-architecture` 定架构、按 `dpkg-architecture` 定 multiarch 目录（`/usr/local/lib/<triple>/`）、用 `dpkg-shlibdeps --ignore-missing-info` 现算 Depends、写 `postinst`（ldconfig + udev 重载），并在包里落地构建标记。

### 14.4 构建标记与"错包拦截"

重编/重打后，包里会多一个 `/usr/local/share/rkmpp-stack/build-info`：

```
ARCH=arm64
MULTIARCH=aarch64-linux-gnu
DISTRO_CODENAME=trixie
GLIBC=2.41
MPV=0.41.0
MPP=1.3.9
RGA=2.1.0
```

`rkmpp-mpv.sh` 扩展在安装预编译包前会读它，与目标 `ARCH`/`RELEASE` 比对；**不一致就丢弃该 deb、自动转源码编译**，不会把 trixie 包硬装到 noble 上。旧包（无 build-info）按 trixie 处理。

### 14.5 发布到其它平台的预编译包

```bash
# 在新平台板子上重编并打包后取出
scp xiaobao@<board>:/root/debs/rkmpp-stack_0.41.0-2_arm64.deb .

# 以带发行版/架构信息的新 tag 上传（示例）
gh release create rkmpp-stack-v0.41.0-noble-arm64 \
  rkmpp-stack_0.41.0-2_arm64.deb --repo <owner>/armbian-custom-builds
```

CI 的"预拉预编译包"步骤按 tag 拉取（当前按 `rkmpp-stack-v0.41.0-2` → `-1` 顺序回退，
见 `.github/workflows/build-image.yml`）；换平台就改 tag 列表，指向对应产物。

**当前已发布**：

| tag | 版本 | 适用 | 说明 |
|---|---|---|---|
| `rkmpp-stack-v0.41.0-2` | 0.41.0-2 | arm64 / trixie / X11 | 含桌面菜单项 + `rkmpp-mpv.svg` + postinst 强制重建图标缓存 + build-info + rga udev 行 |
| `rkmpp-stack-v0.41.0-1` | 0.41.0-1 | arm64 / trixie / X11 | 旧包，无桌面集成（菜单里搜不到 mpv），仅作回退 |

`0.41.0-2` 实测 sha256 `4e3c262ecdb25381a9d209fab8a066b2d8d4ccfb4b15c86e0909128e1787d75a`，
11,251,200 B，77 条目。若 `build-info` 里 `MPP/RGA` 显示 `unknown`，说明该镜像没有
`pkg-config`（v3.8 起会自动回退解析 `.pc` 的 `Version:` 行）。

### 14.6 验收

```bash
dpkg-deb -f <deb> Architecture
dpkg-deb --fsys-tarfile <deb> | tar -xO ./usr/local/share/rkmpp-stack/build-info
sudo bash verify-rkmpp-image.sh /path/to/4k.mp4   # 期望 PASS=14 FAIL=0（含桌面段）
```


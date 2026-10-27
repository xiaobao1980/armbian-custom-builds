# H96 MAX M9 (RK3576) —— mpv rkmpp 硬解重编译记录

- **板子**：192.168.50.103，Armbian trixie，kernel 6.1.172-vendor-rk35xx
- **日期**：2026-10-27
- **结论**：mpv v0.40.0 + `mpp.patch` + ffmpeg-rockchip 8.0 编译成功，`hwdec` 列表出现 `rkmpp` / `rkmpp-copy`（10 种编码），4K H.264 硬解实测通过。

## 1. 背景

重刷系统后板载 Debian mpv 0.40.0 **完全没有 rkmpp**：

- `mpv --hwdec=help` 无任何 rkmpp 项 → 因为 Debian 包是对系统 ffmpeg 7.1.5（libavcodec 61）编译的，`AV_HWDEVICE_TYPE_RKMPP` 不存在，驱动在编译期被裁掉。
- `/usr/local/lib/ffmpeg-rkmpp/` 里是 **ffmpeg 8.0**（libavcodec 62.28.103，10 个 rkmpp 解码器），与板载 so.61 **soname 不匹配** → 只改 `LD_LIBRARY_PATH` 的 wrapper 方案在本板无效，必须重编。

## 2. 源码来源确认（重要）

| 来源 | 是否含 rkmpp | 说明 |
|---|---|---|
| mpv v0.39.0 / v0.40.0 官方源码 | ❌ | `meson.options` 无 rkmpp 选项，无 `hwdec_rkmpp.c` |
| hbiyik/mpv `mpp` 分支（实为 0.41.0） | ❌ | 末次提交名带 rkmpp，但全仓无 rkmpp 源码 |
| **hbiyik/mpv `mpp.patch`（compare 补丁，3 commits）** | ✅ | 把 `ra_hwdec_drmprime_rkmpp`（`.name="drmprime_rkmpp"`）等注进 `hwdec_drmprime.c` / `hwdec_drmprime_overlay.c` / `hwdec.c`，无 meson 开关 |

即：**rkmpp 靠 patch 注入，且依赖系统 ffmpeg 提供 `AV_HWDEVICE_TYPE_RKMPP`**。

## 3. 四个卡点与修法（按出现顺序）

### 坑 A：`FF_PROFILE_*` 未定义（demux_mkv.c）

```
error: 'FF_PROFILE_ARIB_PROFILE_A' undeclared; did you mean 'AV_PROFILE_ARIB_PROFILE_A'?
```

ffmpeg 7 起删除旧宏名。修法：

```bash
sed -i 's/FF_PROFILE_/AV_PROFILE_/g' demux/demux_mkv.c
```

### 坑 B：`ext-data-control-v1.h` 缺失（wayland 剪贴板）

mpv 0.40 默认 `wayland=auto`，`player/clipboard/clipboard-wayland.c` 找不到生成的头。
本板桌面是 X11，直接关掉：

```bash
-Dwayland=disabled
```

### 坑 C：`mpv_protocols` 生成失败 → `build version 62 incompatible with runtime version 61`

这是最隐蔽的一个：`.pc` 里 `libdir=/usr/local/lib/ffmpeg-rkmpp`，但该目录**不在 pkg-config 默认搜索路径**，且**不在 ld.so 路径**里。结果：

- 头文件 → `/usr/local/include`（62）
- 链接 → 系统 `/lib/.../libavcodec.so.61`
- 自检（`mpv --list-protocols`）→ 报 build 62 vs runtime 61

修法两处一起做：

```bash
echo /usr/local/lib/ffmpeg-rkmpp | sudo tee /etc/ld.so.conf.d/99-ffmpeg-rockchip.conf
sudo /sbin/ldconfig
export PKG_CONFIG_PATH=/usr/local/lib/ffmpeg-rkmpp/pkgconfig:/usr/local/lib/pkgconfig
```

> 注意：`echo xxx | sudo tee` 在密码走 stdin（`echo pw | sudo -S tee`）时会被吞掉，写出空文件，表现为 `ldconfig` 后仍找不到 so.62。要先把内容写进临时文件再 `cp`。

### 坑 D：配置不生效——`MPV_CONFDIR` 不是 `/etc/mpv`

```
#define MPV_CONFDIR "/opt/mpv-rkmpp/etc/mpv"
```

meson 的 `sysconfdir` 相对 prefix。写成 `/etc/mpv/mpv.conf` 对自编译 mpv 完全无效（表现：日志里连 `Looking at hwdec ...rkmpp` 都没有，直接软解）。修法：软链回 `/etc/mpv`，保持单一真源。

```bash
sudo mkdir -p /opt/mpv-rkmpp/etc/mpv
sudo ln -sfn /etc/mpv/mpv.conf /opt/mpv-rkmpp/etc/mpv/mpv.conf
```

## 4. 最终生效配置

`/etc/mpv/mpv.conf`

```ini
hwdec=rkmpp,rkmpp-copy,auto-safe
hwdec-codecs=all
vo=gpu
gpu-api=opengl
profile=fast
```

`/etc/mpv/mpv-x11.conf`：`gpu-context=x11`（GLX）

`/usr/local/bin/mpv` → 指向 `/opt/mpv-rkmpp/bin/mpv`（旧文件备份为 `mpv.bak.<时间戳>`）

## 5. 验证结果

| 证据 | 结果 |
|---|---|
| `mpv --hwdec=help` | 10 种编码 × `rkmpp` / `rkmpp-copy` |
| 解码路径 | `Looking at hwdec h264_rkmpp-rkmpp... Could not create device.` → `Looking at hwdec h264_rkmpp-rkmpp-copy...` → `Using hardware decoding (rkmpp-copy)` |
| VPU 负载 | `27b00100.rkvdec load: 47~54% utilization: 25~27%` |
| CPU（4K H.264） | 硬解 37~44% vs 软解 136% |
| X11 输出 | `--vo=x11` 正常（XPresent enabled） |

链式声明 `rkmpp,rkmpp-copy,...` 是有效的：零拷贝失败会自动试下一项（这点已实测确认，不是文档推测）。

## 6. 未完成项

- **`vo=gpu` + `gpu-context=x11`（GLX）从 SSH 侧无法验证**：mpv 卡在 `[vo/gpu/x11] X11 opening display: :0`，`glxinfo` 同样无输出；但 `xdpyinfo` 正常、`--vo=x11` 正常，说明 X 服务器本身活着，是 GLX/GPU 客户端路径被卡住（疑似前面 SIGKILL 掉的 GLX 客户端把 X 的 GL 上下文弄僵）。需在电视端确认，或重启 lightdm 后复测。
- 顺带发现：**板载 Debian mpv 根本没有 GLX 后端**（`--gpu-context=x11` 报 "option parameter could not be parsed"），刷新前它走的是 `x11egl`。我们这版显式开了 `gl-x11` + `egl-x11`，两个 context 都可用，GLX 不行时可退 `--gpu-context=x11egl`。

## 7. 复现

```bash
scp mpp.patch build-mpv-rkmpp.sh xiaobao@192.168.50.103:/home/xiaobao/
ssh xiaobao@192.168.50.103 'bash /home/xiaobao/build-mpv-rkmpp.sh'
```

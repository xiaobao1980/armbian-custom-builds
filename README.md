# armbian-custom-builds

自定义 RK 系列板卡的 Armbian 构建仓库：**按板卡目录隔离，调用官方 [armbian/build](https://github.com/armbian/build) 在线（GitHub Actions）或本地编译镜像**。

每块板卡一个独立目录，构建时同步脚本只把选中板卡的 `config/`、`patch/`、`userpatches/` 拷入全新 clone 的官方 build 树 —— **板卡之间零干扰**（目录结构对齐构建机 192.168.60.170 `/home/xiaobao/U24/build/userpatches/` 的板内布局）。跨板共用能力放 `common/`（如 `common/extensions/`），由同步脚本一并投放到 `userpatches/extensions/`。

## 板卡清单

| 板卡 | SoC | BOARDFAMILY | 默认 BRANCH/RELEASE | 关键定制 |
|---|---|---|---|---|
| `aio-3288c` | RK3288 | rockchip | edge / noble | add-board DTS、WK2124 SPI-UART（RS232+RS485）、dwc2 host 修复、wk2xxx extension |
| `h96s` | RK3576 | rk35xx | vendor / noble | 2026-08-29 golden 基线：9999 DTS 补丁、SAI TDM lanes 修复、`h96-m9-configure`（音频/蓝牙/VPU）经 .csc hook 部署 |
| `am60-sa12` | RK3588 | rockchip-rk3588 | vendor / bookworm | rk3588-am60-sa12 DTS（kernel+u-boot）、tcpci_et7303.ko、触控/HDMI/RT5616 全套 overlay |
| `neardi-lz200` | RK3576 | rk35xx | vendor / bookworm | 自定义 defconfig/DTS 补丁 + `linux-neardi-lz200-rk3576.config` |

每个板卡目录结构（U24 构建机同构）：

```
boards/<board>/
├── build.env              # BOARD/BRANCH/RELEASE/BUILD_DESKTOP/BUILD_MINIMAL/ENABLE_EXTENSIONS 默认值
├── config/boards/*.csc    # 板卡配置（同步到 build/config/boards/）
├── patch/                 # in-tree 内核补丁（仅 aio-3288c rockchip-6.18 需要）
├── userpatches/           # U-Boot / kernel / overlay / extensions / customize-image.sh
└── reference/             # 参考源文件（不参与构建同步）

common/extensions/
├── mesa-vpu.sh            # 公共扩展：jammy|noble + GNOME/Wayland 桌面 → mesa/panthor/
│                          # rockchip-multimedia PPA + 浏览器（与 rkmpp-mpv 自动二选一）
├── rkmpp-mpv.sh           # 公共扩展：其它组合 → RKMPP + mpv 硬解 + 全局非 Wayland (X11)
│                          # （两者可同开，判定互补，详见「硬解栈选路」专节）
└── rk35xx-chinese-desktop.sh          # 公共扩展：RK35xx 中文桌面通用设置
    └── chinese-desktop/               #   （用户/locale/时区/字体/输入法/Chromium/DTB 过滤,
        └── rk35xx-chinese-desktop.sh  #    ENABLE_EXTENSIONS=rk35xx-chinese-desktop）

docs/
└── Debian_X11_RKMPP_MPV_Guide.md   # RKMPP+mpv 完整原理/手册（扩展的上游参考）
```

## 在线编译（GitHub Actions）

Actions 页面两个入口：

1. **Build Armbian Image (单板)** — 下拉式参数（参照 ophub/amlogic-s9xxx-armbian 的交互），跑完在 Artifacts 下载 `*.img.xz`（保留 14 天）。
2. **Build All Boards (矩阵)** — 5 块板并行矩阵构建，可用 `boards` 输入筛选（如 `h96s,am60-sa12`）。

单板手动触发的参数一览（全部为下拉，选 `default` 即回落该板 `build.env`）：

| 输入 | 取值 | 映射到 armbian |
|---|---|---|
| `board` | 5 块板 | `BOARD` |
| `edition` | `default` / `desktop` / `server` / `minimal` | `BUILD_DESKTOP` + `BUILD_MINIMAL` |
| `desktop_environment` | `default` / `gnome` / `xfce` / `kde-plasma` / `cinnamon` / `mate` / `lxqt` / `i3-wm` / `budgie` | `DESKTOP_ENVIRONMENT` |
| `desktop_tier` | `default` / `minimal` / `mid` / `full` | `DESKTOP_TIER` |
| `kernel_branch` | `default` / `vendor` / `current` / `edge` / `legacy` | `BRANCH` |
| `kernel_version` | 如 `6.1.172`（留空=跟随分支最新） | `KERNELBRANCH=tag:v<x.y.z>` |
| `release` | `default` / `noble` / `bookworm` / `trixie` / `jammy` / `resolute` | `RELEASE` |
| `compress` | `xz` / `7z` / `none` | `COMPRESS_OUTPUTIMAGE` |
| `build_ref` | 默认 `main` | armbian/build 的 git 引用 |

组装后的参数串会在运行日志的「构建摘要」步骤里打印，便于核对。**架构守卫**会在构建前拦掉不可能的搭配（如 armhf 板选 `gnome`），直接给出可选清单而不是等到装包阶段才失败。

免费 runner 单次构建约 1.5–3 小时（限 6 小时）；构建前自动清理 runner 磁盘腾出 ~50GB。构建统一带 `DOWNLOAD_MIRROR=china`（国内镜像源）。

### 镜像发布（GitHub Releases）

构建成功后自动把镜像发布到 [Releases](../../releases) 页（类似 ophub/amlogic-s9xxx-armbian），**长期可下载，不随 Artifacts 过期**：

- 单板 / 矩阵 workflow 均有 `publish_release` 开关（默认开）
- tag 规则：`<board>-<yyyymmdd>-r<run>`（如 `h96s-20261023-r11`）；**每次构建独立 Release，所有版本镜像全部保留**，仅同 run 号 rerun 时覆盖自身资产
- 附件：`*.img.xz` + `.sha` 校验 + 构建参数/烧写命令写在 Release Notes
- ⚠️ GitHub Release **单文件上限 2GiB**；超限文件（如 compress=none 的 6GB 裸 img）自动跳过、仅留 Artifacts
- Actions Artifacts 并行保留 **90 天**，作为大文件/失败日志的兜底；长期历史版本一律走 Releases

> 🔴 **`build_ref` 必须用 `main`**（默认值已是 `main`）。armbian/build 的 `master` 是**旧分支**（老 CLI + 交互向导，CI 无 TTY 会直接退 255）；主线在 `main`。

> ⚠️ **aio-3288c 注意**：其内核补丁按 `rockchip-6.18` 目录组织，要求 armbian/build 的 edge 内核仍为 6.18.x。若上游 edge 已升级（如 6.19+），请在 `build_ref` 输入中固定一个 6.18 时代的 build 引用（tag/commit）。

### 定制版工作流（X11 / Wayland）

在标准版之外另有两条**开箱即用**的定制流程，与标准版并存、互不影响：

| Workflow | 文件 | 固定策略 | 典型用法 |
|---|---|---|---|
| Build Armbian Image (单板) | `build-image.yml` | 全部可调（标准版） | 通用构建 |
| Build All Boards (矩阵) | `build-all.yml` | 各板 `build.env` | 批量出图 |
| **Build Armbian Image (X11 定制版)** | `build-x11.yml` | 桌面强制 X11（xfce/cinnamon/mate/lxqt/i3-wm）+ 硬解走 `rkmpp-mpv`（mpv/ffmpeg-rockchip 零拷贝）+ gdm3 `WaylandEnable=false` | neardi-lz200 / trixie 这类已验证的 X11 硬解板 |
| **Build Armbian Image (Wayland 定制版)** | `build-wayland.yml` | 桌面强制 Wayland（gnome/kde-plasma/budgie）+ 硬解走 `mesa-vpu`（rockchip-multimedia PPA，零编译）+ gdm3 `WaylandEnable=true`；**不启用** `rkmpp-mpv` | h96s / noble 这类 Wayland 板 |

两者都额外提供**默认用户设置**（由公共扩展 `common/extensions/default-user.sh` 在构建期 chroot 内落盘，不依赖首启 rc.local 时序）：

| 输入 | 默认 | 说明 |
|---|---|---|
| `user_name` | `xiaobao` | 小写字母/数字/`_`/`-`，≤32；留空=不创建默认用户 |
| `user_password` | `123456` | 仅 `A-Za-z0-9 . _ + # = : @ % -`，4~64 位（含空格/引号的密码会污染 `compile.sh` 参数，CI 直接拒绝） |
| `root_password` | `123456789` | 留空=不改 root 密码 |
| `user_groups` | `sudo,adm,audio,video,plugdev,netdev,render,input,dialout,cdrom` | rootfs 里不存在的组自动跳过 |
| `sudo_nopasswd` | `true` | 写入 `/etc/sudoers.d/90-<user>`（`visudo -cf` 校验失败会自动删除） |
| `desktop_autologin` | `true` | lightdm / gdm3 / sddm 均支持；烧卡开机直接进桌面 |

落地痕迹（镜像内，**不含密码**）：`/etc/default-user.conf`（用户/组/免密/自动登录开关）、`/etc/default-user.autologin`（实际 DM 与会话名）。

> 🔐 密码经**环境变量**传给构建框架（不拼进 `compile.sh` 命令行），因此不会出现在 Armbian 的 `Applying cmdline param` 日志里；workflow 侧另有 `::add-mask::` 与字符集白名单双保险。

> ⚠️ **Wayland 定制版的硬解前提**：`mesa-vpu` 的 PPA 只发布 `jammy` / `noble`。选 `trixie` / `bookworm` 时 `mesa-vpu` 会自动跳过（镜像无硬解栈），预检步骤默认**直接拦下**；确实只要桌面不要硬解时才勾 `allow_no_hwdec`。

> ⚠️ **X11 定制版的预编译 deb**：`rkmpp-stack_*.deb` 的 build-info 写死 `DISTRO_CODENAME=trixie`，目标不是 trixie 时扩展会回退 chroot 源码编译（qemu 下极易撞 6h 上限），预检步骤会提前 `::warning::`。


## 硬解栈选路：mesa-vpu / rkmpp-mpv（自动二选一）

**规则（唯一判据）：**

| 条件 | 生效扩展 | 说明 |
|---|---|---|
| `RELEASE=jammy\|noble` + 桌面镜像 + Wayland 能力桌面（`gnome` / `kde-plasma` / `budgie`） | **`mesa-vpu`** | PPA 栈（`liujianfeng1994/rockchip-multimedia`），零编译、镜像小 ~57MB |
| `RELEASE=jammy` + 任意桌面 | **`mesa-vpu`** | jammy 自带 libplacebo 4.x < 6.338.2，自编译 mpv 必失败，只能走 PPA |
| 其它（noble + X11 桌面 / `bookworm` / `trixie` / `resolute` / server） | **`rkmpp-mpv`** | 源码编译 MPP+RGA+ffmpeg-rockchip+mpv（+20–40 分钟） |

两块扩展**可以同时写进 `ENABLE_EXTENSIONS`**，各自按实际参数判定，判定严格互补 —— 绝不会双开（PPA 栈与自编译栈混装）或双关（两条硬解路径都不装）。当前三块板均两者同开：

| 板卡 | 默认组合 | 实际生效 |
|---|---|---|
| `h96s`（h96-m9） | noble + gnome | **mesa-vpu**（+ panthor overlay 仅 noble 加） |
| `neardi-lz200` | trixie + xfce | **rkmpp-mpv**（强制 X11） |
| `am60-sa12` | bookworm + server | **rkmpp-mpv**（跳过显示管理器配置） |
| `aio-3288c` | noble + xfce（RK3288/armhf） | 两者都不适用：`LINUXFAMILY=rockchip` 不在 rkmpp 支持家族内，PPA 也没有 armhf 的 rk35xx 包。它单独启用板级内核扩展 `wk2xxx-aio3288c`（WK2124 SPI-4UART / RS232+RS485） |

> ⚠️ `userpatches/extensions/*.sh` **不会**被自动加载：必须在 `build.env` / preset / 命令行里用 `ENABLE_EXTENSIONS=<名字>` 显式启用，且钩子函数必须是 `<hook>__<impl>` 双下划线形式（单写 `function <hook>()` 不会被调用）。`aio-3288c` 的 `wk2xxx-aio3288c` 曾因此完全失效（`CONFIG_SPI_WK2XXX` 从未被置 y → 板上没有任何 `ttyWK*`）。

> 为什么不在 `build.env` 里写死某一个：CI 的 `build-image.yml` 允许覆盖 `release` / `desktop_environment`，写死就会在覆盖后选错（例如 h96s 选 `release=jammy` 或 `desktop_environment=xfce` 都应变路）。判定点分别在 `mesa-vpu.sh` 的 `_mesa_vpu__selected()` 与 `rkmpp-mpv.sh` 的 `_rkmpp_mpv__defer_to_mesa_vpu()`，**改一侧必须同步另一侧**。

可覆盖变量：

| 变量 | 作用 |
|---|---|
| `MESA_VPU_FORCE=yes` | 强制走 PPA 栈（例如 noble + X11 桌面不想等 40 分钟自编译）；`rkmpp-mpv` 自动让位 |
| `MESA_VPU_PANTHOR=yes` | 非 noble 也加 `panthor-gpu` overlay（默认仅 noble：jammy 的 mesa 22.x 无 panthor 驱动） |
| `RKMPP_MPV_SKIP_BUILD=yes` | 跳过自编译，只做 CMA/X11 兜底（软解基线排查） |
| `RKMPP_MPV_PREBUILT=no` | 不用预编译 deb，强制源码编译 |

## 公共扩展：rkmpp-mpv（RKMPP 硬解 + 全局非 Wayland）

所有 **vendor 内核**的 RK3566/RK3568/RK3576/RK3588 板卡默认启用（`ENABLE_EXTENSIONS` 里与 `mesa-vpu` 逗号连用，实际是否执行由上面的选路规则决定）。完整原理见 `docs/Debian_X11_RKMPP_MPV_Guide.md`。扩展按场景**自动选路**：

**路径一：jammy|noble + 桌面 + mesa-vpu（PPA 栈，零编译）**

mesa-vpu 已启用的 amazingfated PPA（`liujianfeng1994/rockchip-multimedia`）里，ffmpeg 6.1.1 构建参数即带 `--enable-rkmpp --enable-rkrga`（changelog: "Add mpp patch from nyanmisaka"）。PPA 自己的 mpv 重打包（`0.36.0-1+j1`）现仅剩 jammy/armhf、noble 已下架，noble 上 apt 装 Ubuntu 官方 mpv 0.37 —— 但其动态链接 PPA 的 rkmpp 版 `libavcodec60`，`h264_rkmpp`/`hevc_rkmpp` 等 wrapper 解码器会被 mpv 动态注册为 hwdec 方法（mpv 从 libavcodec 枚举 `wrapper_name`），硬解可用。检测到该 PPA pin 时直接装 `mpv`/`ffmpeg`，跳过自编译（构建快 4 分钟、镜像小 ~57MB）。

**路径二：bookworm / server / 未启用 mesa-vpu（自编译栈）**

按指南方案 A 在 chroot 内源码编译：

1. **RKMPP 编解码栈**：MPP（jellyfin-mpp）+ RGA（jellyfin-rga）+ ffmpeg-rockchip，库隔离在 `/usr/local/lib/ffmpeg-rkmpp`，不污染系统 ffmpeg；
2. **mpv wrapper**：`/usr/bin/mpv` 经 `LD_LIBRARY_PATH` 加载 rkmpp 版 libavcodec（`h264_rkmpp`/`hevc_rkmpp`/`av1_rkmpp` 硬解），另有显式命令 `mpv-rkmpp`。

**两条路径共同落盘**：

3. **全局 `/etc/mpv/mpv.conf`**：`hwdec=rkmpp`（显式锁定——`hwdec=auto` 的探测白名单不含 rkmpp，会把它排在最后且随机序；rkmpp 初始化失败时 mpv 自动回退软解）+ `vo=gpu` + `gpu-api=opengl`（X11 渲染基线，Panfrost 无 Vulkan）+ 4K 性能优化（`profile=fast`）；
4. **全局非 Wayland**：GNOME/gdm3 写 `WaylandEnable=false`，KDE/sddm 写 `DisplayServer=x11`，另加 modesetting `TearFree` 防撕裂。

板上验证：

```bash
# PPA 路径: libavcodec 应为 PPA 版 (6.1.1-3ubuntu5+git240504...~noble); 自编译路径: 应指向 /usr/local/lib/ffmpeg-rkmpp/
ldd $(which mpv) | grep libavcodec
ffmpeg -decoders 2>/dev/null | grep rkmpp        # 应列出 h264_rkmpp/hevc_rkmpp 等
mpv --msg-level=vd=debug video.mp4 2>&1 | grep -iE "hwdec|rkmpp"   # 应显示 hwdec: rkmpp 生效
echo $XDG_SESSION_TYPE                  # 应为 x11
```

说明：
- 非条件板卡（edge/current 内核、minimal、非 rk35xx/rk3588 家族）自动跳过，零副作用；
- server 镜像（如 am60-sa12，noble/bookworm + `BUILD_DESKTOP=no`）走自编译路径（供 kiosk/无人值守播放直接 `mpv` 硬解），仅跳过显示管理器配置；
- ⚠️ **bookworm 自编译必失败**：自带 `libplacebo 5.229` < mpv 0.41 硬依赖 `6.338.2`，脚本会在检查处 `exit 1` 中止镜像构建（扩展已在 prepare 阶段先打 warn）。需要 mpv 硬解请用 `trixie`（7.349）或 `noble`（6.338.2）；只想先跑通、暂不要硬解栈时设 `RKMPP_MPV_SKIP_BUILD=yes`；
- 自编译路径约 +20–40 分钟（arm64 原生 runner），**建议 x86 runner 时选 `runner=ubuntu-24.04-arm`**，qemu 模拟下编译会慢数倍；PPA 路径无编译开销；
- 调试时可传 `RKMPP_MPV_SKIP_BUILD=yes` 跳过编译，只装 mpv + 写配置（软解基线排查用）。

## 公共扩展：rk35xx-chinese-desktop（中文桌面通用设置）

`common/extensions/rk35xx-chinese-desktop.sh` 为 **RK3566/3568/3576/3588 厂商内核**镜像补齐四类中文化能力，**跨板共享但多板编译互不影响**：

| 能力 | 落地 | 说明 |
|---|---|---|
| root 密码 + 首启建用户 | `chpasswd` + `rc.local`→`armbian-firstboot-user.sh` | 幂等；建用户早于显示管理器（`display-manager.service.d` After/Requires） |
| Locale / 时区 / 字体 | `/etc/locale.conf`、`/etc/timezone`、chrony 中国 NTP、Noto/WQY/文泉驿 | zh_CN.UTF-8；`Asia/Shanghai`；Debian 可选 `locales-all` |
| 输入法（雾凇拼音 rime-ice） | **GNOME→ibus-rime**；**X11/XFCE 等→fcitx5-rime** | rime-ice 多镜像回退下载；框架按 `DESKTOP_ENVIRONMENT` 自动选路 |
| Chromium 中文 + DTB 过滤 | `/etc/chromium.d`、policy、Local State；`$SDCARD/boot/dtb` 剪枝 | 只留本板 dtb 与本平台 dtbo；**匹配不到则跳过删除**（安全优先） |

**隔离保证**：守卫 `LINUXFAMILY=~^(rk35xx|rockchip-rk3588)$ && BRANCH=vendor` 且非 minimal；只写 `$SDCARD`；板级差异全走各板 `build.env`。

板级可调变量（写进 `boards/<board>/build.env` 或 `.csc`）：

```bash
RK_CN_USER=xiaobao          # 普通用户（默认 xiaobao）
RK_CN_USER_PASS=123456      # 普通用户密码
RK_CN_ROOT_PASS=123456789   # root 密码
RK_CN_TZ=Asia/Shanghai      # 时区
RK_CN_IME=auto              # auto|fcitx5|ibus（auto: gnome→ibus，其余→fcitx5）
RK_CN_LOCALES_ALL=1         # Debian 是否装 locales-all（1/0，省约 200MB）
RK_CN_RIME_MIRROR=          # 可选：rime-ice 优先镜像前缀
```

启用：`ENABLE_EXTENSIONS=...,rk35xx-chinese-desktop`。当前已接入 `h96s`（GNOME/Wayland→ibus-rime）、`neardi-lz200`（XFCE/X11→fcitx5-rime）与 `am60-sa12`（server，仅 locale/字体/用户）。

> ⚠️ 与 `rkmpp-mpv` 的会话取向关系（已由选路规则自动处理）：`rkmpp-mpv` 会把 GNOME 强制成 X11（`WaylandEnable=false`）。按上表，**noble + GNOME/Wayland 由 `mesa-vpu` 接管、`rkmpp-mpv` 自动让位**，所以 h96s 仍是真正的 GNOME/Wayland + ibus-rime；只有落到 `rkmpp-mpv` 的组合（noble+X11 / bookworm / trixie / server）才会出现「GNOME 被压成 X11」，那里输入法走 ibus（X11 下同样可用），XFCE 走 fcitx5。

## 本地编译

```bash
git clone --depth=1 --branch main https://github.com/armbian/build armbian-build
bash scripts/sync-board-to-build.sh h96s armbian-build
cd armbian-build
source ../boards/h96s/build.env
# ⚠️ main 的参数任意顺序均可; 若用旧的 master 分支, KEY=VALUE 必须在目标命令之前
sudo ./compile.sh \
  BOARD=${BOARD} BRANCH=${BRANCH} RELEASE=${RELEASE} \
  BUILD_DESKTOP=${BUILD_DESKTOP} BUILD_MINIMAL=${BUILD_MINIMAL} \
  DESKTOP_ENVIRONMENT=${DESKTOP_ENVIRONMENT} DESKTOP_TIER=${DESKTOP_TIER} \
  ENABLE_EXTENSIONS=${ENABLE_EXTENSIONS} \
  KERNEL_CONFIGURE=no EXPERT=yes DOWNLOAD_MIRROR=china \
  COMPRESS_OUTPUTIMAGE=sha,img,xz \
  build
# 产物: output/images/*.img.xz
```

## 维护约定

- **`BUILD_DESKTOP=yes` 必须同时给 `DESKTOP_ENVIRONMENT` 和 `DESKTOP_TIER`**：新框架会在缺省时弹 `Choose a desktop environment` / `Choose desktop tier` 对话框，CI 无 TTY 直接以 `stdin is not a terminal. can't use dialog` 退 43。档位 `minimal`（仅 DE，~500MB）/ `mid`（+浏览器、文件管理器、媒体，~1GB）/ `full`（+办公、创作、开发，~2.5GB）。
- 桌面可用性受**架构**限制：`gnome` / `kde-plasma` / `kde-neon` / `deepin` 只支持 `arm64`/`amd64`；**armhf 板（如 RK3288 的 aio-3288c）只能选 `xfce` / `cinnamon` / `mate` / `i3-wm` / `enlightenment`**。
- 新板卡 = `boards/<name>/` 建目录（config/boards + userpatches + build.env），并在两个 workflow 的 options/matrix 中登记。
- 补丁一律放 `userpatches/kernel/<family-branch>/`（新式）或该板 `patch/kernel/archive/<dir>/`（旧式 in-tree，仅 AIO 使用）。
- 板级开机定制写在各自 .csc 的 `post_family_tweaks__*` hook 中（host 上下文、只对本板生效）；**不要**往 `customize-image.sh` 塞板级逻辑 —— 官方对所有板无条件 source 它，会互相污染（除非自行加 `$BOARD` 守卫）。
- `.DS_Store` / `._*` / `*.bak*` 不入库。

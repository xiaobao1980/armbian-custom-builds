# armbian-custom-builds

自定义 RK 系列板卡的 Armbian 构建仓库：**按板卡目录隔离，调用官方 [armbian/build](https://github.com/armbian/build) 在线（GitHub Actions）或本地编译镜像**。

每块板卡一个独立目录，构建时同步脚本只把选中板卡的 `config/`、`patch/`、`userpatches/` 拷入全新 clone 的官方 build 树 —— **板卡之间零干扰**（目录结构对齐构建机 192.168.60.170 `/home/xiaobao/U24/build/userpatches/` 的板内布局）。跨板共用能力放 `common/`（如 `common/extensions/`），由同步脚本一并投放到 `userpatches/extensions/`。

## 板卡清单

| 板卡 | SoC | BOARDFAMILY | 默认 BRANCH/RELEASE | 关键定制 |
|---|---|---|---|---|
| `aio-3288c` | RK3288 | rockchip | edge / noble | add-board DTS、WK2124 SPI-UART（RS232+RS485）、dwc2 host 修复、wk2xxx extension |
| `h96-m9` | RK3576 | rk35xx | vendor / noble | 内核 DTS 直放 `kernel/rk35xx-vendor-6.1/`、U-Boot defconfig（u-boot-rockchip64） |
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
└── mesa-vpu.sh            # 公共扩展：vendor 内核 + GNOME 桌面启用 mesa/panthor/
                           # rockchip-multimedia/浏览器（ENABLE_EXTENSIONS=mesa-vpu）
```

## 在线编译（GitHub Actions）

Actions 页面两个入口：

1. **Build Armbian Image (单板)** — 选板卡，可选覆盖 BRANCH/RELEASE/DESKTOP/armbian build ref，跑完在 Artifacts 下载 `*.img.xz`（保留 14 天）。
2. **Build All Boards (矩阵)** — 5 块板并行矩阵构建，可用 `boards` 输入筛选（如 `h96s,am60-sa12`）。

免费 runner 单次构建约 1.5–3 小时（限 6 小时）；构建前自动清理 runner 磁盘腾出 ~50GB。构建统一带 `DOWNLOAD_MIRROR=china`（国内镜像源）。

> 🔴 **`build_ref` 必须用 `main`**（默认值已是 `main`）。armbian/build 的 `master` 是**旧分支**（老 CLI + 交互向导，CI 无 TTY 会直接退 255）；主线在 `main`。

> ⚠️ **aio-3288c 注意**：其内核补丁按 `rockchip-6.18` 目录组织，要求 armbian/build 的 edge 内核仍为 6.18.x。若上游 edge 已升级（如 6.19+），请在 `build_ref` 输入中固定一个 6.18 时代的 build 引用（tag/commit）。

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

# armbian-custom-builds

自定义 RK 系列板卡的 Armbian 构建仓库：**按板卡目录隔离，调用官方 [armbian/build](https://github.com/armbian/build) 在线（GitHub Actions）或本地编译镜像**。

每块板卡一个独立目录，构建时同步脚本只把选中板卡的 `config/`、`patch/`、`userpatches/` 拷入全新 clone 的官方 build 树 —— **板卡之间零干扰**（目录结构对齐构建机 192.168.60.170 `/home/xiaobao/U24/build/userpatches/` 的板内布局）。跨板共用能力放 `common/`（如 `common/extensions/`），由同步脚本一并投放到 `userpatches/extensions/`。

## 板卡清单

| 板卡 | SoC | BOARDFAMILY | 默认 BRANCH/RELEASE | 关键定制 |
|---|---|---|---|---|
| `aio-3288c` | RK3288 | rockchip | edge / noble | add-board DTS、WK2124 SPI-UART（RS232+RS485）、dwc2 host 修复、wk2xxx extension |
| `h96s` | RK3576 | rk35xx | vendor / noble | 目录名 `h96s`，实际 `BOARD=h96-m9`。2026-08-29 golden 基线：9999 DTS 补丁、SAI TDM lanes 修复、`h96-m9-configure`（音频/蓝牙/VPU）经 .csc hook 部署 |
| `am60-sa12` | RK3588 | rockchip-rk3588 | vendor / bookworm | rk3588-am60-sa12 DTS（kernel+u-boot）、tcpci_et7303.ko、触控/HDMI/RT5616 全套 overlay。`audio-friendly-names` 在无头模式下只装 `audio-switch`：本板显示经 HDMI0 出 4K30、另有 RT5616 codec，ALSA 默认落到哪张卡取决于内核注册顺序，没声就 `sudo audio-switch hdmi`（或 `3.5`）切一次，`audio-switch list` 看候选；出厂不预设默认出口 |
| `neardi-lz120` | RK3568 | rk35xx | vendor / bookworm | Neardi LZ120 工业底板，**无头服务端**。上游 armbian 没有这块板：`config/boards/neardi-lz120.csc` 是厂商件（1-12 行逐字节照抄 + provenance 头），U-Boot 的 defconfig/dts 走 `userpatches/u-boot/legacy/u-boot-radxa-rk35xx/{defconfig,dt}`。四个内核补丁：`0001-lz120-dts`（厂商 DTS 全套；已把 `&pwm7` 红外接收器改 `disabled` —— 它和 4G 电源 `en_4G` 抢同一个 `gpio0_C6`，开机刷 `Error applying setting`；已把 `&vp0`/`&vp1` 的 `cursor-win-id` 从厂商的 `CLUSTER0`/`CLUSTER1` 改成 `ESMART0`/`ESMART1` —— rk3568 的 cluster 窗在驱动里 `format_modifiers_afbc_no_linear_mode` 只报 AFBC 不含 linear，而 GNOME/mutter 的光标缓冲是 GBM linear AR24，`drm_atomic_check_only` 报 `invalid pixel format AR24 ... modifier 0x0` 把 mutter 那笔「CRTC+主平面+游标」整笔拒掉，症状是「原生 HDMI 无信号 + 看不见光标」而另一路照常出桌面；厂商全系 rk3568/rk3566 板都这么写，但自家图形栈光标走 AFBC 且 SDK 默认只开 hdmitx1 单屏，所以从没踩到。2026-11-24 板上实测定根因）；同补丁另新增 `rk3568-neardi-lz120-linux-hdmi1.dts` —— 整份只是 `#include` 基础那份 + `route_dsi0`/`dsi0`/`lt8912` 三个 `status = "disabled"`，两份 dtb 反编译 diff 恰好只有这三行（源码机 dtc 核对），`dtb-y` 里两份都注册）、`0002-lz120-lt8912-driver`（DSI→HDMI 桥：1080p vtotal 必须 1125，panel 节点必须带 `dsi,no-dcs-backlight`）、`0003-lz120-hdmiin`（RK628 HDMI-IN；手上这块板 U1000 是**空 BGA 焊盘**没贴片，i2c3 全总线 NACK 属预期，贴片板若不通先把中断脚改回厂商 4.19 的 `&gpio0 RK_PB7`；`hdmiin-sound` 已置 `status = "disabled"` —— 采集卡是 `rockchip,trcm-sync-tx-only` 的 symmetric-rate dummy codec，`rockchip,capture-only` 属性 simple-card 根本不解析，PCM 仍带 playback 子流，任何播放侧 `hw_params` 都被拒成 -22 并无限刷屏（实测 card2 播放 write EIO、采集 read EIO）；视频采集走 `/dev/video*` + media0，与这条 i2s 通路无关，关掉只砍伴音）、`0004-lz120-lt8912-hpd`（把 Tx2 的实际插拔接进 DRM。链路性质：DSI→LT8912 在 DRM 里算「面板」而不是可探测连接器 —— `dw_mipi_dsi_connector_detect()` 只在 `next_bridge` 带 `DRM_BRIDGE_OP_DETECT` 时才往下问，而那颗桥是纯 i2c 器件、不在 bridge 链上，于是恒 `connected`。补丁打开 0002 里厂商留着没编的 `LT8912_HDP_CHECK`，1s 轮询桥寄存器 `0xC1` bit7 = 接收端 5V/HPD（207 板实测：插显示器 `0xfc`、拔线 `0x00`；dts 里那根 `irq-gpio` = gpio2_C5 两种状态都恒高，**不能**当判据；`i2c-4` 上 `0x50` 读不到 EDID，桥的 DDC 没透出，模式仍取 dts 那份 1080p timing）：插入 → 复位桥再起流，拔出 → 停输出，跳变后 `drm_kms_helper_hotplug_event()`；插入这一跳动哪几步由运行时档位 `/sys/module/lt8912/parameters/hpd_wake_action` 决定（`0`=不碰芯片只发事件 / `1`=出厂默认，rst 低 100ms → 释放 → 等满 1s → 补 `0x09=0xff`/`0x0b=0x7c` → `enable(1)` / `2`=再补一次断电重上电与 `get_chipid`），换档后完整拔插一次即生效。r29/r30 出厂镜像板上实测：不接 `disconnected`、接上自动 `connected` 并长出第二条，**冷启动两路都接不抖**；从插入到出图约 2~3s。遗留「热插唤醒后 Tx2 画面底部抖」到 r31 收口成已知问题、不再追：三档 0/1/2 各走一次完整拔插全抖、只接 Tx2 单屏冷启动不抖但同样拔插后抖、抖动时 KMS 状态里 vp1 与平面还是 1920x1080 1:1 —— 于是「唤醒线程动哪几步」「双屏并发时钟」「vp1 dclk」「桌面重排」「`standby_cfg` 那 6 笔寄存器残留」和更早的「复位后 0 等待 → 首笔 `0xb2` NACK」全部排除，站得住的只剩「Tx2 被关掉再重新起流之后才抖」；现场按开机前接好屏规避，已经抖了只能重启恢复（重新拔插不自愈），未试方向留档在 csc。r31 另记一条：登录界面落在 Tx2（进桌面后主屏回 Tx1）—— greeter 归 gdm3 自己的 mutter 管，hook 的 greeter 入口是 lightdm，没覆盖到；「系统设置 → 显示器」里 Tx2 顶着「内置显示器」排第一这条**本轮没改** —— 标签只由 connector_type 决定，把它报成 HDMIA 会让 VOP2 的 `vop2_crtc_mode_fixup()` 命中 DP/HDMI 分支、跳过 vp1 的 dclk 取整，属时序改动而非纯改名，单独一轮实测（评估见 csc「本地追加 6」）；同时让 `detect()` 改问新导出的 `lt8912_get_hpd()`、连接器补 `polled = POLL_CONNECT|POLL_DISCONNECT` 兜「事件早于 DRM 绑定」那一档。两处都用 `IS_ENABLED(CONFIG_DRM_LONTIUM_LT8912)` 圈住，那颗 bool 只有本板 `lz120-kernel-config` 置 y，同 family 其它板编出来的代码与改动前逐字节相同；单屏 dtb 下整条补丁是惰性的（桥节点 disabled → 不 probe → `-ENODEV` → 走原分支）。细节见 csc「本地追加 6」）。板级扩展 `lz120-kernel-config` 置 `CONFIG_DRM_LONTIUM_LT8912=y`（0002 新增的 bool，Kconfig **无 default**，不置 y 就是 DSI 正常而 HDMI 全黑）与 `CONFIG_DRM_PANEL_SIMPLE=y`（上游 `=m`，模块探测晚于 DRM 初始化 → 首屏黑/花）；两者只作用于本板，不动全局 `linux-rk35xx-vendor.config`。串口 `console=ttyFIQ0` 由厂商 DTS 的 `chosen/bootargs` 提供，**不需要**别板那个 serialcon hook。M.2 槽 = PCIe3x2（`combphy2_psq`，与原生 `&sata2` 互斥，厂商 dtsi 已把后者 disabled），实测 ASM1166 六口 SATA HBA 跑满 Gen3 x2、ahci 正常枚举；WiFi/BT = RTL8852BS：WiFi 由内核 `rtl8852bs`（SDIO `024c:b852`）带起，固件 `armbian-firmware` 已含；**蓝牙不是**「固件到位就行」——它在 `&uart1` = `/dev/ttyS1`，设备树只有厂商 `bluetooth-platdata` 胶水节点、没有 `bluetooth` 子节点，且内核 `hci_uart` 没注册 Realtek 的 UART 协议（bluez `hciattach` 无 realtek 类型、`btrtl.ko` 只认 USB 的 `rtl8852cu`），所以没有工具就永远没有 `hci0`，GNOME 蓝牙开关点了只翻 rfkill 电源。出厂由 `post_family_tweaks__lz120_bluetooth` 部署 `userpatches/lz120-bt-attach/`（`rtk_hciattach` 二进制 —— **必须静态链接**：r27 出厂镜像上原先入库的是厂商外部预编译件，它按 Rockchip 构建机的新 glibc 链、要 `GLIBC_2.42`，而 noble 只有 2.39，结果是二进制根本 exec 不了，守护只能每轮报「attach 后 15s 内没等到 hci0」而看不出根因；重编命令与验真见 csc「本地追加 5」 + attach 脚本 + `lz120-bluetooth.service`）并 enable。attach 脚本是**常驻看门狗**而不是一次性动作，因为 patchram 下载到芯片 RAM、掉电即失效，而 UI 关开蓝牙 / `rfkill block` / suspend 回来走的都是 `bt_rfkill` 的断电重上电：之后 `hci0` 名字还挂着但芯片不回任何东西（`hciconfig hci0 up` → `Connection timed out (110)`、`power on` → `Failed`、`connect` → `br-connection-adapter-not-powered`），一次性 attach 既不会失败也不会重启进程，结果就是「开机能连、UI 关开一次之后永远连不上」。脚本按 `bt_default` 的 soft-block 边沿重 attach（用户正关着时一律不动，不抢开关），重 attach 成功后自己 `power on`（新注册的适配器 BlueZ 算未上电，而回连守护要等 `Powered: yes`）；开机第一步显式 `rfkill unblock`，因为 `bt_default` 出厂态就是 blocked，桌面版有人解、无头镜像没人解。脚本里 attach 前的 `rfkill block → 2s → unblock` 断电重上电同样是必需的，缺它整条 H5 握手超时（详见 csc「本地追加 5」）；源码留档 `userpatches/rtk-hciattach-src/`，不部署进镜像。**hci0 有了还不等于音箱会连上**：BlueZ 只对 HID 做 auto-connect，A2DP/HFP 必须有客户端主动 connect，所以本板 `build.env` 启用 `bluetooth-autoconnect`（`rk-bluetooth-autoconnect` 守护，20s 一轮补连 Paired 且音频类设备（授信不作默认门槛，`REQUIRE_TRUSTED=1` 可收紧））。板上端到端：冷启动 uptime 1 分钟内 attach → 上电 → `已自动回连 HUAWEI CM510`；UI 关开一次后 12s 内自愈并回连。CAN 侧另有 `post_family_tweaks__lz120_can_quiet`：`rk3568_can` 的 `rk3568_can_get_berr_counter` 是 netdev_dbg 且出厂内核默认给它开 dyndbg，can0/can1 即使 DOWN、总线空着，只要有人做 netlink 接口 dump 就每 ~8s 刷两行恒为 0 的计数；该模块没有 dyndbg 模块参数，只能加载后写 `dynamic_debug/control`，故走 modprobe `install` 钩子，接口与 CAN 功能都不动。**显示出厂默认双屏**：`BOOT_FDT_FILE` 保持厂商原值 `rockchip/rk3568-neardi-lz120-linux.dtb`（两只 HDMI 座都在）；单屏那份 `...-linux-hdmi1.dtb` 靠 `.csc` 的 `DTB_KEEP_EXTRA` 一起留在镜像里当兜底，两份切换都不用重烧。Tx2（DSI→LT8912）不是坏路，但桥没有 EDID 也没有 HPD，未打 `0004` 时 DRM 恒报 `DSI-1 connected 1920x1080`（驱动内部锁 720P，两边不一致），GNOME「显示器」里永远多一条点不动的幽灵屏 —— 解法是 `0004` 把插拔接进 detect/hotplug，**别在运行态关 DSI**（xrandr/GNOME 关会让 VOP2 软硬状态分叉、两屏全黑，2026-11-23 板上复现）。双屏那份 + `0004` 下：不接 Tx2 只有一条屏，接上自动多一条；要退回「内核根本不注册 Tx2」，`sudo sed -i 's|^fdtfile=.*|fdtfile=rockchip/rk3568-neardi-lz120-linux-hdmi1.dtb|' /boot/armbianEnv.txt && sudo reboot`。**双屏那份下的主从**由 `post_family_tweaks__lz120_display_layout` 落盘（单屏那份或 Tx2 没接时，它按 `drm_status DSI-1` 自然早退）：开关文件 `/etc/default/lz120-display`（`LZ120_NATIVE_HDMI_PRIMARY=1`）+ `/usr/local/sbin/lz120-display-layout.sh`（GNOME 走 mutter `ApplyMonitorsConfig`、XFCE/X11 走 `xrandr`，都是「原生 HDMI 设 primary @(0,0)、LT8912 桥那路挪右侧扩展」并复核重放，因为会话起步时会被自己重排回出厂的重叠布局）+ autostart 与 lightdm `greeter-setup-script` 两个入口 |
| `neardi-lz200` | RK3576 | rk35xx | vendor / trixie | 自定义 defconfig/DTS 补丁 + `linux-neardi-lz200-rk3576.config`。RELEASE **必须** trixie（预编译 deb 钉死 trixie SONAME，如 `libplacebo349`；bookworm 的 libplacebo 5.229 编不出 mpv 0.41） |
| `cm3588-nas` | RK3588 | rockchip-rk3588（vendor 时 `LINUXFAMILY=rk35xx`） | vendor / trixie | FriendlyElec CM3588 NAS，**无头服务端**。描述文件是上游副本（`main @ 19f1b229c686`，见文件头 provenance），本地只追加板级 hook：vendor 串口 `serialcon=ttyFIQ0`、journald 持久化、RTL8125B 网卡自检、风扇落地自检；另带一个 vendor 内核补丁 `userpatches/kernel/rk35xx-vendor-6.1/0001-cm3588-nas-enable-pwm-fan.patch`（FriendlyElec 的 DTS 把 `pwm-fan` 写成 `status = "disabled"`，裸镜像风扇口是死的：打开它，并把 `rockchip,temp-trips` 由 50..70 改 45..65 ℃，对齐社区方案；注意有 `temp-trips` 时档位走内核查表、**不生成** `cooling_device`，要跑社区守护进程就得删掉 `temp-trips`，二选一）。两个 2.5G 口 = **RTL8125B**（PCIe，非 RK3588 自带 GMAC），上游 udev 规则按 PCI 地址命名 `eth0`，`r8125`/`r8169` 通吃。rkmpp 栈在这块板是**硬件转码**用途（ffmpeg `*_rkmpp`），不是桌面播放。`audio-friendly-names` 在无头模式下只装 `audio-switch`：**card0 是 hdmiin 纯采集卡（无 PCM）**，ALSA 默认落到它就没声，装机后 `sudo audio-switch hdmi`（或 `3.5` / `dp` / `hdmi1`）切一次，`audio-switch list` 看候选；出厂不预设默认出口 |
| `rock-5-itx` | RK3588 | rockchip-rk3588（vendor 时 `LINUXFAMILY=rk35xx`） | vendor / trixie | Radxa Rock 5 ITX，xfce + X11 硬解桌面（`build.env` 档位 `mid`；Build-All 批量版仍强制 `minimal`，见「维护约定」）。同样是上游副本 + 同款串口 hook + RTL8852BE 无线自检。无线 = **Radxa A8 模组 / RTL8852BE**：Wi-Fi 走 PCIe（`rtw88_8852be`）、蓝牙走 USB（`rtl_bt` 固件）→ 本板**没有 BT_UART**，不适用 am60/h96s 的 UART 蓝牙路子；`dtb-no-mac` / `ntp-boot-sync` / `bluetooth-autoconnect` 全开 |

每个板卡目录结构（U24 构建机同构）：

```
boards/<board>/
├── build.env              # BOARD/BRANCH/RELEASE/BUILD_DESKTOP/BUILD_MINIMAL/ENABLE_EXTENSIONS 默认值
├── config/boards/*.csc    # 板卡配置（同步到 build/config/boards/）
├── patch/                 # in-tree 内核补丁（仅 aio-3288c rockchip-6.18 需要）
├── userpatches/           # U-Boot / kernel / overlay / extensions / customize-image.sh
└── reference/             # 参考源文件（不参与构建同步）

common/extensions/
├── rkmpp-mpv.sh           # 公共扩展：mpv 那半边 —— 自编译 RKMPP + mpv 硬解 + 全局非 Wayland (X11)
├── chromium-rkmpp.sh      # 公共扩展：网页那半边 —— 出厂即 chromium +rkmpp（PPA + pin1002）
│                          # （两者互不排斥，可同开 = 一块板两件事都要，详见「硬解栈组合」专节）
├── rk35xx-chinese-desktop.sh          # 公共扩展：RK35xx 中文桌面通用设置
│   └── chinese-desktop/               #   （用户/locale/时区/字体/输入法/Chromium/DTB 过滤,
│       └── rk35xx-chinese-desktop.sh  #    ENABLE_EXTENSIONS=rk35xx-chinese-desktop）
├── default-user.sh        # 公共扩展：构建期建默认用户 + 可选 DM 自动登录
│                          # （CI 用 userpatches/.default-user.env 文件传凭据，见下）
├── desktop-dm.sh          # 公共扩展：补 display-manager.service（chroot 里 gdm 缺这个 Alias
│                          #   → 烧卡停在文字控制台，187 实测；幂等，非桌面镜像自动跳过）
├── bluetooth-autoconnect.sh # 开机自动回连 A2DP/HFP 蓝牙音频（BlueZ 默认不主动连，188 板冷启动实测）
├── ntp-boot-sync.sh       # 开机强制 NTP 校时（无 RTC 电池的板子上电时间归零，渐进同步不够）
├── audio-friendly-names.sh # 声卡友好命名：桌面镜像开机生成 udev + WirePlumber 规则（并补装 libcanberra-pulse，否则设置里的扬声器测试静默没声；HDMI-0/HDMI-1/
│                          #   DP/耳机 不再全叫 "Built-in Audio"；udev 的 SOUND_DESCRIPTION 只有
│                          #   PulseAudio 读，PipeWire 必须走 WirePlumber，且 0.4 Lua / 0.5 SPA-JSON
│                          #   两套语法不通用）；无桌面镜像改装 /usr/local/bin/audio-switch 切 ALSA 出口
├── dtb-no-mac/            # 构建时去除 DTB 里写死的 MAC，让厂商内核从 efuse/cpuid 派生每板唯一 MAC
│   └── rk-dtb-no-mac.sh   #   （量产克隆卡同一 MAC 互相冲撞的根因）
└── _archive/
    └── mesa-vpu.sh.obsolete           # 归档：上游 armbian/build 已于 2026-05-09 删除该扩展
                                       # （职责迁至 armbian-configng），本仓不再引用

docs/
└── Debian_X11_RKMPP_MPV_Guide.md   # RKMPP+mpv 完整原理/手册（扩展的上游参考）

scripts/
├── sync-board-to-build.sh          # 只把选中板卡的 config/patch/userpatches + common/extensions 投放进 build 树
└── fetch-prebuilt-rkmpp.sh         # 按【最终 RELEASE】选 rkmpp-stack 预编译 tag 拉到 build 树（四个 workflow 共用）
```

## 在线编译（GitHub Actions）

Actions 页面四个入口：

1. **Build Armbian Image (单板)** — 下拉式参数（参照 ophub/amlogic-s9xxx-armbian 的交互），跑完在 Artifacts 下载 `*.img.xz`（保留 90 天）。
2. **Build All Boards (矩阵)** — 全部已登记板卡并行矩阵构建（名单是 `build-all.yml` 里的 `ALL_LIST`，与 `boards/` 目录一一对应），可用 `boards` 输入筛选（如 `h96s,am60-sa12`）。该输入是自由文本，因此 matrix job 会拆逗号、去空格后**比对板卡白名单**：出现未知板卡名直接失败，不会带着它去拼 `boards/<x>/build.env` 路径。
3. **Build Armbian Image (X11 定制版)** / 4. **(Wayland 定制版)** — 固定策略的开箱即用路线，详见下一节「定制版工作流」。

单板手动触发的参数一览（全部为下拉，选 `default` 即回落该板 `build.env`）：

| 输入 | 取值 | 映射到 armbian |
|---|---|---|
| `board` | 见上文板卡清单 | `BOARD` |
| `edition` | `default` / `desktop` / `server` / `minimal` | `BUILD_DESKTOP` + `BUILD_MINIMAL` |
| `desktop_environment` | `default` / `gnome` / `xfce` / `kde-plasma` / `cinnamon` / `mate` / `lxqt` / `i3-wm` / `budgie` | `DESKTOP_ENVIRONMENT` |
| `desktop_tier` | `default` / `minimal` / `mid` / `full` | `DESKTOP_TIER` |
| `kernel_branch` | `default` / `vendor` / `current` / `edge` / `legacy` | `BRANCH` |
| `kernel_version` | 如 `6.1.172`（留空=跟随分支最新） | `KERNELBRANCH=tag:v<x.y.z>` |
| `release` | `default` / `noble` / `bookworm` / `trixie` / `jammy` / `resolute` / `forky` | `RELEASE` |
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
| Build All Boards (矩阵) | `build-all.yml` | 各板 `build.env`；桌面向一律 `DESKTOP_TIER=minimal`（6h 预算下省装包时间）并自动追加 `desktop-dm` | 批量出图 |
| **Build Armbian Image (X11 定制版)** | `build-x11.yml` | 桌面强制 X11（xfce/cinnamon/mate/lxqt/i3-wm）+ `rkmpp-mpv`（mpv/ffmpeg-rockchip 零拷贝，默认会话模式）+ `chromium-rkmpp` + gdm3 `WaylandEnable=false` | neardi-lz200 / trixie 这类已验证的 X11 硬解板 |
| **Build Armbian Image (Wayland 定制版)** | `build-wayland.yml` | 桌面强制 Wayland（gnome/kde-plasma/budgie）+ `chromium-rkmpp`（rockchip-multimedia PPA + pin1002，出厂即 +rkmpp 版）+ gdm3 `WaylandEnable=true`；**同时启用 `rkmpp-mpv`**，但经 `.rkmpp-mpv.env` 声明 `RKMPP_MPV_SESSION=wayland`，扩展据此不写 `WaylandEnable=false` | h96s / noble 这类 Wayland 板 |

> 🀄 **中文环境默认开启**：两个定制版的 `chinese` 都是 `default: true`，且**对所有发行版生效**
> （jammy/noble 走 `language-pack-*`，trixie/bookworm 走 `locales-all` + 包自带翻译；逐包安装，
> 单包缺失不拖垮整条 apt 事务），并写 AccountsService `Language=zh_CN.UTF-8`
> （GNOME/GDM 只认这个，不认 `/etc/default/locale` —— 187 实测「系统中文、桌面英文」的根因）。
> 要纯英文镜像时把 `chinese` 取消勾选即可。

两者都额外提供**默认用户设置**（由公共扩展 `common/extensions/default-user.sh` 在构建期 chroot 内落盘，不依赖首启 rc.local 时序）：

| 输入 | 默认 | 说明 |
|---|---|---|
| `user_name` | `xiaobao` | 小写字母/数字/`_`/`-`，≤32；留空=不创建默认用户（**只填 `root_password` 时仍会改 root 口令**） |
| `user_password` | `123456` | 仅 `A-Za-z0-9 . _ + # = : @ % -`，4~64 位（含空格/引号的密码会污染 `compile.sh` 参数，CI 直接拒绝） |
| `root_password` | `123456789` | 留空=不改 root 密码；可**单独**填写（用户名留空即「只设 root 口令」） |
| `user_groups` | `sudo,adm,audio,video,plugdev,netdev,render,input,dialout,cdrom` | rootfs 里不存在的组自动跳过 |
| `sudo_nopasswd` | `true` | 写入 `/etc/sudoers.d/90-<user>`（`visudo -cf` 校验失败会自动删除） |
| `desktop_autologin` | `true` | lightdm / gdm3 / sddm 均支持；烧卡开机直接进桌面。⚠️ gdm3 + Wayland 落的是 `TimedLoginEnable/TimedLogin/TimedLoginDelay=0`（不是 `AutomaticLogin*`）：后者下 GDM 会把 tty1 的原 display 改跑 greeter 且永不回收，两个合成器共占 card0 → gnome-shell 刷 `Page flip failed`（207 板 lz120 实锤，见 `default-user.sh` gdm3 分支注释）|

> 👤 **三种组合都有明确语义，没有「填了却没生效」**（2026-11 收口）：
> 两者都留空 → 扩展零副作用，CI 连 `.default-user.env` 都不写（写了也没人读）；
> 只填 `root_password` → 仅 `chpasswd root`，**不建用户、不配自动登录、不清 `/root/.not_logged_in_yet`**
> （首启向导照常跑，因为镜像里确实还没有普通用户）；填了 `user_name` → 完整走建用户 + 组 + sudo + 家目录兜底。
> CI 的 `default-user` 扩展启用门与凭据文件的写入门用的是同一个条件（用户名**或** root 口令非空），
> 不会出现「文件写了但扩展没启用」。
> 注：`Build-All` / `Build-Image` 两个 workflow **没有任何用户凭据输入**，默认用户只在这两个定制版（或本地板卡 config）里生效。

落地痕迹（镜像内，**不含密码**）：`/etc/default-user.conf`（用户/组/免密/自动登录开关）、`/etc/default-user.autologin`（实际 DM 与会话名）、`/etc/desktop-dm.conf`（DM/unit/是否自愈过）。

> 🔐 **凭据怎么进构建（2026-11-02 更正）**：`compile.sh` 以非 root 启动时会
> `exec sudo --preserve-env <白名单> bash compile.sh ...` 重启自己（`lib/functions/cli/utils-cli.sh:355`），
> 白名单只含 `ARMBIAN_ORIGINAL_BUILD_UUID` / `ARMBIAN_HIDE_REPEAT_PARAMS` / `ARMBIAN_CLI_RELAUNCH_ENVS`
> —— **普通环境变量一律被 sudo 丢弃**。所以 CI 里 `env: DEFAULT_USER_NAME=...` 到扩展手上是空的，
> 扩展静默跳过 → 镜像零个普通用户（187 的「不进桌面」缺陷 B）。
> 现改为文件通道：args step 先校验 → 写 `armbian-build/userpatches/.default-user.env`（0600，不进命令行）→
> 扩展 source 一次后立刻删除 → 编译 step 后 `always()` 再兜底清理。密码既不进日志、也不留在构建目录。
> 本地构建仍可直接用环境变量 / 板卡 config，两者兼容。
>
> 由此推出两条纪律（2026-11 收口）：**① 编译 step 的 `env:` 里不再出现任何口令**——env 通道既然被
> sudo 白名单丢弃，留着它只有坏处：`SHARE_LOG=yes` 的构建日志与失败 artifact 不受 GitHub 掩码保护，
> 多一份 env 就多一份明文（非敏感的 `DEFAULT_USER_NAME` / 组 / 自动登录开关仍走 env，扩展另有文件通道）。
> **② 掩码步骤不许静默失效**：`add-mask` 那步若读不到 event JSON 或缺 `jq`，现在会打
> `::warning::` 而不是 `exit 0` 装作做过。扩展侧的输入校验同样补齐了 `DEFAULT_USER_SHELL`
> （它和别的变量一样被单引号拼进 chroot 命令行，一个 `'` 就能逃出引号在 chroot 里以 root 执行命令）。

> 🖥️ **display-manager 自愈（缺陷 A）**：chroot 里装 gdm3 时，`deb-systemd-helper` 只建 `.wants`，
> **不建** `/etc/systemd/system/display-manager.service` 这个 Alias（正常由 `systemctl enable` 在真机上创建）。
> 结果 `graphical.target → Wants=display-manager.service → 缺失`，开机会停在文字控制台；XFCE/lightdm 自带该链接，所以只有 GNOME/gdm 路线暴露。
> `common/extensions/desktop-dm.sh` 在定制链最后补这一环（`systemctl --root` 优先、手工链接兜底、幂等）。
> 两个定制版 workflow 显式启用；**Build All Boards (矩阵) 只要 `BUILD_DESKTOP=yes` 就自动追加它**——
> 同一块板卡换个 workflow 出图，不该在「能不能进桌面」上表现不一致（扩展幂等，lightdm 路线零副作用）。

> ⚠️ **Wayland 定制版的硬解前提**：`chromium-rkmpp` 用的 PPA 只发布 `jammy` / `noble`。选 `trixie` / `bookworm` 时该扩展会自动跳过（镜像无网页硬解），预检步骤默认**直接拦下**；确实只要桌面不要硬解时才勾 `allow_no_hwdec`（默认已开）。

> 📦 **预编译 rkmpp-stack deb**：由 `scripts/fetch-prebuilt-rkmpp.sh <RELEASE>` 统一拉取，
> **四个 workflow 都在 args 步骤解析出最终 `RELEASE` 之后调用**（原先无条件先下 noble 包的写法等于没下：
> 扩展读包内 `/usr/local/share/rkmpp-stack/build-info` 的 `DISTRO_CODENAME` 与本次 `RELEASE` 比对，
> 发行版或架构不匹配就把包丢弃、回退 chroot 源码编译，6h 超时风险原封不动回来）。
> 现有 tag 只有两条有效链：`noble → rkmpp-stack-v0.41.0-noble-arm64`、
> `trixie → rkmpp-stack-v0.41.0-2`（`-1` 从未发布，列出仅为兼容）；`bookworm` / `jammy` / `resolute` / `forky`
> 没有预编译包 → 脚本直接 notice 返回 0，扩展走源码编译。脚本**任何失败都只告警、不返回非零**，
> 构建不会在下载环节中断。


## 硬解栈组合：rkmpp-mpv + chromium-rkmpp（互不排斥）

两块扩展解决两件不同的事，**可以同时启用，也可以单独启用**：

| 扩展 | 负责 | 生效条件 | 不生效时 |
|---|---|---|---|
| `rkmpp-mpv` | 本地播放：自编译 MPP+RGA+ffmpeg-rockchip+mpv 0.41（drm_prime 零拷贝）+ 会话基线（默认强制 X11）+ CMA 兜底 | vendor 内核 + rk35xx/rk3588 + 非 minimal + **非 jammy**（libplacebo 4.x 编不出 mpv 0.41） | 本地播放走发行版 mpv（软解） |
| `chromium-rkmpp` | 网页视频：PPA 的 chromium `+rkmpp`（noble=132 / jammy=126）+ pin1002 + `libv4l-rkmpp` + `/dev/video-dec0` | vendor 内核 + 桌面镜像 + arm64/armhf + **jammy 或 noble** | 网页视频走 `FFmpegVideoDecoder`（软解） |

**两条硬解链互不干扰**：`chromium-rkmpp` 只碰 apt 源与 chromium，不做整机 `dist-upgrade`，因此不会动 mpv 依赖的 `libplacebo/libass/libdav1d`。曾经存在的「二选一 / 双栈开关」机制已整体废弃 —— 那是为了绕开老 `mesa-vpu` 的整机降级动作。

组合矩阵（`X11 定制版` 与 `Wayland 定制版` **都启用两个扩展**；差别只在 `RKMPP_MPV_SESSION`：Wayland 版经 `userpatches/.rkmpp-mpv.env` 传 `wayland`，扩展因此**不写** `WaylandEnable=false`，同一份带 x11/wayland 双后端的 mpv 二进制在 Wayland 下照常走 rkmpp 硬解）：

| 发行版 | mpv 本地硬解 | 网页硬解 |
|---|---|---|
| `noble` | ✅ rkmpp-mpv | ✅ chromium 132+rkmpp |
| `trixie` | ✅ rkmpp-mpv | ❌ Debian 侧 chromium 无 V4L2 VDA patch（死路） |
| `jammy` | ❌ libplacebo 4.x | ✅ chromium 126+rkmpp |
| `bookworm` | ❌ libplacebo 5.229 | ❌ |
| `resolute` | ⚠️ 在 `SUPPORTED_DISTROS` 里（meson 用系统版），但**没出过预编译包** → chroot 源码编译（6h 预算紧）；libplacebo 够不够 6.338.2 由 `rkmpp-mpv.sh` 构建期实测，不足则跳过并告警 | ❌ PPA 只发 jammy/noble，`chromium-rkmpp` 自动跳过 |
| `forky` | ⚠️ Debian 14（上游 CSC）；**不在** `SUPPORTED_DISTROS` 里 —— 构建脚本只告警并按通用 Debian 路径继续编 mpp+rga+ffmpeg+mpv，未经该发行版实测；同样没有预编译包 | ❌ PPA 无 forky |

> ⚠️ **jammy 的现状**：上游 armbian/build 的 RELEASE 选择器已经不再列 jammy（`main-config.sh` 里也只认 `noble|resolute` 为 Ubuntu），本仓三个 workflow 仍保留这一项，唯一理由是 `chromium-rkmpp` 的 PPA 还发 jammy=126 的 `+rkmpp` chromium。哪天上游彻底不收，这个选项就会在 rootfs 阶段失败，届时摘掉即可。

可覆盖变量：

| 变量 | 作用 |
|---|---|
| `CHROMIUM_RKMPP=no` | 关掉网页硬解扩展（`trixie`/`bookworm` 本来就会自动跳过） |
| `RKMPP_MPV_SKIP_BUILD=yes` | 跳过自编译，只做 CMA/X11 兜底（软解基线排查） |
| `RKMPP_MPV_PREBUILT=no` | 不用预编译 deb，强制源码编译 |

> 📌 **为什么不再用上游的 mesa-vpu**：armbian/build 的 `extensions/mesa-vpu.sh` 已于 **2026-05-09 整文件删除**（commit `27c668343`，理由 "fully covered by armbian-config"），mesa 运行时 / `panthor-gpu` overlay / PPA 基础多媒体包在设计上改由 armbian-configng 的 `module_desktops` 接管。但两点让它不能直接依赖：① 删除提交自己写明 configng **不做**装机期的 `apt-get dist-upgrade --allow-downgrades`，**出厂镜像仍是 `apt.armbian.com` 的软解 chromium**，要等用户首次 `apt upgrade` 才换；② 本仓实测 `./compile.sh build` 里 configng 路径**并未运行**（实证见 `boards/h96s/config/boards/h96-m9.csc` 顶部第 2 条）。所以 `chromium-rkmpp.sh` 自己幂等补装 PPA/pin/`libv4l-rkmpp`/`rockchip-multimedia-config`，只补这个缺口；`panthor-gpu` overlay 默认不加（X11/panfrost 基线已验证，加 overlay 需 panthor-capable mesa，见扩展头注释）。旧的 293 行拷贝已归档到 `common/extensions/_archive/mesa-vpu.sh.obsolete`。

> ⚠️ `userpatches/extensions/*.sh` **不会**被自动加载：必须在 `build.env` / preset / 命令行里用 `ENABLE_EXTENSIONS=<名字>` 显式启用（`chromium-rkmpp`、`rkmpp-mpv` 皆然），且钩子函数必须是 `<hook>__<impl>` 双下划线形式（单写 `function <hook>()` 不会被调用）。`aio-3288c` 的 `wk2xxx-aio3288c` 曾因此完全失效（`CONFIG_SPI_WK2XXX` 从未被置 y → 板上没有任何 `ttyWK*`）。

## 公共扩展：rkmpp-mpv（RKMPP 硬解 + 全局非 Wayland）

所有 **vendor 内核**的 RK3566/RK3568/RK3576/RK3588 板卡默认启用（`ENABLE_EXTENSIONS` 里与 `chromium-rkmpp` 逗号连用；各自按发行版自动判定是否真正执行）。完整原理见 `docs/Debian_X11_RKMPP_MPV_Guide.md`。扩展按场景**自动选路**：

**路径一：jammy（不自编译，网页硬解由 chromium-rkmpp 提供）**

jammy 自带 libplacebo 4.x < 6.338.2，`rkmpp-mpv` 会直接跳过（否则构建脚本会 `exit 1` 中止镜像）。该发行版上：网页硬解走 `chromium-rkmpp`（PPA chromium 126+rkmpp），本地播放只能用发行版 mpv（软解）。PPA 里虽有 `mpv 0.36.0-1+j1`，但本仓**不安装**它（版本过旧、且会牵动 PPA 的 `libavcodec` 版本）—— 要 mpv 硬解请改 `noble` / `trixie`。

**路径二：bookworm / trixie / noble / server（预编译 deb 优先，否则自编译栈）**

`assets/rkmpp-mpv/prebuilt/` 里有与目标 **发行版 + 架构**都同名的 `rkmpp-stack_*.deb` 时直接 `apt install`（秒级，依赖由 deb 自己声明）；缺包、发行版/架构不符、或装完校验不到 `mpv --hwdec` 里的 rkmpp / ffmpeg 的 `*_rkmpp` 解码器 → 自动回落源码编译（CI 的 6 小时预算只装得下前者，板上原生编译一般走后者）。按指南方案 A 在 chroot 内源码编译：

1. **RKMPP 编解码栈**：MPP（jellyfin-mpp）+ RGA（jellyfin-rga）+ ffmpeg-rockchip，库隔离在 `/usr/local/lib/ffmpeg-rkmpp`，不污染系统 ffmpeg；
2. **mpv 本体**：官方主线 `v0.41.0` + 扩展自带 `mpp.patch`（rkmpp 解码后端），装在 `/usr/local/bin/mpv`，
   用 rpath 直链 `/usr/local/lib/ffmpeg-rkmpp` 的 libavcodec（`h264_rkmpp`/`hevc_rkmpp`/`vp9_rkmpp`/`av1_rkmpp`），不靠 `LD_LIBRARY_PATH`。

**两条路径共同落盘**：

3. **全局 `/etc/mpv/mpv.conf`**：`hwdec=rkmpp`（显式锁定——`hwdec=auto` 的探测白名单不含 rkmpp，会把它排在最后且随机序；rkmpp 初始化失败时 mpv 自动回退软解）+ `vo=gpu` + `gpu-api=opengl`（X11 渲染基线，Panfrost 无 Vulkan）+ 4K 性能优化（`profile=fast`）；
4. **全局非 Wayland**：GNOME/gdm3 写 `WaylandEnable=false`，KDE/sddm 写 `DisplayServer=x11`，另加 modesetting `TearFree` 防撕裂（`RKMPP_MPV_SESSION=wayland` 时整步跳过）；
5. **CMA 512M**（4K 流畅前提，重刷后默认为 256M 会卡）：写进 `/boot/armbianEnv.txt` 的**已有** `extraboardargs=` 行 —— 语义与板端 `set-cma.sh` 一致：已含 `cma=512M` 就不动；含 `cma=<其它>M` 就地替换；没有 `cma` 就追加到该行末尾；一行都没有才新写一行。**同时删掉 `extraargs=` 行里 family 模板自带的 `cma=256M`**（同行其它参数原样保留，逐条 `extraargs=` 行都处理）。
   ⚠️ 为什么两条不能并存：`config/bootscripts/boot-rk35xx.cmd` 拼的是 `${extraargs} ${extraboardargs}`，而 Linux 的 `cma=` **取最后一次出现**。cm3588-nas 实测 cmdline 即 `cma=256M cma=512M`、dmesg `Reserved 512 MiB` —— 生效值全靠模板拼接顺序，是巧合不是设计，顺序或模板一变就静默退回 256M。现在 cmdline 只有 `extraboardargs` 这一个来源。
   ⚠️ 旧实现是「全文 `grep cma=`（连注释行、`extraargs=` 里的都算命中）→ 没命中就 `sed -i '1i extraboardargs=cma=512M'` 无条件前插」，而 Armbian 出厂往往已经有一行 `extraboardargs=`（哪怕为空）→ 文件里出现**两个同名键**，boot 脚本按最后一次取值：前插那条要么被吃掉（CMA 根本没生效），要么把原有参数吃掉，两种都静默出错。
6. **不留编译残留**：装完删掉镜像里的 `/root/rkmpp-build`（源码树 + 中间对象，数 GB）、`/root/rkmpp-src`（投喂进去的 tarball / `mpp.patch` / deb 副本）和两个一次性脚本；`RKMPP_MPV_PACK_DEB=yes` 时保留 `/root/debs`（那是要在烧卡后取出的交付物）。删之前先确认 `SDCARD` 是非空绝对路径且 `/root` 存在 —— 变量被置空就会变成删构建机的 `~/`。

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
| root 密码 + 首启建用户 | 构建期 `chpasswd`；用户口令只落散列到 0600 conf，`rc.local`→静态 `armbian-firstboot-user.sh` 消费后删除 | 幂等；首启**不重设口令**（不覆盖 default-user 构建期配好的凭据）；建用户早于显示管理器（`display-manager.service.d` After/Requires） |
| Locale / 时区 / 字体 | `/etc/locale.conf`、`/etc/timezone`、chrony 中国 NTP、Noto/WQY/文泉驿 | zh_CN.UTF-8；`Asia/Shanghai`；Debian 可选 `locales-all` |
| 输入法（雾凇拼音 rime-ice） | **GNOME→ibus-rime**；**X11/XFCE 等→fcitx5-rime** | rime-ice 多镜像回退下载；框架按 `DESKTOP_ENVIRONMENT` 自动选路 |
| Chromium 中文 + DTB 过滤 | `/etc/chromium.d`、policy、Local State；`$SDCARD/boot/dtb` 剪枝 | 只留本板 dtb 与本平台 dtbo。**匹配是确定性的、且只在命中唯一时才删**：先按 `*-<board>.dtb` 精确后缀，多于一个再按 SoC 前缀（`rk35xx` 家族从 BOARD 名反推芯片）收窄，最后才回退子串匹配；**命中 0 个或多个一律一个都不删**并打 warn（剪错 dtb = 开机黑屏/砖，不可逆）。旧写法 `grep -E "${board}"` 把板卡名当正则、`| head -n1` 又让多个候选随机收敛 —— 同一家芯片的多板变体（`rk3588s-rock-5b` vs `rk3588b-rock-5b`）会被误删；`ls … | head -1` 在无匹配时还会撞上全局 `set -o pipefail` 直接把整场构建炸掉。**一块板要出多份 dtb**（如 `neardi-lz120` 的单屏 / 双屏变体，靠 `armbianEnv.txt` 的 `fdtfile` 切换）时，板级 `DTB_KEEP_EXTRA` 列空格分隔的文件名：名单内的既**不参与**唯一性判定（否则命中 2 份 → 走「不删除」分支 → 几百份厂商 dtb 全留在镜像里），也一定不被删。命中仍不唯一时再用 `BOOT_FDT_FILE`（镜像真正启动的那份）收敛 —— 这条兜底只在旧逻辑本会「一个都不删」的场景生效，其它板子的路径一字不变。名单里写了镜像中不存在的名字会打 warn（拼错 = 第二份被当非本板删掉）。 |

**隔离保证**：守卫 `LINUXFAMILY=~^(rk35xx|rockchip-rk3588)$ && BRANCH=vendor` 且非 minimal；只写 `$SDCARD`；板级差异全走各板 `build.env`。

板级可调变量（写进 `boards/<board>/build.env` 或 `.csc`）：

```bash
RK_CN_USER=xiaobao          # 普通用户（默认 xiaobao）
RK_CN_USER_PASS=            # 普通用户密码；留空 = 不设口令（无默认口令兜底）
RK_CN_ROOT_PASS=            # root 密码；留空 = 不设口令（无默认口令兜底）
RK_CN_TZ=Asia/Shanghai      # 时区
RK_CN_IME=auto              # auto|fcitx5|ibus（auto: gnome→ibus，其余→fcitx5）
RK_CN_LOCALES_ALL=1         # Debian 是否装 locales-all（1/0，省约 200MB）
RK_CN_RIME_MIRROR=          # 可选：rime-ice 优先镜像前缀
```

> ⚠️ **口令必须走文件通道，不能只靠环境变量**：`compile.sh` 以非 root 启动时会
> `exec sudo --preserve-env <3 个 ARMBIAN 变量>` 重启自己，普通 env 全被丢弃，所以
> CI step 的 `env: RK_CN_ROOT_PASS=...` 到扩展手里是空的。`build-x11.yml` /
> `build-wayland.yml` 因此在构建前写 `userpatches/.rk-cn-pass.env`（0600，与
> default-user 的 `.default-user.env` 同一个套路），扩展 source 后立即删除；两个
> workflow 还各有 `if: always()` 的清理步骤兜底。口令字符集限
> `A-Za-z0-9 . _ + # = : @ % -`（4~64 位），非法值直接**中止构建**，不静默降级。
> 交付形态：root 口令构建期 `chpasswd`；普通用户口令构建期只留 `openssl passwd -6`
> 的**散列**（写进 0600 的 `/etc/armbian-firstboot-user.conf`，首启建完用户即删），
> 部署的首启脚本本身是纯静态、全局可读的，里面没有任何口令。

启用：`ENABLE_EXTENSIONS=...,rk35xx-chinese-desktop`。当前已接入 `h96s`（GNOME/Wayland→ibus-rime）、`neardi-lz200`（XFCE/X11→fcitx5-rime）、`am60-sa12`（server，仅 locale/字体/用户）与 `neardi-lz120`（`build-wayland.yml` / `build-x11.yml` 追加启用；本板 `build.env` 的无头构建不含它，所以那份的 DTB 过滤与中文设置只作用于桌面镜像）。

> ⚠️ 与 `rkmpp-mpv` 的会话取向关系：`rkmpp-mpv` 在**默认（X11）模式**下会把 GNOME 压成 X11（`WaylandEnable=false`）。
> **Wayland 定制版**同样启用它 —— 但先写 `userpatches/.rkmpp-mpv.env` 传 `RKMPP_MPV_SESSION=wayland`，
> 扩展据此**跳过**整段强制 X11 的逻辑，于是 h96s 仍是真正的 GNOME/Wayland + ibus-rime，同时白拿 rkmpp 本地硬解；
> **X11 定制版**（`build-x11.yml`）不设该变量 → 默认 `x11`，GNOME 被压成 X11（输入法走 ibus，X11 下同样可用），XFCE 走 fcitx5。
> 该文件通道与口令通道同理：`compile.sh` 的 sudo 白名单会丢弃普通 env，纯 env 传这个开关在 CI 里不可靠。

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
  ⚠️ 合法值只有 `minimal|mid|full`，**没有 `base`** —— 矩阵 workflow 历史上写 `base`，三个桌面向板卡全部注定失败/弹框，现已统一为 `minimal`（6h 预算下省装包时间）。
- 桌面可用性受**架构**限制：`gnome` / `kde-plasma` / `kde-neon` / `deepin` 只支持 `arm64`/`amd64`；**armhf 板（如 RK3288 的 aio-3288c）只能选 `xfce` / `cinnamon` / `mate` / `i3-wm` / `enlightenment`**。
- 新板卡 = `boards/<name>/` 建目录（至少 `config/boards/<name>.{csc,conf}` + `build.env`，需要补丁/overlay 再加 `patch/` `userpatches/`；`sync-board-to-build.sh` 对缺失子目录静默跳过），并在**四个** workflow 里登记：`build-image` / `build-x11` / `build-wayland` 的 `board` choice options + `build-all.yml` 的 `ALL_LIST` 白名单（漏后者会被 `::error::未知板卡` 拒进 matrix）。`build.env` 里的 `BOARD=` 必须等于板卡目录名与描述文件名。
- **扩展只有两条启用路径，想让某扩展在「所有入口」生效必须写进 `build.env`**：① `build.env` 的 `ENABLE_EXTENSIONS`（板级，四个 workflow 都认）；② 两个桌面定制 workflow 的 `add_ext`（**只在那两条入口生效**，以 build.env 为基底去重叠加 `rkmpp-mpv` / `chromium-rkmpp` / `desktop-dm` / `bluetooth-autoconnect` / `ntp-boot-sync` / `dtb-no-mac` / `audio-friendly-names`）。`build-image.yml` / `build-all.yml` 只把 build.env 的值**原样透传**、不 add_ext（前者还刻意「未设置则不传」，避免覆盖 csc 里已有的 `ENABLE_EXTENSIONS`）→ 走这两条入口时，没在 build.env 列名的扩展一律不会出现；反过来，桌面 workflow 已 `add_ext` 的扩展在 build.env 里重复列名也无害（去重）。
  rk35xx 新板建议默认列 `audio-friendly-names`：扩展按 `BUILD_DESKTOP` 自动分流（桌面装 boot oneshot，开机按 `ID_PATH` 现场生成 udev + WirePlumber 命名规则；无头只装 `audio-switch` 切 ALSA 默认出口），**一次列名同时覆盖桌面与 server 两种版本**。非 rk35xx 家族（如 RK3288 的 `rockchip`）由扩展自身门控 `LINUXFAMILY =~ ^(rk35xx|rockchip-rk3588)$` 自动跳过，列了也不落地。
- **不要在 `.csc` / family 配置里写 `ENABLE_EXTENSIONS=` 裸赋值**（本仓库唯一这么写过的 `neardi-lz120.csc` 已删除该行）：cmdline 的 `KEY=VALUE` 只在 `early` 阶段应用，板级文件在其后的 `config_source_board_file` 阶段被 source，裸赋值会把整串顶掉；而 `initialize_extension_manager` 只在 `do_main_configuration` 首次调用时读一次 `ENABLE_EXTENSIONS`，之后 `enable_extension()` 撞上「已初始化」直接 `exit 2`，被顶掉的项目毫无补救机会。板级兜底一律写进 `build.env`（四个 workflow 都读、都透传）。`sync-board-to-build.sh` 已加守卫：板级 `config/boards/*.{csc,conf}` 里出现这些键（`ENABLE_EXTENSIONS` + 命令行会传的 12 个键）的行首裸赋值就拒绝同步并 `exit 1`，四条 CI 入口与本机同步都经过它。2026-11-22 的 lz120 X11/Wayland 两次构建就因此只剩 `.csc` 里的 3 项，桌面 workflow 追加的 8 项（`desktop-dm`、`default-user`、`rkmpp-mpv`、`chromium-rkmpp`、`rk35xx-chinese-desktop` 等）全丢 → 镜像没有 `display-manager.service`，首启向导走完重启就停在文字界面。
- **直接沿用上游板卡**（不为 DTS/U-Boot 造本地分叉）时：正文**逐字节照抄**上游，加 15 行 provenance 头（来源 commit + 原路径 + 「导入即分叉」告警 + 可复制的 `diff -u <(curl …)` 上游比对命令 + 本地改动清单），板级定制只**追加**在文件末尾的 `post_family_tweaks__*` 里并逐条登记进清单。从此以后上游对同板的改动不会自动生效，靠那个 diff 命令手动回合。
- 补丁一律放 `userpatches/kernel/<family-branch>/`（新式）或该板 `patch/kernel/archive/<dir>/`（旧式 in-tree，仅 AIO 使用）。
- 板级开机定制写在各自 .csc 的 `post_family_tweaks__*` hook 中（host 上下文、只对本板生效）；**不要**往 `customize-image.sh` 塞板级逻辑 —— 官方对所有板无条件 source 它，会互相污染（除非自行加 `$BOARD` 守卫）。
- **vendor 内核（rk35xx）的调试串口是 `ttyFIQ0`，但镜像默认拿不到它**：`config/bootscripts/boot-rk35xx.cmd` 在 `env import armbianEnv.txt` **之前** 就 `setenv serialcon "ttyS2"`，而 `config/bootenv/rk35xx.txt` 模板里根本没有 `serialcon` 键 —— 上游 family 的 `SERIALCON` 只在 getty 那侧生效，进不了 bootargs。于是 vendor 镜像的 cmdline 永远挂着这块板上不存在的 `console=ttyS2,1500000`。修法：板级 hook 往 `/boot/armbianEnv.txt` **补 `serialcon=ttyFIQ0` 键**（先判存在再写，幂等）。⚠️ 别改用 `extraboardargs` 承载 —— 那是 rkmpp-mpv 扩展写 `cma=512M` 的键，boot 脚本对同名键取最后一次值，两处写等于互相吃参数。
- `build.env` 里的 `DESKTOP_TIER` **只对单版 workflow 生效**：`build-all.yml` 组装参数时不看它，桌面向一律强制 `DESKTOP_TIER=minimal`（6h runner 时限下的省时装包）。所以板卡 `build.env` 写 `mid` 是表达「本机推荐的完整形态」，批量版产物仍比它小 —— 换 workflow 得到不同体积是设计如此，不是配置漂移。
- `.DS_Store` / `._*` / `*.bak*` 不入库。
- **workflow 里 `${{ }}` 一律经 `env:` 落地，不直接写进 `run:`**：`run` 脚本里未加引号的
  `${{ inputs.* }}` / `${{ matrix.* }}` / `${{ github.ref_name }}` 都是**shell 代码**，一个空格或引号
  就能变成命令注入（板卡名、`boards` 输入、`build_ref`、Release Notes 里的参数串都算）。
  四个 workflow 的 run 块现已全部 env 化，唯一保留的内插是
  `${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}`（仓库自身标识，非用户输入）。
- **超时预算**：GitHub job 硬上限 360 分钟。workflow 用 `timeout-minutes: 340`（job）+
  `320`（编译步骤）留出 ~20 分钟给构件检查、产物与日志上传 —— 撞 360 会被杀在上传中途，
  几小时编译的成果直接丢失、Release 只剩半截。
- **手动触发参数里的默认口令是有意保留的便利默认**（`user_password=123456` / `root_password=123456789`，
  板卡出厂即用）。它们只作为 workflow 输入默认值存在，扩展侧**没有任何硬编码兜底**：
  留空即不设口令、不会悄悄落一个弱口令进镜像。自己发布公开镜像前请先改成强口令。

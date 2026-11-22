# Neardi LZ120 (RK3568) 板级配置
# 放置：config/boards/neardi-lz120.csc（由 scripts/sync-board-to-build.sh 同步进构建树）
#
# ── provenance（正文 1-12 行逐字节照抄厂商件，导入即分叉）─────────────────────
#   来源：Neardi LZ120 官方 6.1.115 镜像随附的 userpatches/config/boards/neardi-lz120.csc
#         本地留档 rk3568/lz120/6.1.115内核配置/neardi-lz120.csc（1-12 行完全一致）
#   内核：armbian/linux-rockchip branch:rk-6.1-rkr7.2 → KERNELPATCHDIR=rk35xx-vendor-6.1
#   U-Boot：radxa/u-boot branch:next-dev-v2024.10 → BOOTPATCHDIR=legacy/u-boot-radxa-rk35xx
#   ⚠️ armbian/build 上游**没有**这块板（构建树里 config/boards/neardi-lz120.csc 一直是
#      未跟踪文件），所以没有 upstream commit 可比、也没有可复制的 diff 命令；
#      厂商/上游后续改动只能手工回合。
#   本地追加（都在文件末尾，逐条登记）：
#     1) ENABLE_EXTENSIONS=verify-boot-env,lz120-kernel-config,audio-friendly-names
#        —— verify-boot-env 出厂前校验 armbianEnv.txt 的 rootdev/fdtfile（common/extensions/），
#           lz120-kernel-config 把 LT8912 / panel-simple 两个内核符号置 y（本板 userpatches/extensions/），
#           audio-friendly-names 在无头镜像下只装 audio-switch 手工切 ALSA 出口（音频未实测，
#           该分支不装 boot 服务、不预设默认出口 → 对开机零影响）
#     2) PACKAGE_LIST_ADDITIONAL 追加 i2c-tools / libdrm-tests
#        —— LT8912 HDMI 通路 bring-up 用（i2cdetect 探 0x48/0x49、modetest 点屏）
#
# ── 构建 ────────────────────────────────────────────────────────────────────
#   ./compile.sh BOARD=neardi-lz120 BRANCH=vendor RELEASE=bookworm BUILD_DESKTOP=no
#   本机推荐参数见同目录 build.env。

# Rockchip RK3568 quad core 1-8GB SoC GBe eMMC USB3
BOARD_NAME="neardi lz120"
BOARDFAMILY="rk35xx"
BOARD_MAINTAINER="amazingfate"
BOOTCONFIG="neardi-lz120-rk3568_defconfig"
##BOOTCONFIG="radxa-e25-rk3568_defconfig"
KERNEL_TARGET="vendor"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3568-neardi-lz120-linux.dtb"
BOOT_SCENARIO="spl-blobs"
IMAGE_PARTITION_TABLE="gpt"

# ── 本地追加 1：扩展 ────────────────────────────────────────────────────────
# ⚠️ userpatches/extensions/*.sh 不会被自动加载，必须在这里（或 build.env）列名。
#    build.env 的 ENABLE_EXTENSIONS 会**覆盖**本行，两处必须保持一致。
ENABLE_EXTENSIONS="verify-boot-env,lz120-kernel-config,audio-friendly-names"

# ── 本地追加 2：bring-up 工具包 ─────────────────────────────────────────────
# Bring-up tooling for the LT8912 HDMI_TX1 path: modetest, i2c probing, weston for the second display
PACKAGE_LIST_ADDITIONAL="$PACKAGE_LIST_ADDITIONAL i2c-tools libdrm-tests"

# ── 关于串口：本板**不需要** serialcon=ttyFIQ0 的板级 hook ────────────────────
# 仓库约定里 rk35xx vendor 板普遍要往 armbianEnv.txt 补 serialcon（boot-rk35xx.cmd
# 把 serialcon 写死成 ttyS2，而 vendor 内核根本没有 /dev/ttyS2）。
# LZ120 实测不用补：0001 补丁带的 rk3568-neardi-lz120-linux.dts 里有
#   chosen { bootargs = "earlycon=uart8250,mmio32,0xfe660000 console=ttyFIQ0"; }
# 厂商 U-Boot 会把它并进最终 bootargs，板上 /proc/cmdline 实测为
#   "... splash=verbose console=ttyFIQ0 console=tty1 consoleblank=0 loglevel=7 ..."
# 既没有 ttyS2，earlycon 也在。别再"顺手"加 hook，否则会出现两个 console= 打架。

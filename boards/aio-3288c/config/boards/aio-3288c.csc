# Rockchip RK3288 quad core 2GB RAM SoC 100M eMMC WiFi BT
# Firefly AIO-3288C industrial all-in-one board
# https://www.t-firefly.com/product/industry/aio3288c
BOARD_NAME="AIO-3288C"
BOARD_VENDOR="firefly"
BOARDFAMILY="rockchip"
BOARD_MAINTAINER="xiaobao1980"
BOOTCONFIG="aio-3288c-rk3288_defconfig"
KERNEL_TARGET="current,edge"
KERNEL_TEST_TARGET="current"
FULL_DESKTOP="yes"
BOOT_SOC="rk3288"
BOOT_FDT_FILE="rk3288-aio-3288c.dtb"
SERIALCON="ttyS2"

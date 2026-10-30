#!/usr/bin/env bash
#
# Board-specific kernel config for the Firefly AIO-3288C (aio-3288c).
#
# Enables the on-board WK2124 SPI-to-4xUART bridge driver
# (CONFIG_SPI_WK2XXX) ONLY for this board, so it is kept OUT of the
# global linux-rockchip-current.config and does not affect the compilation
# of other rockchip boards.
#
# =============================================================================
#  ⚠️ 两个必须知道的机制（2026-10-30 修正，之前这份扩展是「哑」的）
# -----------------------------------------------------------------------------
#  1) userpatches/extensions/*.sh **不会**被自动加载。Armbian 官方文档明确：
#     "An user of the build system can enable that extension by adding a call to
#      enable_extension \"be-festive\" on his configuration file, or by passing
#      ENABLE_EXTENSIONS=be-festive as a parameter to the build."
#     → 必须在 boards/aio-3288c/build.env 里写 ENABLE_EXTENSIONS=wk2xxx-aio3288c，
#       否则本文件永远不会被 source。
#
#  2) 钩子实现必须用双下划线形式 `<hook>__<impl>`。框架是按名字「组合」出
#     custom_kernel_config() 再调用的；直接定义 function custom_kernel_config()
#     不会被调用（docs: "An extension method implementation is just a Bash function
#     that follows the pattern run_after_build__say_congratulations"）。
#     → 本文件用 custom_kernel_config__wk2xxx_aio3288c()。
#
#  hook 时机：${LINUXCONFIG}.config 已放进 .config、Armbian 默认 Kconfig 改动已
#  应用、olddefconfig 之前。SPI_WK2XXX 是 tristate 且**没有 default**，
#  所以不显式置 y 就不会编进来（WK2124 的 4 路串口 / RS485 全废）。
#  该符号只在应用了 add-wk2xxx-driver.patch（板级）后才存在，因此对其它板天然无副作用。
# =============================================================================

function custom_kernel_config__wk2xxx_aio3288c() {
	# Only act for the AIO-3288C board.
	[[ "${BOARD}" == "aio-3288c" ]] || return 0
	# The hook may be called before .config is in place; guard.
	[[ -f .config ]] || return 0
	# Enable the driver built-in so it probes at boot (SPI-DT auto-load is unreliable).
	kernel_config_set_y CONFIG_SPI_WK2XXX
	# The driver's GPIO control for reset/power/chip-select/RS485 is gated
	# behind these Kconfig bools. Their Kconfig "default y" only takes effect
	# when olddefconfig runs AFTER SPI_WK2XXX is set, which is not guaranteed
	# in this build flow. If they stay off, the CS#/reset/power code is
	# compiled out -> WK2124 is never selected -> GENA reads 0 -> probe fails.
	# Force them on explicitly so the driver actually drives the pins.
	kernel_config_set_y CONFIG_SPI_WK2XXX_GPIO_RST
	kernel_config_set_y CONFIG_SPI_WK2XXX_GPIO_PWR
	kernel_config_set_y CONFIG_SPI_WK2XXX_GPIO_CS
	kernel_config_set_y CONFIG_SPI_WK2XXX_GPIO_RS485

	# 参与「内核配置哈希」：这些值变化时强制重建内核，避免命中旧缓存拿到
	# 一个没有 WK2XXX 驱动的内核（表现为板上 ttyWK* 一个都不出现）。
	# Armbian 文档要求 custom_kernel_config 钩子必须做这件事。
	kernel_config_modifying_hashes+=(
		"CONFIG_SPI_WK2XXX=y"
		"CONFIG_SPI_WK2XXX_GPIO_RST=y"
		"CONFIG_SPI_WK2XXX_GPIO_PWR=y"
		"CONFIG_SPI_WK2XXX_GPIO_CS=y"
		"CONFIG_SPI_WK2XXX_GPIO_RS485=y"
	)

	return 0
}

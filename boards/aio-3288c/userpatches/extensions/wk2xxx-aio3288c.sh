#!/usr/bin/env bash
#
# Board-specific kernel config for the Firefly AIO-3288C (aio-3288c).
#
# Enables the on-board WK2124 SPI-to-4xUART bridge driver
# (CONFIG_SPI_WK2XXX) ONLY for this board, so it is kept OUT of the
# global linux-rockchip-current.config and does not affect the compilation
# of other rockchip boards.
#
# This extension is auto-loaded from userpatches/extensions/ by the Armbian
# build framework. custom_kernel_config() is invoked after the user .config
# is put in place (kernel work dir), before olddefconfig.
#
# The SPI_WK2XXX Kconfig symbol only exists when add-wk2xxx-driver.patch is
# applied (board-specific), so this is a safe no-op for any board without it.

function custom_kernel_config() {
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
}

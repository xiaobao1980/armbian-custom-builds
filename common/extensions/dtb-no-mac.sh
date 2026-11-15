#
# SPDX-License-Identifier: GPL-2.0
# Armbian build framework extension
#
# dtb-no-mac: 构建时去除内核 DTB 里「写死」的 MAC 地址属性
#   （local-mac-address / mac-address），让 RK 厂商内核的 GMAC 驱动走默认机制：
#     1) 优先从芯片 efuse / cpuid 派生每板唯一 MAC；
#     2) 派生失败则随机生成本地 MAC（locally-administered）。
#   避免同型号板卡共用一个写死 MAC（克隆镜像 / 批量部署时最容易踩坑：
#   所有机器 MAC 冲突、DHCP 拿不到地址、交换机风暴）。
#
# 适用范围（与 rk35xx-chinese-desktop 一致的守卫，避免误伤其它板卡）：
#   LINUXFAMILY=rk35xx|rockchip-rk3588 且 BRANCH=vendor；
#   其余板卡 / 内核 / 最小镜像在 prepare 阶段直接跳过（零副作用）。
#
# 无副作用：DTB 中本就没有 MAC 属性时完全不改动（仅记录「扫描 N 个、去除 0 个」）。
# 可用板级变量 RK_DTB_KEEP_MAC=yes 关闭本扩展（极个别需要固定 MAC 的授权场景）。
#
# 实现：在 chroot 内用 device-tree-compiler (dtc) 反编译 → 删属性行 → 重编译，
# 覆盖写回原文件（保留权限 / 符号链接指向的实体文件）。
# 若 chroot 内无 dtc 且无法 apt 安装，则仅告警并跳过，绝不中断构建。
# =============================================================================

# 守卫：只放行 RK35xx/RK3588 厂商内核 + 非最小镜像
_dtbnm_should_run() {
	[[ "${LINUXFAMILY}" =~ ^(rk35xx|rockchip-rk3588)$ && "${BRANCH}" == "vendor" ]] || return 1
	[[ "${BUILD_MINIMAL:-no}" == "yes" ]] && return 1
	[[ "${RK_DTB_KEEP_MAC:-no}" == "yes" ]] && return 1
	return 0
}

function extension_prepare_config__dtb_no_mac() {
	if ! _dtbnm_should_run; then
		display_alert "Extension: ${EXTENSION}" "needs rk35xx/rk3588 vendor kernel & non-minimal; skipping" "warn"
		return 0
	fi
	display_alert "Extension: ${EXTENSION}" "will strip hardcoded MAC (local-mac-address/mac-address) from DTBs" "info"
	return 0
}

function post_install_kernel_debs__dtb_no_mac() {
	_dtbnm_should_run || return 0

	local SCRIPT_DIR ASSET
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	ASSET="${SCRIPT_DIR}/dtb-no-mac/rk-dtb-no-mac.sh"
	if [[ ! -f "${ASSET}" ]]; then
		display_alert "dtb-no-mac asset missing at ${ASSET}" "${EXTENSION}" "err"
		return 0
	fi

	# ---- 暂存 chroot 执行器（用完即删，不残留进镜像） ----
	display_alert "Staging dtb-no-mac executor into chroot" "${EXTENSION}" "info"
	mkdir -p "${SDCARD}/usr/local/sbin"
	cp "${ASSET}" "${SDCARD}/usr/local/sbin/rk-dtb-no-mac.sh"
	chmod +x "${SDCARD}/usr/local/sbin/rk-dtb-no-mac.sh"

	chroot_sdcard "bash /usr/local/sbin/rk-dtb-no-mac.sh" \
		|| display_alert "dtb-no-mac returned non-zero (image MAC may remain hardcoded)" "${EXTENSION}" "warn"

	# 执行器一次性使用，删除避免残留
	rm -f "${SDCARD}/usr/local/sbin/rk-dtb-no-mac.sh"

	display_alert "dtb-no-mac complete" "${EXTENSION}" "info"
	return 0
}

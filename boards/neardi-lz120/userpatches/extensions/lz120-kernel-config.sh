#!/usr/bin/env bash
#
# Neardi LZ120 (neardi-lz120) 板级内核 config。
#
# 只为本板打开两个符号，**不改**全局 config/kernel/linux-rk35xx-vendor.config，
# 因此对同 LINUXFAMILY 的其它板（h96s / cm3588-nas / rock-5-itx / am60-sa12）零影响。
#
# =============================================================================
#  两个必须知道的机制（同 boards/aio-3288c/userpatches/extensions/wk2xxx-aio3288c.sh）
# -----------------------------------------------------------------------------
#  1) userpatches/extensions/*.sh **不会**被自动加载：必须在 build.env / .csc 里
#     写 ENABLE_EXTENSIONS=lz120-kernel-config，否则本文件永远不会被 source。
#     （build.env 的值会覆盖 .csc，两处都要列名。）
#
#  2) 钩子实现必须用双下划线形式 `<hook>__<impl>`：本文件用
#     custom_kernel_config__lz120_lt8912()。框架在
#     lib/functions/compilation/kernel-config.sh:119 通过
#     call_extension_method "custom_kernel_config" 组合调用；直接定义
#     function custom_kernel_config() 不会被调用。
#
#  hook 时机：${LINUXCONFIG}.config 已放进 .config、Armbian 默认改动已应用、
#  olddefconfig 之前（kernel-config.sh:77-80，此时 cwd = kernel_work_dir）。
#  内核 artifact 的 prepare_version 也会调同一个钩子
#  （lib/functions/artifacts/artifact-kernel.sh:131），所以缓存哈希一致。
#
#  kernel_config_set_y 内部已自动把 "<CONFIG>=y" 追加进
#  kernel_config_modifying_hashes（lib/functions/compilation/armbian-kernel.sh:734-739），
#  这两个值变化时会强制重建内核 —— 不会命中旧缓存拿到一个没有 LT8912 的内核。
# =============================================================================

function custom_kernel_config__lz120_lt8912() {
	# 只对本板生效。⚠️ 不能按 LINUXFAMILY 守卫 —— rk35xx 被多块板共用。
	[[ "${BOARD}" == "neardi-lz120" ]] || return 0
	# 钩子可能在 .config 落地前被调用，先兜一层。
	[[ -f .config ]] || return 0

	# 0002-lz120-lt8912-driver.patch 新增的 DSI→HDMI 桥驱动。
	# drivers/gpu/drm/bridge/Kconfig 里是 `bool` 且**没有 default**，
	# 不显式置 y 就永远编不进来 → 现象是 DSI 侧一切正常、HDMI 口全黑。
	kernel_config_set_y CONFIG_DRM_LONTIUM_LT8912

	# panel-simple 上游是 =m。LT8912 的视频模式取自 DSI panel 节点，
	# 面板驱动做成模块时探测会晚于 DRM 初始化 → 首屏黑屏/花屏。改成内建。
	kernel_config_set_y CONFIG_DRM_PANEL_SIMPLE

	return 0
}

# =============================================================================
# 本仓副本 —— 导入自上游 armbian/build；正文默认与上游一致，本地新增段落逐条记在下方清单
#   来源: armbian/build  main @ 19f1b229c686 (2026-11-22)
#   原路径: config/boards/cm3588-nas.csc
#
# ⚠️ 导入即分叉：scripts/sync-board-to-build.sh 会把本文件 cp 进构建树的
#    config/boards/cm3588-nas.csc 并**覆盖**上游同名文件，所以自导入之日起上游对这块板的
#    后续改动不会自动生效，需要手动 diff 后回合：
#      diff -u <(curl -fsSL https://raw.githubusercontent.com/armbian/build/main/config/boards/cm3588-nas.csc) \
#              boards/cm3588-nas/config/boards/cm3588-nas.csc
#
# 本地改动清单（改一条记一条，别只靠 git blame）:
#   (1) 仅加本注释头，正文与上游一致
#   (2) 文件末尾新增本仓板级 hook：post_family_tweaks__cm3588_nas_serial_console（vendor 串口补 serialcon=ttyFIQ0） + cm3588_nas_journal_storage（journald 持久化）
#   (3) post_family_tweaks__cm3588_nas_rtl8125_check：RTL8125B 网卡驱动（r8125/r8169）与 rtl_nic 固件构建期自检，只写日志不改镜像
#   (4) userpatches/kernel/rk35xx-vendor-6.1/0001-cm3588-nas-enable-pwm-fan.patch：vendor DTS 打开 pwm-fan（status disabled→okay），触发档 50..70 改 45..65 ℃
#   (5) post_family_tweaks__cm3588_nas_fan_check：反编译镜像里的本板 DTB，核对风扇 status 与触发档是否真的落地，只写日志不改镜像
# =============================================================================

# Rockchip RK3588 octa core 16GB RAM SoC eMMC 4x NVMe 2x USB3 USB2 USB-C 2.5GbE
BOARD_NAME="CM3588 NAS"
BOARD_VENDOR="friendlyelec"
BOARDFAMILY="rockchip-rk3588"
BOARD_MAINTAINER=""
INTRODUCED="2023"
BOOTCONFIG="cm3588-nas-rk3588_defconfig" # Mainline defconfig, enables booting from NVMe
KERNEL_TARGET="current,edge,vendor"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
IMAGE_PARTITION_TABLE="gpt"
BOOT_FDT_FILE="rockchip/rk3588-friendlyelec-cm3588-nas.dtb"
BOOT_SCENARIO="tpl-blob-atf-mainline"
UEFI_EDK2_BOARD_ID="nanopc-cm3588-nas" # This _only_ used for uefi-edk2-rk3588 extension; cm3588-nas was introduced in v0.12 of edk2-porting/edk2-rk3588

enable_extension "uboot-mainline-mmc-env-storage" # store u-boot env in mmc (boot0/boot1)

# @TODO: revisit this as it's probably just for vendor kernel
function post_family_tweaks__cm3588_nas_udev_naming_audios() {
	display_alert "$BOARD" "Renaming CM3588 audio interfaces to human-readable form" "info"

	mkdir -p $SDCARD/etc/udev/rules.d/

	cat <<- EOF > "${SDCARD}/etc/udev/rules.d/90-naming-audios.rules"
		SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-hdmi0-sound", ENV{SOUND_DESCRIPTION}="HDMI-0 Audio Out"
		SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-hdmi1-sound", ENV{SOUND_DESCRIPTION}="HDMI-1 Audio Out"
		SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-dp0-sound", ENV{SOUND_DESCRIPTION}="DisplayPort-Over-USB Audio Out"
		SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-rt5616-sound", ENV{SOUND_DESCRIPTION}="Headphone Out/Mic In"
		SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-hdmiin-sound", ENV{SOUND_DESCRIPTION}="HDMI-IN Audio In"
	EOF
}

# Output from CM3588 syslog with edge kernel 6.8: r8169 0004:41:00.0 enP4p65s0: renamed from eth0
# Note: legacy kernel 5.10 uses driver r8125, edge kernel uses r8169 as of 6.8
# TODO: only needed on BRANCH==vendor since mainline kernel patch for u-boot driven MAC stability also brings eth0/end0
function post_family_tweaks__cm3588_nas_udev_naming_network_interfaces() {
	display_alert "$BOARD" "Renaming CM3588 LAN interface to eth0" "info"

	mkdir -p $SDCARD/etc/udev/rules.d/
	cat <<- EOF > "${SDCARD}/etc/udev/rules.d/70-persistent-net.rules"
		SUBSYSTEM=="net", ACTION=="add", KERNELS=="0004:41:00.0", NAME:="eth0"
	EOF
}

# Mainline U-Boot
function post_family_config__cm3588_nas_use_mainline_uboot() {
	display_alert "${BOARD}/${BRANCH}" "Using mainline U-Boot for ${BOARD}/${BRANCH}" "info"

	# If BRANCH==vendor, use rkbin BL31 ${RKBIN_DIR}/${BL31_BLOB}, otherwise, bl31.elf from mainline ATF/TF-A
	declare bl31_blob="undetermined"
	if [[ "${BRANCH}" == vendor* ]]; then
		display_alert "${BOARD}/${BRANCH}" "Using Rockchip rkbin BL31 blob : ${RKBIN_DIR}/${BL31_BLOB}" "info"
		bl31_blob="${RKBIN_DIR}/${BL31_BLOB}"
		declare -g ATF_COMPILE="no" # no need to build mainline it either
	else
		display_alert "${BOARD}/${BRANCH}" "Using mainline BL31: bl31.elf from mainline ATF/TF-A" "info"
		bl31_blob="bl31.elf"
	fi

	declare -g BOOTDELAY=1
	declare -g BOOTSOURCE="https://github.com/u-boot/u-boot.git"
	declare -g BOOTBRANCH="tag:v2026.10"
	declare -g BOOTPATCHDIR="v2026.10"
	declare -g BOOTDIR="u-boot-${BOARD}"
	declare -g UBOOT_TARGET_MAP="BL31=${bl31_blob} ROCKCHIP_TPL=${RKBIN_DIR}/${DDR_BLOB};;u-boot-rockchip.bin"
	unset uboot_custom_postprocess write_uboot_platform write_uboot_platform_mtd # Disable stuff from rockchip64_common; we're using binman here which does all the work

	# Just use the binman-provided u-boot-rockchip.bin, which is ready-to-go
	function write_uboot_platform() {
		dd "if=$1/u-boot-rockchip.bin" "of=$2" bs=32k seek=1 conv=notrunc status=none
	}
}

function pre_config_uboot_target__cm3588_patch_uboot_dtsi_for_ums() {
	display_alert "u-boot for ${BOARD}" "u-boot: add to u-boot dtsi for UMS" "info" # avoid a patch, just append to the dtsi file
	cat <<- UBOOT_BOARD_DTSI_OTG >> arch/arm/dts/rk3588-friendlyelec-cm3588-nas-u-boot.dtsi
		&u2phy0 { status = "okay"; };
		&u2phy0_otg { status = "okay"; };
		&usbdp_phy0 { status = "okay"; };
		&usb_host0_xhci { dr_mode = "peripheral";  maximum-speed = "high-speed";  status = "okay"; };
	UBOOT_BOARD_DTSI_OTG
}

# "rockchip-common: boot SD card first, then NVMe, then mmc"
# include/configs/rockchip-common.h
# -#define BOOT_TARGETS "mmc1 mmc0 nvme scsi usb pxe dhcp spi"
# +#define BOOT_TARGETS "mmc0 nvme mmc1 scsi usb pxe dhcp spi"
# On cm3588-nas, mmc0 is the eMMC, mmc1 is the SD card slot
function pre_config_uboot_target__cm3588_patch_rockchip_common_boot_order() {
	declare -a rockchip_uboot_targets=("mmc1" "nvme" "mmc0" "scsi" "usb" "pxe" "dhcp" "spi") # for future make-this-generic delight
	display_alert "u-boot for ${BOARD}/${BRANCH}" "u-boot: adjust boot order to '${rockchip_uboot_targets[*]}'" "info"
	sed -i -e "s/#define BOOT_TARGETS.*/#define BOOT_TARGETS \"${rockchip_uboot_targets[*]}\"/" include/configs/rockchip-common.h
	regular_git diff -u include/configs/rockchip-common.h || true
}

function post_config_uboot_target__extra_configs_for_cm3588-nas_uboot() {
	display_alert "u-boot for ${BOARD}/${BRANCH}" "u-boot: enable preboot & flash user LED in preboot" "info"
	run_host_command_logged scripts/config --enable CONFIG_USE_PREBOOT
	run_host_command_logged scripts/config --set-str CONFIG_PREBOOT "'led green:indicator on; sleep 0.1; led amber:heartbeat on; sleep 0.1; led green:indicator off; led amber:heartbeat off'" # double quotes required due to run_host_command_logged's quirks

	display_alert "u-boot for ${BOARD}/${BRANCH}" "u-boot: enable EFI debugging commands" "info"
	run_host_command_logged scripts/config --enable CMD_EFIDEBUG
	run_host_command_logged scripts/config --enable CMD_NVEDIT_EFI

	display_alert "u-boot for ${BOARD}/${BRANCH}" "u-boot: enable more filesystems support" "info"
	run_host_command_logged scripts/config --enable CONFIG_CMD_BTRFS

	display_alert "u-boot for ${BOARD}/${BRANCH}" "u-boot: enable more compression support" "info"
	run_host_command_logged scripts/config --enable CONFIG_LZO
	run_host_command_logged scripts/config --enable CONFIG_BZIP2
	run_host_command_logged scripts/config --enable CONFIG_ZSTD

	display_alert "u-boot for ${BOARD}/${BRANCH}" "u-boot: enable gpio LED support" "info"
	run_host_command_logged scripts/config --enable CONFIG_LED
	run_host_command_logged scripts/config --enable CONFIG_LED_GPIO

	display_alert "u-boot for ${BOARD}/${BRANCH}" "u-boot: enable networking cmds" "info"
	run_host_command_logged scripts/config --enable CONFIG_CMD_NFS
	run_host_command_logged scripts/config --enable CONFIG_CMD_WGET
	run_host_command_logged scripts/config --enable CONFIG_CMD_DNS
	run_host_command_logged scripts/config --enable CONFIG_PROT_TCP
	run_host_command_logged scripts/config --enable CONFIG_PROT_TCP_SACK

	display_alert "u-boot for ${BOARD}/${BRANCH}" "u-boot: enable LWIP (new networking stack)" "info"
	run_host_command_logged scripts/config --enable CONFIG_CMD_MII
	run_host_command_logged scripts/config --enable CONFIG_NET_LWIP

	display_alert "u-boot for ${BOARD}/${BRANCH}" "u-boot: enable MBed TLS stuff" "info"
	run_host_command_logged scripts/config --enable CONFIG_WGET_HTTPS
	run_host_command_logged scripts/config --enable CONFIG_WGET_CACERT
	#run_host_command_logged scripts/config --enable CONFIG_WGET_BUILTIN_CACERT # not yet
	run_host_command_logged scripts/config --enable CONFIG_MBEDTLS_LIB

	# UMS, RockUSB, gadget stuff
	display_alert "u-boot for ${BOARD}/${BRANCH}" "u-boot: enable UMS/RockUSB gadget" "info"
	declare -a enable_configs=("CONFIG_CMD_USB_MASS_STORAGE" "CONFIG_USB_GADGET" "USB_GADGET_DOWNLOAD" "CONFIG_USB_FUNCTION_ROCKUSB" "CONFIG_USB_FUNCTION_ACM" "CONFIG_CMD_ROCKUSB")
	for config in "${enable_configs[@]}"; do
		run_host_command_logged scripts/config --enable "${config}"
	done
	# Auto-enabled by the above, force off...
	run_host_command_logged scripts/config --disable USB_FUNCTION_FASTBOOT

	return 0
}

# =============================================================================
# ↓↓ 本仓板级开机定制（上游没有这段；已在文件头「本地改动清单」登记）↓↓
# =============================================================================

# vendor 内核的调试串口是 fiq_debugger 的 ttyFIQ0，但 config/bootscripts/boot-rk35xx.cmd
# 在 `env import armbianEnv.txt` **之前** 就 setenv serialcon "ttyS2"，而
# config/bootenv/rk35xx.txt 模板里根本没有 serialcon 键（只有 console=both / extraargs=cma=256M）。
# 净结果：bootargs 里永远是这块板上不存在的 console=ttyS2,1500000 —— 串口拿不到任何输出。
# 上游 family 的 post_family_config__900_late_default_serial_console_by_branch 虽然把
# SERIALCON 设成 ttyFIQ0，但那个变量进不了 armbianEnv.txt（模板没这个键），只在 getty 那侧生效。
# 这里直接把键补进镜像的 armbianEnv.txt。
#
# ⚠️ 只写 serialcon，绝不写 extraboardargs：那是 rkmpp-mpv 扩展写 cma=512M 的键。
#    boot 脚本对同名键按最后一次取值，两处写等于互相吃参数（本仓在 CMA 上踩过一次）。
function post_family_tweaks__cm3588_nas_serial_console() {
	[[ "${BRANCH}" == vendor* ]] || return 0
	local env_file="${SDCARD}/boot/armbianEnv.txt"
	if [[ ! -f "${env_file}" ]]; then
		display_alert "$BOARD" "armbianEnv.txt 尚未生成，跳过 serialcon 设置（开机后手动确认串口参数）" "warn"
		return 0
	fi
	if grep -qE '^serialcon=' "${env_file}"; then
		display_alert "$BOARD" "armbianEnv.txt 已有 serialcon 键，保持不动" "info"
		return 0
	fi
	printf 'serialcon=ttyFIQ0\n' >> "${env_file}"
	display_alert "$BOARD" "vendor 串口: serialcon=ttyFIQ0 已写入 /boot/armbianEnv.txt" "info"
}

# 无人值守设备：journald 默认 volatile（日志在 /run/log/journal），一断电上一次崩溃的原因
# 就查不到。开持久化并给占用封顶，别让日志写满系统分区。
function post_family_tweaks__cm3588_nas_journal_storage() {
	mkdir -p "${SDCARD}/etc/systemd/journald.conf.d"
	cat > "${SDCARD}/etc/systemd/journald.conf.d/50-cm3588-nas-journal.conf" <<- EOF
		[Journal]
		Storage=persistent
		SystemMaxUse=200M
		SystemMaxFileSize=20M
	EOF
	display_alert "$BOARD" "journald 持久化已开启（上限 200M）" "info"
}

# =============================================================================
# ↓↓ 2.5GbE 自检（本仓新增；硬件事实：两个 2.5G 口 = Realtek RTL8125B，走 PCIe）↓↓
#
# 认识 RTL8125 的驱动有两家，vendor/current/edge 上不一定同一家的：
#   · r8125 —— Realtek 外置驱动，Rockchip vendor BSP 一般带这个；
#   · r8169 —— 内核树内驱动，较新内核才补进 8125 支持（上游正文注释：edge 6.8 用 r8169）。
# 上游正文里的 udev 规则按 PCI 地址 0004:41:00.0 命名 eth0，两家驱动都吃，**不用动**。
#
# 本 hook 只报告 vendor 内核实际带的是哪一家，以及 rtl_nic 的 PHY 配置固件在不在
# （缺配置固件只是拿不到厂商 PHY 调优，链路照样起，所以 warn 不致命）。
# 时序（上游 lib/functions/main/rootfs-image.sh）：内核与 armbian-firmware 都装在这
# 个 customize_image 阶段之前，所以看到的就是镜像最终态。真报缺固件时，正解是本板
# build.env 加 `BOARD_FIRMWARE_INSTALL="-full"`（见 distro-agnostic.sh:443-450）。
# 实现约束同 rock-5-itx：不用 `find | head` / `find | grep -q`，避免 pipefail 把命中判成失败。

function post_family_tweaks__cm3588_nas_rtl8125_check() {
	[[ "${BRANCH}" == vendor* ]] || return 0

	local kroot="${SDCARD}/usr/lib/modules"
	if [[ ! -d "${kroot}" ]]; then
		display_alert "$BOARD" "RTL8125B 自检跳过：镜像里没有内核模块树（${kroot}）" "warn"
		return 0
	fi

	local ko hit rel drv_found=no
	for ko in r8125 r8169; do
		hit="$(find "${kroot}" -name "${ko}.ko*" 2>/dev/null || true)"
		if [[ -n "${hit}" ]]; then
			rel="${hit#"$kroot"/}"
			rel="${rel%%$'\n'*}"
			display_alert "$BOARD" "RTL8125B 驱动: 镜像里有 ${ko}.ko -> ${rel}" "info"
			drv_found=yes
		fi
	done
	[[ "${drv_found}" == "yes" ]] || \
		display_alert "$BOARD" "RTL8125B 驱动: 内核树里既无 r8125 也无 r8169 —— 两个 2.5G 口没有驱动，需确认内核配置或补外置 r8125" "warn"

	hit="$(find "${SDCARD}/lib/firmware/rtl_nic" -name 'rtl8125*' 2>/dev/null || true)"
	if [[ -n "${hit}" ]]; then
		rel="${hit#"$SDCARD"}"
		rel="${rel%%$'\n'*}"
		display_alert "$BOARD" "RTL8125B PHY 固件: ${rel}" "info"
	else
		display_alert "$BOARD" "RTL8125B PHY 固件: /lib/firmware/rtl_nic/rtl8125* 不在镜像里（链路仍能起，只是没有厂商 PHY 调优）" "warn"
	fi

	return 0
}

# =============================================================================
# ↓↓ 风扇自检（本仓新增；配套 userpatches/kernel/rk35xx-vendor-6.1/0001-… 补丁）↓↓
# =============================================================================

# -----------------------------------------------------------------------------
# 风扇自检 —— 核对 0001 风扇补丁有没有真的落到镜像 DTB 里（只写日志，不改镜像）
#
# FriendlyElec 的 rk3588-friendlyelec-cm3588-nas.dts 把 fan: pwm-fan 节点写成
# status = "disabled"，裸 vendor 镜像里 NAS 风扇口是死的（4 盘位封闭机箱，无强制风道）。
# 本仓 userpatches/kernel/rk35xx-vendor-6.1/0001-cm3588-nas-enable-pwm-fan.patch
# 把它打开，并把 rockchip,temp-trips 从 50/55/60/65/70 改成 45/50/55/60/65 ℃
# —— 45..65 这个窗口就是 martabal/cm3588-fan 和 vijaygill/pwm-fan-cm3588
#    两个社区方案共同的 MIN/MAX 阈值。
#
# vendor 内核（rk-6.1-rkr7.2，drivers/hwmon/pwm-fan.c）的语义，排查时要知道：
#   · 有 rockchip,temp-trips 时，档位由**内核里查表**决定（驱动挂 rockchip_system_monitor
#     通知链，CONFIG_ROCKCHIP_SYSTEM_MONITOR=y，rk3588s.dtsi 里 thermal-zone = "soc-thermal"），
#     不需要任何守护进程。代价是驱动 return 在 devm_thermal_of_cooling_device_register()
#     之前，**不会**生成 /sys/class/thermal/cooling_deviceN —— 而上面两个社区守护进程写的
#     正是 cooling_device。要改用守护进程就得先删掉 rockchip,temp-trips，二选一。
#   · rockchip,hold-time-ms 这个内核根本没人读；实际去抖是 system_monitor 的
#     2 ℃ 下降沿门限 + rockchip,polling-delay（默认 200 ms 轮询）。
#   · 占空比 = cooling-levels/255：vendor 的 0 35 64 100 150 255 ≈ 0/13.7/25/39/59/100%。
#     最低档要是不转，正解是抬 cooling-levels[1]，不是挪 temp-trips。
#
# 时序：post_family_tweaks 在 customize_image 阶段，内核与 DTB 已装进 ${SDCARD}，
# 看到的即镜像最终态。DTB 定位沿用 rk35xx-chinese-desktop / dtb-no-mac 的两处候选
# （/boot/dtb 有可能是指向 /usr/lib/linux-image-*/rockchip 的软链）。
# 实现约束同前：不用 `| head -1`（pipefail 会把命中判成失败）；dtc 打的 cell 是十进制
# 还是 0x 十六进制取决于 dtc 版本，一律过 $(( )) 归一；空白类正则写 [[:space:]] 不写 \t
# （BSD sed 把 \t 当成 't'，本地 bash 回归会静默解析成空值）。
# -----------------------------------------------------------------------------

function post_family_tweaks__cm3588_nas_fan_check() {
	[[ "${BRANCH}" == vendor* ]] || return 0

	if ! command -v dtc >/dev/null 2>&1; then
		display_alert "$BOARD" "风扇自检跳过：构建主机没有 dtc（device-tree-compiler），无法核对镜像里的风扇节点" "warn"
		return 0
	fi

	local fdt="${BOOT_FDT_FILE##*/}"
	[[ -n "${fdt}" ]] || fdt="rk3588-friendlyelec-cm3588-nas.dtb"

	local dtb="" d
	for d in "${SDCARD}/boot/dtb/rockchip/${fdt}" "${SDCARD}"/usr/lib/linux-image-*/rockchip/"${fdt}"; do
		if [[ -f "${d}" ]]; then dtb="${d}"; break; fi
	done
	if [[ -z "${dtb}" ]]; then
		display_alert "$BOARD" "风扇自检失败：镜像里找不到本板 DTB（${fdt}）—— 风扇状态无法确认" "warn"
		return 0
	fi

	# 板级 dts 里 pwm-fan 节点没有子节点，首个 }; 即闭合
	local node
	node="$(dtc -I dtb -O dts -@ "${dtb}" 2>/dev/null | awk '/pwm-fan[[:space:]]*\{/ {on=1} on {print} on && /^[[:space:]]*\};/ {exit}' || true)"
	if [[ -z "${node}" ]]; then
		display_alert "$BOARD" "风扇自检失败：${dtb#"$SDCARD"} 反编译后没有 pwm-fan 节点 —— 风扇不可控" "warn"
		return 0
	fi

	local st fan_on=no
	st="$(printf '%s\n' "${node}" | sed -n 's/^[[:space:]]*status = "\(.*\)";/\1/p')"
	[[ -n "${st}" ]] || st="okay" # DT 里不写 status 默认就是 okay
	case "${st}" in okay | ok) fan_on=yes ;; esac # 新规范里 "ok" 与 "okay" 同义

	# 一次扫出 cooling-levels 与 rockchip,temp-trips 两个数组，各自压成一行
	local props kind cells dec trips_raw="" levels_raw="" v
	props="$(printf '%s\n' "${node}" | awk '
		/(cooling-levels|temp-trips)[[:space:]]*=[[:space:]]*</ {
			key = ($0 ~ /temp-trips/) ? "TRIPS" : "LEVELS"
			line = $0; sub(/.*=[[:space:]]*</, "", line)
			if (line ~ />/) { sub(/>.*/, "", line); printf "%s %s\n", key, line; key = ""; next }
			buf = line; next
		}
		key != "" {
			line = $0
			if (line ~ />/) { sub(/>.*/, "", line); printf "%s %s\n", key, buf " " line; key = "" }
			else { buf = buf " " line }
		}
	')"
	while read -r kind cells; do
		[[ -n "${kind}" ]] || continue
		dec=""
		for v in ${cells}; do
			# 只吃纯数字；dtc 万一把 phandle 引用之类打出来就跳过，别让 $(( )) 把构建搞挂
			[[ "${v}" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || continue
			dec+="${dec:+ }$(( v ))" # 十进制与 0x 十六进制都吃
		done
		[[ "${kind}" == "TRIPS" ]] && trips_raw="${dec}" || levels_raw="${dec}"
	done <<< "${props}"

	display_alert "$BOARD" "风扇节点: ${dtb#"$SDCARD"} :: status=${st} cooling-levels=${levels_raw:-<无>} temp-trips=${trips_raw:-<无>}" "info"

	local -a tc=(${trips_raw})
	local -a trip_list=()
	local i
	for ((i = 0; i + 1 < ${#tc[@]}; i += 2)); do
		trip_list+=("$(( tc[i] / 1000 ))℃->档${tc[i + 1]}")
	done

	if [[ "${fan_on}" != "yes" ]]; then
		display_alert "$BOARD" "风扇未开：status=\"${st}\" —— 0001-cm3588-nas-enable-pwm-fan.patch 没生效，NAS 将无强制风冷" "err"
		return 0
	fi
	if [[ "${tc[0]:-0}" == "45000" ]]; then
		display_alert "$BOARD" "风扇已开，触发档: ${trip_list[*]:-<单档/未配>}" "info"
	else
		display_alert "$BOARD" "风扇已开，但触发档不是本仓补丁的 45..65：${trip_list[*]:-<无 temp-trips，风扇恒定满速或由守护进程决定>} —— 核对 userpatches/kernel/rk35xx-vendor-6.1/0001-cm3588-nas-enable-pwm-fan.patch" "warn"
	fi

	return 0
}

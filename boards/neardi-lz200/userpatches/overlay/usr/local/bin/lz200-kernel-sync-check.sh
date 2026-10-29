#!/bin/bash
# ================================================================
#  Neardi LZ200 (RK3576) 内核 / 模块 / initramfs 同源自检
#
#  背景：/lib/modules 与内核 Image 若用不同 .config 编译，module_layout
#        的 CRC 会不同（modversions 机制），表现是开机 dmesg 刷
#        "xxx: disagrees about version of symbol module_layout"，
#        模块加载失败或必须 modprobe -f 强加载。
#        initramfs 里另存一份模块副本，若换过模块树却没重建 initramfs，
#        则开机早期阶段的模块会继续报错。
#
#  用法：
#    lz200-kernel-sync-check.sh           # 完整检查（模块树 + initramfs）
#    lz200-kernel-sync-check.sh --quick   # 只查模块树与内核运行态
#
#  退出码：0 = 同源；1 = 发现漂移
# ================================================================
set -u

KREL=$(uname -r)
MODDIR=/lib/modules/$KREL
INITRD=/boot/initrd.img-$KREL
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

RC=0

hr() { printf '%s\n' "------------------------------------------------------------"; }

hr
echo "内核 / 模块 / initramfs 同源自检"
echo "  kernel release : $KREL"
echo "  module tree    : $MODDIR ($(ls -ld $MODDIR | awk '{print $6,$7,$8}'))"
[ -f "$INITRD" ] && echo "  initramfs      : $INITRD ($(ls -ld $INITRD | awk '{print $6,$7,$8}'))"
hr

# ---------------------------------------------------------------
# 1. 运行态：dmesg 是否有符号版本冲突
# ---------------------------------------------------------------
echo "[1] dmesg 符号版本冲突"
BAD=$(dmesg 2>/dev/null | grep -c "disagrees about version")
if [ "$BAD" -eq 0 ]; then
	echo "    PASS — 无 'disagrees about version' 记录"
else
	echo "    FAIL — 发现 $BAD 条冲突："
	dmesg 2>/dev/null | grep "disagrees about version" | sed 's/^/      /' | head -20
	RC=1
fi

# ---------------------------------------------------------------
# 2. 运行态：内核 taint 标志（强制加载会置位）
# ---------------------------------------------------------------
echo
echo "[2] 内核 taint 标志"
T=$(cat /proc/sys/kernel/tainted 2>/dev/null)
if [ "$T" = "0" ]; then
	echo "    PASS — tainted=0（无强加载、无树外模块）"
else
	echo "    WARN — tainted=$T"
	echo "      位含义: 1=专有模块 2=强制加载(module_layout 不符) 4096=树外(OOT) ..."
	RC=1
fi

# ---------------------------------------------------------------
# 3. 模块树自洽：vermagic 是否与运行内核一致
# ---------------------------------------------------------------
echo
echo "[3] 模块树 vermagic 抽样"
ERRORS=0
for m in skw_sdio_v20 skw6316 raid6_pq; do
	F=$(find $MODDIR -name "$m.ko" 2>/dev/null | head -1)
	[ -z "$F" ] && continue
	VM=$(modinfo -F vermagic "$F" 2>/dev/null | awk '{print $1}')
	printf "    %-16s %s\n" "$m" "$VM"
	[ "$VM" != "$KREL" ] && ERRORS=$((ERRORS+1))
done
if [ "$ERRORS" -eq 0 ]; then echo "    PASS — vermagic 全部匹配"
else echo "    FAIL — $ERRORS 个模块 vermagic 不匹配"; RC=1; fi

# ---------------------------------------------------------------
# 4. initramfs 内模块副本是否与 /lib/modules 同一批
# ---------------------------------------------------------------
echo
if [ "$QUICK" -eq 1 ]; then
	echo "[4] initramfs 校验已跳过（--quick）"
else
	echo "[4] initramfs 模块副本比对（md5）"
	if [ ! -f "$INITRD" ]; then
		echo "    SKIP — 无 $INITRD"
	else
		TMP=$(mktemp -d /tmp/lz200-sync.XXXXXX)
		unmkinitramfs "$INITRD" "$TMP" >/dev/null 2>&1
		IRD="$TMP/usr/lib/modules/$KREL"
		if [ ! -d "$IRD" ]; then
			IRD=$(find "$TMP" -maxdepth 4 -type d -name "$KREL" -path "*modules*" | head -1)
		fi
		if [ -z "$IRD" ] || [ ! -d "$IRD" ]; then
			echo "    SKIP — initramfs 内未找到模块目录"
		else
			TOTAL=0; DIFF=0
			while read -r rel; do
				TOTAL=$((TOTAL+1))
				A="$IRD/$rel"
				B="$MODDIR/$rel"
				if [ ! -f "$B" ]; then continue; fi
				if ! cmp -s "$A" "$B"; then
					DIFF=$((DIFF+1))
					[ "$DIFF" -le 10 ] && echo "      DIFF  $rel"
				fi
			done < <(cd "$IRD" && find . -name '*.ko' | sed 's|^\./||')
			echo "    比对 $TOTAL 个模块，不一致 $DIFF 个"
			if [ "$DIFF" -eq 0 ]; then
				echo "    PASS — initramfs 与 /lib/modules 完全同源"
			else
				echo "    FAIL — initramfs 是旧副本，请执行： update-initramfs -u -k $KREL"
				RC=1
			fi
		fi
		rm -rf "$TMP"
	fi
fi

hr
if [ "$RC" -eq 0 ]; then
	echo "结论：同源，无漂移"
else
	echo "结论：存在漂移 —— 修复步骤"
	echo "  1) 确认模块树由运行内核同一份 .config 编译（可用 /proc/config.gz 作权威配置）"
	echo "  2) 覆盖 /lib/modules/$KREL 后： depmod -a $KREL"
	echo "  3) 重建 initramfs：            update-initramfs -u -k $KREL"
	echo "  4) 重启后复跑本脚本确认"
fi
hr
exit $RC

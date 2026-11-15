#!/usr/bin/env bash
#
# rk-dtb-no-mac.sh —— 在构建 chroot 内执行（由 dtb-no-mac 扩展暂存后调用）
# 去除所有内核 DTB 中写死的 MAC 属性，让 RK 厂商内核 GMAC 驱动：
#   efuse/cpuid 派生每板唯一 MAC，派生失败则随机生成本地 MAC。
# 退出码始终为 0：本脚本只做「去写死 MAC」的加固，不应中断镜像构建。
#
set -u
export LC_ALL=C

log() { echo "[dtb-no-mac] $*"; }

PROPS='local-mac-address|mac-address'

# 1) 确保有 dtc（device-tree-compiler）
if ! command -v dtc >/dev/null 2>&1; then
	if command -v apt-get >/dev/null 2>&1; then
		apt-get update -qq >/dev/null 2>&1 || true
		apt-get install -y -qq --no-install-recommends device-tree-compiler >/dev/null 2>&1 || true
	fi
fi
if ! command -v dtc >/dev/null 2>&1; then
	log "WARN: dtc 不可用且无法安装，跳过 MAC 去除（DTB 保持原样，请人工复核）"
	exit 0
fi

shopt -s nullglob

# 2) 收集候选 dtb（去重，解析符号链接后的实体文件，避免 /boot/dtb 软链重复处理）
candidates=()
for base in /boot/dtb /usr/lib/linux-image-*; do
	[[ -e "$base" ]] || continue
	while IFS= read -r -d '' p; do candidates+=("$p"); done < <(find "$base" -type f -name '*.dtb' -print0 2>/dev/null)
done
# /boot/dtb 常为指向 /usr/lib/linux-image-<ver>/dtb 的符号链接，补一刀实体目录
if [[ -L /boot/dtb ]]; then
	rl=$(readlink -f /boot/dtb)
	[[ -d "$rl" ]] && while IFS= read -r -d '' p; do candidates+=("$p"); done < <(find "$rl" -type f -name '*.dtb' -print0 2>/dev/null)
fi

# 去重（兼容 bash 3.x：不用关联数组）
uniq_dtbs=()
for d in "${candidates[@]:-}"; do
	[[ -n "$d" ]] || continue
	r=$(readlink -f "$d")
	skip=0
	for u in "${uniq_dtbs[@]:-}"; do
		[[ "$u" == "$r" ]] && { skip=1; break; }
	done
	[[ $skip -eq 1 ]] && continue
	uniq_dtbs+=("$r")
done

if [[ ${#uniq_dtbs[@]} -eq 0 ]]; then
	log "未找到任何内核 dtb，跳过（可能本构建不含内核）"
	exit 0
fi

tmpd=$(mktemp -d)
trap 'rm -rf "$tmpd"' EXIT

SCANNED=0
REMOVED=0

for f in "${uniq_dtbs[@]:-}"; do
	[[ -f "$f" ]] || continue
	SCANNED=$((SCANNED + 1))

	# 3) 检查是否含写死 MAC
	if ! dtc -I dtb -O dts -@ "$f" 2>/dev/null | grep -qE "$PROPS"; then
		continue
	fi
	log "发现写死 MAC: $f"

	dts="$tmpd/$(basename "$f").dts"
	out="$tmpd/$(basename "$f").new.dtb"

	# 4) 反编译
	if ! dtc -I dtb -O dts -@ -o "$dts" "$f" 2>/dev/null; then
		log "WARN: 反编译失败，跳过 $f"
		continue
	fi
	# 5) 删除 MAC 属性行（保留其余内容）
	if ! grep -vE "^[[:space:]]*($PROPS)[[:space:]]*=" "$dts" > "$dts.filtered"; then
		cp "$dts" "$dts.filtered"
	fi
	# 6) 重编译（保留 overlay 符号 -@，避免 panthor 等 dtbo 引用失效）
	if ! dtc -I dts -O dtb -@ -o "$out" "$dts.filtered" 2>/dev/null; then
		log "WARN: 重编译失败，跳过 $f（保持原样）"
		continue
	fi
	# 7) 校验产物可解析
	if ! dtc -I dtb -O dts -@ "$out" >/dev/null 2>&1; then
		log "WARN: 重编译产物无法解析，跳过 $f（保持原样）"
		continue
	fi
	# 8) 原样覆盖（cat 保留目标文件权限；若 /boot/dtb 是软链则作用于软链指向的实体）
	cat "$out" > "$f"
	REMOVED=$((REMOVED + 1))
	log "已去除写死 MAC: $f"
done

log "完成: 扫描 ${SCANNED} 个 dtb，去除 ${REMOVED} 个含写死 MAC 的 dtb"
exit 0

#!/usr/bin/env bash
# =============================================================================
# set-cma.sh — RK35xx 硬解前置：设置/校验 CMA=512M（仅 Armbian，显式、幂等）
# -----------------------------------------------------------------------------
# 为什么单独成脚本而不是塞进 rkmpp-stack.deb 的 postinst：
#   CMA 是内核启动期连续内存预留，只能走内核 cmdline（Armbian 用
#   /boot/armbianEnv.txt 的 extraboardargs=cma=512M），运行时无法可靠扩容，
#   必须 reboot 才生效。改 /boot 属于高风险启动配置操作，应由用户**主动、显式**
#   执行，而非藏进「装用户态软件」的静默副作用里。
#
# 行为分三档：
#   默认（无参数）  只读报告：打印当前 CmaTotal、armbianEnv.txt 现状、是否已设。
#                   绝不修改任何文件。
#   --apply         真正写入：仅 Armbian（存在 /boot/armbianEnv.txt）生效；
#                   幂等合并到已有 extraboardargs（不覆盖其它参数）；写后明确告警需 reboot。
#   --check         校验：CmaTotal == 524288 kB(512M) 则 PASS，否则 FAIL。
#
# 非 Armbian（无 armbianEnv.txt）：不写任何东西，打印手动指引后退出非 0。
#
# 用法：
#   sudo bash set-cma.sh            # 只读报告（推荐先跑这个看现状）
#   sudo bash set-cma.sh --apply    # 写入 cma=512M 并提示 reboot
#   sudo bash set-cma.sh --check    # 校验当前 CMA 是否已达 512M
#
# 环境变量：
#   CMA_SIZE   目标大小（默认 512M）；改这个值可设其它档位（如 256M）。
#   ARMBIANENV 指定 armbianEnv.txt 路径（默认 /boot/armbianEnv.txt）。
# =============================================================================
set -uo pipefail

CMA_TARGET_KB=524288            # 512M，单位 kB，对应 /proc/meminfo 的 CmaTotal
CMA_SIZE="${CMA_SIZE:-512M}"
ARMBIANENV="${ARMBIANENV:-/boot/armbianEnv.txt}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "  ⚠️  $*" >&2; }
ok()   { echo "  ✅ $*"; }
die()  { echo "  ❌ $*" >&2; exit 1; }

# 把 "512M" 转成 kB 数字（仅支持 M 单位）
cma_to_kb() {
  local s="$1"
  case "$s" in
    *M) echo "${s%M} * 1024" | bc 2>/dev/null || echo "$(( ${s%M} * 1024 ))" ;;
    *)  echo "$s" ;;   # 已是数字（kB）则原样
  esac
}

# 当前 CmaTotal（kB），读不到返回 0
current_cma_kb() {
  local v
  v="$(awk '/^CmaTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  echo "${v:-0}"
}

# 解析 armbianEnv.txt 里 extraboardargs 的当前值（无则空）
current_extraboardargs() {
  [ -r "$ARMBIANENV" ] || { echo ""; return; }
  grep -E '^extraboardargs=' "$ARMBIANENV" 2>/dev/null | tail -1 | sed 's/^extraboardargs=//'
}

# 把 cma=NNN 写进 extraboardargs（幂等合并，不覆盖其它参数）
# 入参：$1 = 目标 cma 字符串（如 512M）
apply_cma() {
  local want="$1" newval oldval
  oldval="$(current_extraboardargs)"
  if echo "$oldval" | grep -qE "cma=${want}"; then
    log "extraboardargs 已含 cma=${want}，无需改动"
    return 0
  fi
  # 若已有其它 cma= 值，替换之；否则追加
  if [ -n "$oldval" ]; then
    newval="$(echo "$oldval" | sed -E "s/cma=[0-9]+M/cma=${want}/")"
    if echo "$newval" | grep -qE "cma=${want}"; then
      : # 已替换
    else
      newval="${oldval} cma=${want}"
    fi
  else
    newval="cma=${want}"
  fi

  if [ -f "$ARMBIANENV" ]; then
    # 存在 extraboardargs 行 → 替换该行；否则追加
    if grep -qE '^extraboardargs=' "$ARMBIANENV"; then
      local tmp; tmp="$(mktemp)"
      sed -E "s|^extraboardargs=.*|extraboardargs=${newval}|" "$ARMBIANENV" > "$tmp"
      cat "$tmp" > "$ARMBIANENV"; rm -f "$tmp"
    else
      printf 'extraboardargs=%s\n' "$newval" >> "$ARMBIANENV"
    fi
  else
    die "未找到 $ARMBIANENV，无法写入（非 Armbian？见下方手动指引）"
  fi
  ok "已写入 extraboardargs=${newval} → $ARMBIANENV"
  warn "⚠️ CMA 需 reboot 后才生效；reboot 后请再跑 'bash set-cma.sh --check' 确认 CmaTotal=$CMA_TARGET_KB kB"
}

# 非 Armbian 的手动指引
manual_guide() {
  echo ""
  echo "== 非 Armbian 系统手动设置 CMA (${CMA_SIZE}) 参考 =="
  echo "  GRUB 系 (Debian/Ubuntu):"
  echo "    在 /etc/default/grub 的 GRUB_CMDLINE_LINUX_DEFAULT 追加 cma=${CMA_SIZE}"
  echo "    sudo update-grub && sudo reboot"
  echo "  /boot/cmdline.txt 系 (Pi 等):"
  echo "    在单行末尾追加 cma=${CMA_SIZE} 后 reboot"
  echo "  本脚本只处理 Armbian 的 /boot/armbianEnv.txt（extraboardargs）。"
}

report() {
  local cur kb want
  cur="$(current_cma_kb)"
  kb="$(cma_to_kb "$CMA_SIZE")"
  echo "== CMA 现状（只读报告，未做任何修改）=="
  echo "  目标 CMA        : ${CMA_SIZE} (= ${kb} kB)"
  echo "  当前 CmaTotal   : ${cur} kB  (from /proc/meminfo)"
  if [ "$cur" -ge "$kb" ] 2>/dev/null; then
    ok "当前 CMA 已 ≥ 目标，硬解内存足够"
  else
    warn "当前 CMA 不足 ${CMA_SIZE}；4K 硬解可能掉帧/失败，需设置后 reboot"
  fi
  echo "  armbianEnv.txt  : ${ARMBIANENV}"
  if [ -r "$ARMBIANENV" ]; then
    local eb; eb="$(current_extraboardargs)"
    if [ -n "$eb" ]; then
      echo "  extraboardargs : ${eb}"
      echo "$eb" | grep -qE "cma=${CMA_SIZE}" && ok "已含 cma=${CMA_SIZE}" || warn "未含 cma=${CMA_SIZE}"
    else
      warn "armbianEnv.txt 中无 extraboardargs 行"
    fi
  else
    warn "未找到 ${ARMBIANENV}（可能不是 Armbian）"
    manual_guide
  fi
}

check_only() {
  local cur kb
  cur="$(current_cma_kb)"
  kb="$(cma_to_kb "$CMA_SIZE")"
  echo "== CMA 校验 =="
  echo "  目标: ${kb} kB (${CMA_SIZE})  当前: ${cur} kB"
  if [ "$cur" -ge "$kb" ] 2>/dev/null; then
    ok "PASS: CmaTotal=${cur} kB ≥ ${kb} kB"
    return 0
  else
    die "FAIL: CmaTotal=${cur} kB < ${kb} kB（需 reboot 或先 --apply）"
  fi
}

main() {
  local mode="report"
  for a in "$@"; do
    case "$a" in
      --apply) mode="apply" ;;
      --check) mode="check" ;;
      -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
      *) warn "未知参数: $a（忽略）" ;;
    esac
  done

  case "$mode" in
    report) report ;;
    check)  check_only ;;
    apply)
      # 仅 --apply 需要 root 与写文件
      if [ "$(id -u)" -ne 0 ]; then
        exec sudo ARMBIANENV="$ARMBIANENV" CMA_SIZE="$CMA_SIZE" bash "$0" --apply
      fi
      [ -r "$ARMBIANENV" ] || { warn "未找到 ${ARMBIANENV}（可能不是 Armbian）"; manual_guide; exit 1; }
      log "准备写入 CMA=${CMA_SIZE}（仅 Armbian /boot/armbianEnv.txt，幂等合并）"
      apply_cma "$CMA_SIZE"
      ;;
  esac
}

# 仅在作为脚本直接执行时运行；被 source 时不触发（便于单测函数）
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi

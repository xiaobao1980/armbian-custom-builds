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
#                   幂等合并到已有 extraboardargs（不覆盖其它参数），并删掉 extraargs 行里
#                   模板自带的 cma=（两条并存时 Linux 只认最后一个，生效值取决于拼接顺序）；
#                   写后明确告警需 reboot。
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

# 解析 armbianEnv.txt 里 extraargs 的当前值（无则空）
current_extraargs() {
  [ -r "$ARMBIANENV" ] || { echo ""; return; }
  grep -E '^extraargs=' "$ARMBIANENV" 2>/dev/null | tail -1 | sed 's/^extraargs=//'
}

# 删掉 extraargs 行里的 cma=<值>，同行其它参数原样保留；每条 extraargs 行都处理。
# 为什么必须删：rk35xx family 的 bootenv 模板自带 extraargs=cma=256M，boot.cmd 拼的是
# "${extraargs} ${extraboardargs}"，而 Linux 的 cma= 取最后一次出现 —— 两条并存时生效值
# 全靠拼接顺序（cm3588-nas 实测 cmdline 即 `cma=256M cma=512M`）。CMA 只留 extraboardargs
# 一个来源，语义与扩展 rkmpp-mpv.sh、板端 rk35xx-rkmpp-mpv-build.sh 一致。
strip_extraargs_cma() {
  local tmp
  [ -f "$ARMBIANENV" ] || return 1
  tmp="$(mktemp)"
  # 幂等判据用「转换后与原文件比对」，不用「最后一行有没有 cma」：多行 extraargs 时后者会漏
  awk '
    function drop_cma(line, key,   v, n, i, parts, out) {
      v = substr(line, length(key) + 2)   # +2 = 跳过 "key=" 本身
      n = split(v, parts, /[ \t]+/)
      out = ""
      for (i = 1; i <= n; i++)
        if (parts[i] != "" && parts[i] !~ /^cma=/)
          out = out (out == "" ? "" : " ") parts[i]
      return key "=" out
    }
    /^extraargs=/ { print drop_cma($0, "extraargs"); next }
    { print }
  ' "$ARMBIANENV" > "$tmp"
  if cmp -s "$tmp" "$ARMBIANENV"; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp" > "$ARMBIANENV"
  rm -f "$tmp"
  return 0
}

# 把 cma=NNN 写进 extraboardargs（幂等合并，不覆盖其它参数）
# 入参：$1 = 目标 cma 字符串（如 512M）
apply_cma() {
  local want="$1" newval oldval
  if strip_extraargs_cma; then
    ok "已删除 extraargs 里的 cma=（family 模板自带），CMA 统一由 extraboardargs 提供"
  fi
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
      # 值经 ENVIRON 交给 awk，不拼进 sed 替换式：newval 来自文件本身，
      # 其中的 & 会被 sed 解释成「整段匹配」，把启动参数原地吃掉。
      CMA_LINE="extraboardargs=${newval}" awk '{ if ($0 ~ /^extraboardargs=/) print ENVIRON["CMA_LINE"]; else print }' "$ARMBIANENV" > "$tmp"
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
    # extraargs 是 family bootenv 模板的键（rk35xx 自带 cma=256M）。它和 extraboardargs
    # 同时挂 cma= 时，boot.cmd 的 "${extraargs} ${extraboardargs}" 拼出两个 cma=，
    # Linux 取最后一个 —— 生效值由拼接顺序决定，不是设计。--apply 会把这条清掉。
    local ea; ea="$(current_extraargs)"
    if [ -n "$ea" ]; then
      echo "  extraargs      : ${ea}"
      case " ${ea} " in
        *" cma="*) warn "extraargs 也带 cma=（模板自带）：与 extraboardargs 并存 → 跑 'bash set-cma.sh --apply' 收敛到单一来源" ;;
      esac
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
    # 真实生效值以 cmdline 为准：cma= 出现多次时 Linux 取最后一个，今天「碰巧是 512M」
    # 不代表设计正确 —— 模板顺序一变就退回 256M。这里只做提示，不推翻上面的 PASS。
    local n; n="$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | grep -c '^cma=' || true)"
    if [ "${n:-0}" -gt 1 ] 2>/dev/null; then
      warn "cmdline 里有 ${n} 个 cma=（$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | grep '^cma=' | paste -sd ' ' -)）：只有最后一个生效；跑 --apply 可收敛成一条"
    fi
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

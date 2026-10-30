#!/bin/bash
# =============================================================================
# rkmpp-health-check.sh — RK35xx 全栈只读体检（rkmpp + mpv + chromium + 中文 + 硬解实测）
#
# 与 verify-rkmpp-image.sh 的分工：
#   verify-rkmpp-image.sh  校验 + 自愈（需 sudo，会改 udev/图标缓存/补配置）
#   rkmpp-health-check.sh  纯只读体检（不改系统，只往 /tmp 写临时文件）
#
# 适用：RK3566 / RK3568 / RK3576 / RK3588 + Armbian vendor BSP + X11 桌面
#
# 用法：
#   bash rkmpp-health-check.sh                     # 全量（含 4K 实测，自动找样片）
#   bash rkmpp-health-check.sh --no-play           # 跳过播放实测（纯静态）
#   bash rkmpp-health-check.sh --file /path/a.mp4  # 指定测试片（可重复）
#   bash rkmpp-health-check.sh --json              # 末尾额外输出 JSON 汇总
#   sudo bash rkmpp-health-check.sh                # 允许，会自动切到桌面用户跑 mpv
#
# 退出码：0 = 无 FAIL；1 = 存在 FAIL 项；2 = 环境不适用（非 arm64 / 非 RK 平台）
# =============================================================================

set -o nounset
# 刻意不开 pipefail：本脚本大量使用 `grep -c` 统计，pipefail + SIGPIPE 会误报（历史踩坑）

VERSION="1.0"
DO_PLAY=1
JSON_OUT=0
TEST_FILES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --no-play) DO_PLAY=0; shift ;;
        --json)    JSON_OUT=1; shift ;;
        --file)    TEST_FILES+=("$2"); shift 2 ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1（--help 查看用法）" >&2; exit 1 ;;
    esac
done

PASSED=0; FAILED=0; WARNED=0
RESULTS=$(mktemp /tmp/rkmpp-check.XXXXXX)
TMPD=$(mktemp -d /tmp/rkmpp-tmp.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT

record() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$RESULTS"; }
pass()   { PASSED=$((PASSED+1)); record PASS "$1" "${2:-}"; printf '  [PASS] %s%s\n' "$1" "${2:+  — $2}"; }
fail()   { FAILED=$((FAILED+1)); record FAIL "$1" "${2:-}"; printf '  [FAIL] %s%s\n' "$1" "${2:+  — $2}"; }
warn()   { WARNED=$((WARNED+1)); record WARN "$1" "${2:-}"; printf '  [WARN] %s%s\n' "$1" "${2:+  — $2}"; }
info()   { record INFO "$1" "${2:-}"; printf '  [INFO] %s%s\n' "$1" "${2:+  — $2}"; }
hr()     { echo; echo "──── $* ────"; }

echo "======================================================================"
echo " RK35xx 全栈体检 rkmpp-health-check v${VERSION}"
echo " 时间: $(date '+%Y-%m-%d %H:%M:%S %z')   主机: $(hostname)   用户: $(id -un)"
echo "======================================================================"

# ============================ A. 平台与系统身份 ============================
hr "A. 平台与系统身份"

ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    pass "架构 = aarch64"
else
    fail "架构 = $ARCH" "本脚本只适用于 arm64"
fi

KREL=$(uname -r)
case "$KREL" in
    *vendor*|*rk35*|*rockchip*) pass "内核 = $KREL" "vendor BSP 分支（含 mpp_service 驱动）" ;;
    *) warn "内核 = $KREL" "非 vendor 分支，mainline 通常无 mpp_service" ;;
esac
info "内核构建: $(uname -v)"

if [ -r /proc/device-tree/model ]; then
    DT_MODEL=$(tr -d '\0' < /proc/device-tree/model)
    info "DT model: $DT_MODEL"
else
    warn "无法读取 /proc/device-tree/model"
fi
if [ -r /proc/device-tree/compatible ]; then
    DT_COMPAT=$(tr '\0' ' ' < /proc/device-tree/compatible | sed 's/ *$//')
    info "DT compatible: $DT_COMPAT"
    # 常见坑：板级 DTB 直接复用 EVB 的 compatible 字符串（文件名对但内部标识是 EVB）
    case "$DT_COMPAT" in
        *evb*) warn "compatible 指向 EVB" "板级 DTB 可能沿用 EVB 标识，依赖 compatible 精确匹配的驱动需留意" ;;
        *) pass "compatible 为板级专用标识" ;;
    esac
fi

if [ -r /etc/os-release ]; then
    DISTRO_CODENAME=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')
    DISTRO_PRETTY=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')
    info "发行版: $DISTRO_PRETTY  (codename=$DISTRO_CODENAME)"
fi
info "启动参数: $(tr -s ' ' < /proc/cmdline | cut -c1-200)"

# 平台识别（决定后续期望值）
if [ -r /proc/device-tree/compatible ]; then
    case "$DT_COMPAT" in
        *rk3588*|*rk3576*|*rk3568*|*rk3566*) info "平台: Rockchip ${DT_COMPAT##*rockchip,}" ;;
        *) warn "未识别到 RK35xx 平台" "后续判定可能不适用" ;;
    esac
fi

# ============================ B. 镜像版本 ============================
hr "B. 镜像版本线索"

if [ -r /etc/armbian-release ]; then
    for k in BOARD BRANCH VERSION LINUXFAMILY IMAGE_TYPE; do
        v=$(sed -n "s/^${k}=//p" /etc/armbian-release | head -1)
        [ -n "$v" ] && info "$k = $v"
    done
else
    warn "非 Armbian 系统" "无 /etc/armbian-release"
fi

if [ -r /boot/armbianEnv.txt ]; then
    info "armbianEnv fdtfile: $(sed -n 's/^fdtfile=//p' /boot/armbianEnv.txt | head -1)"
    info "armbianEnv extraboardargs: $(sed -n 's/^extraboardargs=//p' /boot/armbianEnv.txt | head -1)"
fi

# ============================ C. 桌面会话 ============================
hr "C. 桌面会话（X11 / Wayland）"

DM=$(systemctl is-active display-manager 2>/dev/null || echo unknown)
case "$DM" in
    active) pass "display-manager = active" ;; 
    *) warn "display-manager = $DM" "无图形登录管理器，播放实测将跳过" ;;
esac

XSERVER=""; XORG_PID=""; WAYLAND_PID=""
if pgrep -x Xorg >/dev/null 2>&1; then
    XORG_PID=$(pgrep -x Xorg | head -1)
    XORG_CMD=$(tr '\0' ' ' < "/proc/$XORG_PID/cmdline" 2>/dev/null)
    XSERVER=x11
    pass "Xorg 运行中" "PID=$XORG_PID  $(echo "$XORG_CMD" | grep -oE ':[0-9]+' | head -1)"
elif pgrep -x Xwayland >/dev/null 2>&1; then
    WAYLAND_PID=$(pgrep -x Xwayland | head -1)
    XSERVER=wayland
    warn "Only Xwayland 运行中（Wayland 会话）" "rkmpp X11 零拷贝路径不适用，应改用 mesa-vpu"
else
    warn "未检测到 Xorg / Xwayland" "无图形会话，播放实测将跳过"
fi

if [ -S /tmp/.X11-unix/X0 ]; then
    pass "X11 socket :0 存在"
else
    warn "无 /tmp/.X11-unix/X0"
fi

# 找桌面用户（用于 mpv 播放：普通用户才有 MIT cookie）
DESK_USER=""; DESK_HOME=""
if [ "$(id -u)" = "0" ]; then
    for h in /home/*/; do
        u=$(basename "$h")
        if [ -f "$h/.Xauthority" ]; then
            DESK_USER="$u"; DESK_HOME="${h%/}"
            break
        fi
    done
    if [ -n "$DESK_USER" ]; then
        info "以 root 运行 → 播放将切到桌面用户: $DESK_USER"
    else
        warn "root 运行且未找到带 .Xauthority 的桌面用户" "播放实测可能因 MIT cookie 失败"
    fi
else
    DESK_USER=$(id -un)
    DESK_HOME="$HOME"
fi

# ============================ D. CMA（硬解必需） ============================
hr "D. CMA 连续内存"

CMA_TOTAL=$(sed -n 's/^CmaTotal:[[:space:]]*\([0-9]*\) kB/\1/p' /proc/meminfo)
CMA_FREE=$(sed -n 's/^CmaFree:[[:space:]]*\([0-9]*\) kB/\1/p' /proc/meminfo)
if [ -z "$CMA_TOTAL" ]; then
    fail "CMA 未启用" "内核无 CmaTotal，4K 硬解会因缓冲不足失败"
else
    CMA_MB=$((CMA_TOTAL/1024))
    if [ "$CMA_TOTAL" -ge 524288 ]; then
        pass "CmaTotal = ${CMA_TOTAL} kB (${CMA_MB}M)" "满足 4K 硬解基线 512M"
    elif [ "$CMA_TOTAL" -ge 262144 ]; then
        warn "CmaTotal = ${CMA_TOTAL} kB (${CMA_MB}M)" "低于推荐 512M，4K60 可能掉帧；见 set-cma.sh"
    else
        fail "CmaTotal = ${CMA_TOTAL} kB (${CMA_MB}M)" "远低于 512M，硬解大概率失败"
    fi
    info "CmaFree = ${CMA_FREE} kB"
fi

# ============================ E. VPU/RGA 设备节点 ============================
hr "E. VPU / RGA / DRM 设备节点"

for d in /dev/mpp_service /dev/rga /dev/dri/renderD128 /dev/dri/card0; do
    if [ -e "$d" ]; then
        perm=$(stat -c '%a %U:%G' "$d" 2>/dev/null)
        case "$d" in
            /dev/mpp_service|/dev/rga)
                if [ -n "$DESK_USER" ] && [ "$(stat -c %a "$d" 2>/dev/null)" -ge 660 ] 2>/dev/null; then
                    pass "$d 存在" "perm=$perm"
                else
                    warn "$d 存在但权限受限" "perm=$perm（普通用户可能无法访问，verify-rkmpp-image.sh 可自愈 udev）"
                fi ;;
            *) pass "$d 存在" "perm=$perm" ;;
        esac
    else
        case "$d" in
            /dev/mpp_service) fail "$d 缺失" "vendor 内核未启用 mpp_service 或无该 VPU 驱动" ;;
            /dev/rga)         warn "$d 缺失" "仅影响 ffmpeg rkrga 滤镜（缩放/格式转换），纯解码不需要" ;;
            /dev/dri/*)       fail "$d 缺失" "无 DRM 设备，X11/GPU 渲染无法进行" ;;
        esac
    fi
done

if [ -d /sys/class/drm ]; then
    CONN=$(ls /sys/class/drm 2>/dev/null | grep -E 'card[0-9]+-(HDMI|DP|DSI|eDP)' | tr '\n' ' ')
    [ -n "$CONN" ] && info "显示接口: $CONN"
fi

# ============================ F. rkmpp 用户态库 ============================
hr "F. rkmpp 用户态库（MPP / RGA）"

MPP_LIB=""
for c in /usr/local/lib/librockchip_mpp.so.0 /usr/lib/aarch64-linux-gnu/librockchip_mpp.so.0 \
         /usr/local/lib/aarch64-linux-gnu/librockchip_mpp.so.0; do
    [ -e "$c" ] && { MPP_LIB="$c"; break; }
done
if [ -n "$MPP_LIB" ]; then
    # 软链表：.so.1 是 .so.0 的别名（libavcodec 的 NEEDED 是 .so.1）
    MPP_SONAMES=$(ls -1 "$(dirname "$MPP_LIB")"/librockchip_mpp.so* 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')
    pass "librockchip_mpp 已安装" "$MPP_LIB"
    info "SONAME 链: $MPP_SONAMES"
else
    fail "librockchip_mpp 缺失" "mpv/ffmpeg 的 rkmpp 后端无法加载"
fi

RGA_LIB=$(find /usr/local/lib /usr/lib -name 'librga.so.2' 2>/dev/null | head -1)
if [ -n "$RGA_LIB" ]; then
    pass "librga 已安装" "$RGA_LIB"
else
    warn "librga 缺失" "ffmpeg rkrga 滤镜（缩放/格式转换）不可用，纯解码不受影响"
fi

# ldconfig 可能被裁掉（镜像精简），用 cache 二进制兜底核查
if command -v ldconfig >/dev/null 2>&1; then
    N=$(ldconfig -p 2>/dev/null | grep -cE 'rockchip_mpp|librga')
    [ "$N" -gt 0 ] && pass "ldconfig 已登记 rkmpp 库" "命中 $N 条" \
                   || warn "ldconfig 缓存未登记 rkmpp 库" "可执行 sudo ldconfig 重建"
else
    warn "系统无 ldconfig 命令" "镜像精简所致；改用 /etc/ld.so.cache 二进制核查"
    if grep -aq 'librockchip_mpp' /etc/ld.so.cache 2>/dev/null; then
        pass "/etc/ld.so.cache 已含 librockchip_mpp"
    else
        warn "/etc/ld.so.cache 未含 librockchip_mpp" "若 mpv 仍能硬解则无碍（靠 RUNPATH）"
    fi
fi

# ============================ G. mpv ============================
hr "G. mpv（rkmp 后端 + 链接 + 配置）"

MPV=$(command -v mpv 2>/dev/null)
if [ -z "$MPV" ]; then
    fail "mpv 未安装" "无法播放；rkmpp-mpv 扩展应安装到 /usr/local/bin/mpv"
else
    MPV_VER=$(mpv --version 2>/dev/null | head -1)
    pass "mpv 已安装" "$MPV  ($MPV_VER)"

    # hwdec 后端：基线 20（rkmpp 10 + rkmpp-copy 10）
    mpv --hwdec=help > "$TMPD/hwdec.txt" 2>&1
    RKMPP_N=$(grep -c 'rkmpp' "$TMPD/hwdec.txt" 2>/dev/null || echo 0)
    if [ "${RKMPP_N:-0}" -ge 20 ]; then
        pass "mpv rkmpp 后端计数 = $RKMPP_N" "基线 20（rkmpp + rkmpp-copy 各 10 编解码器）"
    elif [ "${RKMPP_N:-0}" -gt 0 ]; then
        warn "mpv rkmpp 后端计数 = $RKMPP_N" "低于基线 20，部分编解码器缺失"
    else
        fail "mpv 无 rkmpp 后端" "编译时缺 libdisplay-info-dev 或未启用 drm，见 MEMORY 坑位 1"
    fi
    grep -E '^\s+rkmpp|^\s+rkmpp-copy' "$TMPD/hwdec.txt" | head -3 | while read -r l; do info "  $l"; done

    # 链接的 libavcodec 必须指向 ffmpeg-rkmpp，否则用的是系统 ffmpeg（无 rkmpp）
    LDD_AV=$(ldd "$MPV" 2>/dev/null | grep 'libavcodec')
    case "$LDD_AV" in
        *ffmpeg-rkmpp*) pass "mpv 链接 ffmpeg-rkmpp" "$(echo "$LDD_AV" | awk '{print $3}')" ;;
        "")             warn "无法解析 mpv 的 libavcodec 依赖" ;;
        *)              fail "mpv 链接到系统 libavcodec" "$LDD_AV（非 ffmpeg-rkmpp，硬解会失效）" ;;
    esac

    # 配置文件
    if [ -r /etc/mpv/mpv.conf ]; then
        HWDEC_CFG=$(sed -n 's/^\s*hwdec=\([^[:space:]]*\).*/\1/p' /etc/mpv/mpv.conf | head -1)
        VO_CFG=$(sed -n 's/^\s*vo=\([^[:space:]]*\).*/\1/p' /etc/mpv/mpv.conf | head -1)
        if [ "$HWDEC_CFG" = "rkmpp" ]; then
            pass "/etc/mpv/mpv.conf hwdec=rkmpp" "vo=${VO_CFG:-<未设>}"
        elif [ -z "$HWDEC_CFG" ]; then
            warn "/etc/mpv/mpv.conf 未设 hwdec" "需命令行显式 --hwdec=rkmpp"
        else
            warn "/etc/mpv/mpv.conf hwdec=$HWDEC_CFG" "非 rkmpp，默认播放不走硬解"
        fi
        if [ "$VO_CFG" = "null" ]; then
            fail "/etc/mpv/mpv.conf vo=null" "vo=null 不走 hwdec，会得出'软硬解一样快'的假结论"
        fi
    else
        warn "无 /etc/mpv/mpv.conf" "将只能靠命令行参数"
    fi
fi

# ============================ H. ffmpeg ============================
hr "H. ffmpeg（rkmpp 解码器）"

FFMPEG=$(command -v ffmpeg 2>/dev/null)
if [ -z "$FFMPEG" ]; then
    warn "ffmpeg 未安装" "mpv 自带解码不依赖它，但命令行转码/抽帧需要"
else
    info "ffmpeg: $FFMPEG"
    ffmpeg -hide_banner -decoders > "$TMPD/dec.txt" 2>/dev/null
    DEC_N=$(grep -c '_rkmpp' "$TMPD/dec.txt" 2>/dev/null || echo 0)
    if [ "${DEC_N:-0}" -ge 10 ]; then
        pass "ffmpeg rkmpp 解码器计数 = $DEC_N" "基线 10"
    elif [ "${DEC_N:-0}" -gt 0 ]; then
        warn "ffmpeg rkmpp 解码器计数 = $DEC_N" "低于基线 10"
    else
        fail "ffmpeg 无 rkmpp 解码器" "非 ffmpeg-rockchip 构建或未链接 MPP"
    fi
    HWACCELS=$(ffmpeg -hide_banner -hwaccels 2>/dev/null | grep -x 'rkmpp')
    if [ -n "$HWACCELS" ]; then
        pass "ffmpeg -hwaccels 含 rkmpp"
    else
        warn "ffmpeg -hwaccels 无 rkmpp" "解码器在但 hwaccel 未注册"
    fi
fi

# ============================ I. 浏览器 ============================
hr "I. 浏览器"

BROWSER_FOUND=""
for b in chromium chromium-browser google-chrome-stable firefox firefox-esr; do
    if command -v "$b" >/dev/null 2>&1; then
        BROWSER_FOUND="$b"
        pass "浏览器已安装: $b" "$("$b" --version 2>/dev/null | head -1)"
    fi
done
if [ -z "$BROWSER_FOUND" ]; then
    # 注意：中文 locale 下 apt 输出"候选："而非 "Candidate:"，必须 LC_ALL=C 强制英文
    CAND=$(LC_ALL=C apt-cache policy chromium 2>/dev/null | sed -n 's/^  Candidate: //p')
    if [ -n "$CAND" ]; then
        fail "无任何浏览器" "apt 候选 chromium=$CAND，镜像未安装"
    else
        fail "无任何浏览器" "仓库也无 chromium 候选"
    fi
fi

# ============================ J. 中文环境 ============================
hr "J. 中文环境（locale / 字体 / 输入法）"

LOC=$(locale 2>/dev/null | sed -n 's/^LANG=//p')
case "$LOC" in
    zh_CN*) pass "LANG=$LOC" ;;
    "")     warn "LANG 未设置" ;;
    *)      warn "LANG=$LOC" "非中文 locale，中文界面会回退英文" ;;
esac

if locale -a 2>/dev/null | grep -qiE '^zh_CN'; then
    pass "zh_CN locale 已生成"
else
    fail "zh_CN locale 未生成" "需 locale-gen zh_CN.UTF-8"
fi

ZH_CNT=$(fc-list :lang=zh 2>/dev/null | grep -c . 2>/dev/null || echo 0)
# 取 family 名（fc-list 格式：/path/font.ttf: Family1,Family2:style=...）
ZH_FAMILIES=$(fc-list :lang=zh 2>/dev/null \
    | sed 's|^[^:]*: *||; s|:.*$||' \
    | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep . | sort -u | head -5)
ZH_FILE=$(fc-list :lang=zh 2>/dev/null | head -1 | sed 's|^[^:]*/||; s|:.*||')
if [ "${ZH_CNT:-0}" -ge 5 ]; then
    pass "中文字体 ${ZH_CNT} 个" "$(printf '%s' "$ZH_FAMILIES" | head -3 | tr '\n' ',' | sed 's/,$//')"
elif [ "${ZH_CNT:-0}" -ge 1 ]; then
    case "$(printf '%s' "$ZH_FAMILIES")" in
        *Droid*|*droidsansfallback*)
            warn "中文字体仅 ${ZH_CNT} 个（${ZH_FILE}）" "Droid Sans Fallback 是兜底字体，字形差；建议 fonts-noto-cjk / fonts-wqy-zenhei" ;;
        *)
            warn "中文字体仅 ${ZH_CNT} 个" "$(printf '%s' "$ZH_FAMILIES" | head -2 | tr '\n' ',' | sed 's/,$//')，建议补 fonts-noto-cjk" ;;
    esac
else
    fail "无中文字体" "中文会显示成方块"
fi

IM_FOUND=""
for im in fcitx5 fcitx ibus; do
    if dpkg -l 2>/dev/null | grep -qE "^ii  +$im(:| )"; then
        IM_FOUND="$im"
        pass "输入法框架已装: $im"
    fi
done
if [ -z "$IM_FOUND" ]; then
    fail "无任何输入法框架" "中文只能显示不能输入（fcitx5/ibus 均未安装）"
fi

IM_ENV=""
for v in GTK_IM_MODULE QT_IM_MODULE XMODIFIERS; do
    eval "val=\${$v:-}"
    if [ -n "$val" ]; then IM_ENV="$IM_ENV $v=$val"; fi
done
if [ -n "$IM_ENV" ]; then
    pass "输入法环境变量已设" "$IM_ENV"
elif [ -n "$IM_FOUND" ]; then
    warn "输入法框架在但环境变量未设" "GTK_IM_MODULE/QT_IM_MODULE/XMODIFIERS 需写入 /etc/environment 或 ~/.xprofile"
else
    info "输入法环境变量未设（无框架，属预期）"
fi

# ============================ K. rkmpp-stack 元数据 ============================
hr "K. rkmpp-stack 版本元数据"

BI=/usr/local/share/rkmpp-stack/build-info
if [ -r "$BI" ]; then
    pass "build-info 存在" "$BI"
    sed 's/^/         /' "$BI"
    PKG_VER=$(sed -n 's/^VERSION=//p' "$BI" | head -1)
    info "打包版本: ${PKG_VER:-unknown}"
    for f in MPP RGA; do
        v=$(sed -n "s/^${f}=//p" "$BI" | head -1)
        [ "${v:-unknown}" = "unknown" ] && info "$f 版本未记录" "打包机缺 pkg-config，不影响运行"
    done
else
    warn "无 build-info" "可能为源码编译安装，非预编译 deb"
fi

# ============================ L. 硬件加速实测 ============================
hr "L. 硬件加速实测（4K 真实播放）"

if [ "$DO_PLAY" -eq 0 ]; then
    info "已指定 --no-play，跳过播放实测"
elif [ -z "$MPV" ]; then
    warn "跳过播放实测" "mpv 未安装"
elif [ "$XSERVER" != "x11" ]; then
    warn "跳过播放实测" "需要 X11 会话（当前 ${XSERVER:-无}）；Wayland 请用 mesa-vpu 路线"
elif [ -z "$DESK_USER" ]; then
    warn "跳过播放实测" "未确定桌面用户"
else
    # 样片：优先 --file，其次自动搜索常见目录
    if [ ${#TEST_FILES[@]} -eq 0 ]; then
        for d in "$DESK_HOME/视频" "$DESK_HOME/Videos" "$DESK_HOME" /root /tmp; do
            [ -d "$d" ] || continue
            while IFS= read -r f; do TEST_FILES+=("$f"); done < <(
                find "$d" -maxdepth 2 \( -iname '*.mp4' -o -iname '*.mkv' \) -size +100M 2>/dev/null | head -2
            )
            [ ${#TEST_FILES[@]} -gt 0 ] && break
        done
    fi

    if [ ${#TEST_FILES[@]} -eq 0 ]; then
        warn "未找到 >100M 的测试片" "请用 --file 指定真实高码率 4K 片源（合成测试片软解也能满帧，无判据价值）"
    else
        RUNAS=()
        if [ "$(id -u)" = "0" ] && [ "$DESK_USER" != "root" ]; then
            RUNAS=(runuser -u "$DESK_USER" --)
        fi
        XAUTH="$DESK_HOME/.Xauthority"
        [ -f "$XAUTH" ] || XAUTH=""

        for f in "${TEST_FILES[@]}"; do
            [ -r "$f" ] || { warn "跳过不可读文件: $f"; continue; }
            base=$(basename "$f")
            info "测试: $base"
            # 关键：必须 vo=gpu（不能用 vo=null，否则不走 hwdec，会得出假结论）
            # RUNAS 可能为空数组，用 ${arr[@]+...} 写法兼容 nounset（旧 bash 空数组展开会报 unbound）
            ${RUNAS[@]+"${RUNAS[@]}"} env DISPLAY=:0 ${XAUTH:+XAUTHORITY=$XAUTH} \
                timeout 90 mpv --hwdec=rkmpp --vo=gpu --fs=no --frames=120 \
                     --msg-level=all=info --really-quiet=no \
                     "$f" > "$TMPD/play.log" 2>&1

            HWDEC_LINE=$(grep -m1 'Using hardware decoding' "$TMPD/play.log" 2>/dev/null)
            VO_LINE=$(grep -m1 'VO: \[' "$TMPD/play.log" 2>/dev/null)
            ERR_LINE=$(grep -m1 -iE 'could not open|failed to|cannot open' "$TMPD/play.log" 2>/dev/null)

            if [ -z "$HWDEC_LINE" ] && [ -n "$ERR_LINE" ]; then
                fail "$base 播放失败" "$ERR_LINE"
            elif echo "$HWDEC_LINE" | grep -q 'rkmpp'; then
                if echo "$VO_LINE" | grep -q 'drm_prime'; then
                    pass "$base 零拷贝硬解" "$(echo "$HWDEC_LINE" | sed 's/^ *//')  |  $(echo "$VO_LINE" | sed 's/^ *//')"
                else
                    warn "$base 硬解但非零拷贝" "$(echo "$HWDEC_LINE" | sed 's/^ *//')  |  $(echo "$VO_LINE" | sed 's/^ *//')"
                fi
            elif echo "$HWDEC_LINE" | grep -qi 'copy'; then
                warn "$base 走了 copy 回退" "$(echo "$HWDEC_LINE" | sed 's/^ *//')（非零拷贝，性能有损）"
            else
                fail "$base 未走硬解" "无 'Using hardware decoding' 行；可能编解码器不支持或回退软解"
                grep -m3 -iE 'error|fallback|not supported' "$TMPD/play.log" 2>/dev/null | sed 's/^/         /'
            fi
        done
    fi
fi

# ============================ 汇总 ============================
TOTAL=$((PASSED+FAILED+WARNED))
echo
echo "======================================================================"
echo " 体检汇总"
echo "----------------------------------------------------------------------"
printf "   PASS : %3d\n" "$PASSED"
printf "   WARN : %3d\n" "$WARNED"
printf "   FAIL : %3d\n" "$FAILED"
printf "   合计 : %3d 项判定\n" "$TOTAL"

if [ "$FAILED" -gt 0 ]; then
    echo "----------------------------------------------------------------------"
    echo "   失败项明细:"
    awk -F'\t' '$1=="FAIL"{printf "     - %s%s\n", $2, ($3!=""?"  ("$3")":"")}' "$RESULTS"
fi
if [ "$WARNED" -gt 0 ]; then
    echo "----------------------------------------------------------------------"
    echo "   告警项明细:"
    awk -F'\t' '$1=="WARN"{printf "     - %s%s\n", $2, ($3!=""?"  ("$3")":"")}' "$RESULTS"
fi
echo "======================================================================"

if [ "$JSON_OUT" -eq 1 ]; then
    echo
    echo "--- JSON ---"
    awk -F'\t' '
        BEGIN { print "{\"host\":\"" ENVIRON["HOSTNAME"] "\",\"checks\":[" ; first=1 }
        {
            gsub(/\\/,"\\\\"); gsub(/"/,"\\\"");
            if (!first) printf ",";
            printf "\n  {\"status\":\"%s\",\"item\":\"%s\",\"detail\":\"%s\"}", $1, $2, $3;
            first=0;
        }
        END { print "\n],\"summary\":{\"pass\":" ENVIRON["_P"] ",\"warn\":" ENVIRON["_W"] ",\"fail\":" ENVIRON["_F"] "}}" }
    ' _P="$PASSED" _W="$WARNED" _F="$FAILED" "$RESULTS" 2>/dev/null \
    || { echo "{\"summary\":{\"pass\":$PASSED,\"warn\":$WARNED,\"fail\":$FAILED}}"; }
fi

[ "$FAILED" -gt 0 ] && exit 1
exit 0

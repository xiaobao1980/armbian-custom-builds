#!/usr/bin/env bash
#
# 把指定板卡的自定义文件（config/ patch/ userpatches/）同步进一份
# armbian/build 工作树。只拷贝该板卡目录下的内容 —— 各板卡互不干扰。
#
# 用法: sync-board-to-build.sh <board> <armbian-build-dir>
# 示例: sync-board-to-build.sh h96s ./armbian-build
#
set -euo pipefail

BOARD="${1:?用法: sync-board-to-build.sh <board> <armbian-build-dir>}"
BUILD="${2:?用法: sync-board-to-build.sh <board> <armbian-build-dir>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_ROOT}/boards/${BOARD}"

if [[ ! -d "${SRC}" ]]; then
    echo "ERROR: 板卡 '${BOARD}' 不存在 (boards/ 下可选: $(ls "${REPO_ROOT}/boards" | tr '\n' ' '))" >&2
    exit 1
fi
if [[ ! -d "${BUILD}" ]]; then
    echo "ERROR: armbian/build 工作树 '${BUILD}' 不存在" >&2
    exit 1
fi

# ── 守卫：板级配置文件不许裸赋值「命令行会传的键」──────────────────────────────
# 背景：cmdline 的 KEY=VALUE 只在 early 阶段应用；config/boards/<board>.{csc,conf} 在
# 其后的 config_source_board_file 阶段被 source，而那一阶段之后**不再重放**命令行
# （只有 userpatches/config-*.conf 的 preset 通道会在 source 完再
# apply_cmdline_params_to_env "after config ..."）。于是板级裸赋值会静默顶掉调用方传值。
# 2026-11-22 的 neardi-lz120.csc 里 `ENABLE_EXTENSIONS="verify-boot-env,
# lz120-kernel-config,audio-friendly-names"` 就凭一行吞掉了桌面 workflow 追加的 8 项
# （含 desktop-dm），镜像里没有 display-manager.service → 桌面起不来。见 README「维护约定」。
GUARD_KEYS=(ENABLE_EXTENSIONS BOARD BRANCH RELEASE BUILD_DESKTOP BUILD_MINIMAL
            DESKTOP_ENVIRONMENT DESKTOP_TIER INCLUDE_HOME_DIR KERNEL_CONFIGURE
            KERNEL_BTF COMPRESS_OUTPUTIMAGE EXPERT)

guard_board_config() {
    local dir="${SRC}/config/boards" f key hit
    [[ -d "${dir}" ]] || return 0
    for f in "${dir}"/*.csc "${dir}"/*.conf; do
        [[ -f "${f}" ]] || continue
        for key in "${GUARD_KEYS[@]}"; do
            # 只算行首（可带缩进/export）的裸赋值；注释行与 ${KEY:=...} 判空展开不算
            hit="$(grep -nE "^[[:space:]]*(export[[:space:]]+)?${key}=" "${f}" || true)"
            [[ -z "${hit}" ]] && continue
            echo "ERROR: 板级文件裸赋值了 ${key} —— 板级 config 在命令行之后被 source 且不重放" >&2
            echo "       命令行，会静默顶掉调用方/build.env 传进来的同名值。命中行：" >&2
            printf '%s\n' "${hit}" | sed "s|^|         ${f}:|" >&2
            echo "       修法：删掉该行，板级兜底写进 boards/${BOARD}/build.env。" >&2
            exit 1
        done
    done
    return 0
}

# 清理 macOS 元数据文件（.DS_Store / AppleDouble ._*）。
# 背景：这些文件不被 .gitignore 跟踪，但 `cp -a` 会照样拷进构建树，
# 历史上曾以 .AppleDouble 形式污染过产物。拷贝后主动清理目标侧，最稳。
purge_macos_metadata() {
    local dir="$1"
    [[ -d "${dir}" ]] || return 0
    # GNU find 的 -delete 会隐式打印被删文件名，这里静音，保持构建日志干净
    find "${dir}" -name '.DS_Store' -type f -delete >/dev/null 2>&1 || true
    find "${dir}" -name '._*' -type f -delete >/dev/null 2>&1 || true
}

# 目录级合并拷贝: config/ patch/ userpatches/
sync_subdir() {
    local sub="$1"
    [[ -d "${SRC}/${sub}" ]] || return 0
    mkdir -p "${BUILD}/${sub}"
    cp -a "${SRC}/${sub}/." "${BUILD}/${sub}/"
    purge_macos_metadata "${BUILD}/${sub}"
    echo "  synced ${sub}/ ($(find "${SRC}/${sub}" -type f ! -name '.DS_Store' ! -name '._*' | wc -l | tr -d ' ') files)"
}

guard_board_config   # 先校验再拷贝，避免留下半同步的构建树

echo "==> 同步板卡 '${BOARD}' -> ${BUILD}"
sync_subdir config
sync_subdir patch
sync_subdir userpatches

# 公共扩展 (common/extensions/*.sh) —— 所有板卡共享, 例如 rkmpp-mpv / chromium-rkmpp
# 框架按名字解析: ENABLE_EXTENSIONS=chromium-rkmpp -> userpatches/extensions/chromium-rkmpp.sh
# _archive/ 是历史版本归档（不参与构建），不同步，避免 ENABLE_EXTENSIONS 误启用。
if [[ -d "${REPO_ROOT}/common/extensions" ]]; then
    mkdir -p "${BUILD}/userpatches/extensions"
    cp -a "${REPO_ROOT}/common/extensions/." "${BUILD}/userpatches/extensions/"
    rm -rf "${BUILD}/userpatches/extensions/_archive"
    purge_macos_metadata "${BUILD}/userpatches/extensions"
    echo "  synced common/extensions/ ($(find "${REPO_ROOT}/common/extensions" -maxdepth 1 -mindepth 1 -not -name '_archive' -not -name '.DS_Store' -not -name '._*' | wc -l | tr -d ' ') entries)"
fi

echo "==> 完成"

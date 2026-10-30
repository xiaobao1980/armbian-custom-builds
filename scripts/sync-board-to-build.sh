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

echo "==> 同步板卡 '${BOARD}' -> ${BUILD}"
sync_subdir config
sync_subdir patch
sync_subdir userpatches

# 公共扩展 (common/extensions/*.sh) —— 所有板卡共享, 例如 mesa-vpu
# 框架按名字解析: ENABLE_EXTENSIONS=mesa-vpu -> userpatches/extensions/mesa-vpu.sh
if [[ -d "${REPO_ROOT}/common/extensions" ]]; then
    mkdir -p "${BUILD}/userpatches/extensions"
    cp -a "${REPO_ROOT}/common/extensions/." "${BUILD}/userpatches/extensions/"
    purge_macos_metadata "${BUILD}/userpatches/extensions"
    echo "  synced common/extensions/ ($(find "${REPO_ROOT}/common/extensions" -type f ! -name '.DS_Store' ! -name '._*' | wc -l | tr -d ' ') files)"
fi

echo "==> 完成"

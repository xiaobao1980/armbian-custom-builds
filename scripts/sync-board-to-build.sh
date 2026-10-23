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

# 目录级合并拷贝: config/ patch/ userpatches/
sync_subdir() {
    local sub="$1"
    [[ -d "${SRC}/${sub}" ]] || return 0
    mkdir -p "${BUILD}/${sub}"
    cp -a "${SRC}/${sub}/." "${BUILD}/${sub}/"
    echo "  synced ${sub}/ ($(find "${SRC}/${sub}" -type f | wc -l | tr -d ' ') files)"
}

echo "==> 同步板卡 '${BOARD}' -> ${BUILD}"
sync_subdir config
sync_subdir patch
sync_subdir userpatches
echo "==> 完成"

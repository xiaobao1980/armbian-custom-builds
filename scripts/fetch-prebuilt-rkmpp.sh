#!/usr/bin/env bash
# =============================================================================
# fetch-prebuilt-rkmpp.sh — 拉取 rkmpp-stack 预编译 deb 到 build 树
#
# 背景：GitHub-hosted runner 只有 2 vCPU，x86 上还要 qemu 模拟 arm64。实测源码编译
#   mpp 17.5m + rkrga 1.5m + ffmpeg-rockchip 3h09m + mpv >1h，再加 kernel 1h52m
#   必然撞 GitHub Actions 6h 上限（run 40623907079 在 mpv 68/258 处被 cancel）。
#   预编译 deb 只有 11MB，dpkg 装完秒级，所以 CI 默认先把它取到扩展的 prebuilt/ 目录。
#
# ⚠️ 为什么必须按发行版选包（而不是"先下 noble 包再说"）：
#   common/extensions/rkmpp-mpv.sh 会读 deb 内 /usr/local/share/rkmpp-stack/build-info
#   的 DISTRO_CODENAME 与本次 RELEASE 比对，架构或发行版不匹配就把包丢弃、回退源码编译
#   —— 于是"拿错包"等于"没拿包"，6h 超时的风险原封不动回来。本脚本按【最终 RELEASE】
#   选 tag，所以调用方必须等参数解析完（args 步骤之后）再调它。
#
# 用法：scripts/fetch-prebuilt-rkmpp.sh <RELEASE>
#   需要 env: GH_REPO（仓库 slug，缺省用 github.repository 由调用方传入）、
#   GH_TOKEN（actions 令牌）。目标目录 = armbian-build/userpatches/extensions/rkmpp-mpv/prebuilt
#   任何失败都只告警不退出非零：扩展自带源码编译兜底，构建不该在这里中断。
# =============================================================================
set -uo pipefail

RELEASE="${1:-}"
DEST_DIR="${DEST_DIR:-armbian-build/userpatches/extensions/rkmpp-mpv/prebuilt}"
GH_REPO="${GH_REPO:-}"

# tag 清单：noble / trixie 各只有一条有效链（-1 从未发布，留着只为兼容历史）
case "${RELEASE}" in
	noble)  TAGS="rkmpp-stack-v0.41.0-noble-arm64" ;;
	trixie) TAGS="rkmpp-stack-v0.41.0-2 rkmpp-stack-v0.41.0-1" ;;
	*)
		echo "::notice::RELEASE=${RELEASE:-<空>} 没有对应的预编译包（只有 noble/trixie 出过），rkmpp-mpv 将走源码编译；bookworm/jammy 的可行性见 README 的硬解组合矩阵"
		exit 0
		;;
esac

if [ -z "${GH_REPO}" ]; then
	echo "::warning::GH_REPO 未设置，跳过预编译包拉取（扩展将回退源码编译）"
	exit 0
fi
if ! command -v gh >/dev/null 2>&1; then
	echo "::warning::无 gh CLI, rkmpp-mpv 扩展将回退源码编译"
	exit 0
fi

mkdir -p "${DEST_DIR}"
OK=0
for TAG in ${TAGS}; do
	if gh release download "${TAG}" --repo "${GH_REPO}" \
		--pattern 'rkmpp-stack_*_arm64.deb' --dir "${DEST_DIR}"; then
		echo "预编译包已就位（${TAG} / RELEASE=${RELEASE}）:"
		ls -lh "${DEST_DIR}"
		OK=1
		break
	fi
	echo "::notice::${TAG} 不可用，尝试下一个 tag"
done

if [ "${OK}" != "1" ]; then
	echo "::warning::预编译包下载失败, rkmpp-mpv 扩展将回退源码编译(可能撞 6h 上限)"
fi
exit 0

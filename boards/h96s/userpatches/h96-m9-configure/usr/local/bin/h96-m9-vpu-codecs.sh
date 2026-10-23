#!/bin/bash
# H96 MAX M9 (RK3576) — VPU 能力声明补全（供 Chromium / Firefox 的 V4L2 VDA/VEA 判定）
#
# 背景（2026-08-30 板上实测坐实）：
#   amazingfated PPA 的 rockchip-multimedia-config 提供 udev 规则
#     KERNEL=="mpp_service", MODE="0660", GROUP="video" \
#       RUN+="/usr/bin/create-chromium-vda-vea-devices.sh"
#   该脚本生成 /dev/video-dec0 与 /dev/video-enc0，浏览器据此决定是否启用硬解。
#
#   但它只按 /proc/device-tree/compatible 匹配两种模式：
#       *rk3588*  -> codecs=VP8:VP9:H.264:H.265:AV1  7680x4320
#       *rk356*)  -> codecs=VP8:VP9:H.264:H.265      3840x2160
#       *)        -> 只 echo "dec"                   ← 无 codecs 行
#   本板 compatible 是 "h96,h96-max-m9" + "rockchip,rk3576"，两个分支都不匹配，
#   落进 `*` 兜底 → /dev/video-dec0 内容只有 4 字节的 "dec"。
#   后果：Chromium/Firefox 认为该设备不支持任何编码格式，浏览器硬解不启用
#   （gstreamer 直连 MPP 不受影响，照样能硬解；这里补的只是浏览器这条路径）。
#
# 本脚本按 RK3576 实测能力补齐，数值全部来自本机实测而非照抄 RK3588：
#   - H.264 / H.265：mpph264enc、mpph265enc、mppvideodec 实测通过，
#     且 7680x4320（8K）硬编硬解 rc=0，故分辨率上限定 8K。
#   - VP8 / VP9：rkvdec2 硬件支持。（gstreamer 裸流测试曾报 "no valid frames
#     found"，但用 vp9dec 软解做对照，同样报 Internal data stream error ——
#     是 vp9enc 裸输出缺容器导致，与硬件无关，不能据此判定不支持。）
#   - AV1：可用。RK3576 的 AV1 解码不是独立 IP，而是 RKVDEC 硬件 + MPP 里的
#     mpp_av1dec.c 承担（CONFIG_ROCKCHIP_MPP_AV1DEC=y），所以 DTS 里没有
#     独立的 av1d 节点、/proc/mpp_service/supports-device 也只列 RKVDEC 而
#     不列 AV1 —— 这两点都**不能**当作"AV1 不可用"的证据。
#     2026-08-30 板上实测坐实：ffmpeg -hwaccel rkmpp -c:v av1_rkmpp 解码成功，
#     Stream mapping 为 (av1 (av1_rkmpp) -> wrapped_avframe)，输出 nv12。
#     （更早一版脚本用 supports-device 里 grep 'av1' 决定是否声明，那会误判成
#      不支持、白白埋掉 AV1 硬解，已改为固定声明。）
#
# 权限：/dev/video-dec0 由内核/udev 以 root 创建，需与 PPA 规则保持一致
# （root:video 0660），否则 video 组用户（桌面会话）读不到。

set -u

DEC_NODE=/dev/video-dec0
ENC_NODE=/dev/video-enc0

# 等 mpp_service 就位——驱动 probe / udev 事件可能晚于本 service 启动
for _ in $(seq 1 40); do
	[[ -c /dev/mpp_service ]] && break
	sleep 0.5
done

dec_codecs="VP8:VP9:H.264:H.265:AV1"
enc_codecs="H.264:H.265"

# 固定声明（见顶部 AV1 一节）。不要改成"探测到才声明"：
# supports-device 只枚举独立 VPU 设备，AV1 挂在 RKVDEC 名下，探测必然漏掉。

{
	echo "type=dec"
	echo "codecs=${dec_codecs}"
	echo "max-width=7680"
	echo "max-height=4320"
} > "$DEC_NODE"

{
	echo "type=enc"
	echo "codecs=${enc_codecs}"
	echo "max-width=7680"
	echo "max-height=4320"
} > "$ENC_NODE"

for n in "$DEC_NODE" "$ENC_NODE"; do
	chown root:video "$n" 2>/dev/null || true
	chmod 0660 "$n" 2>/dev/null || true
done

exit 0

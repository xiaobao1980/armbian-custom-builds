#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# verify-img-wayland.sh — 镜像级校验（不烧卡）
#
# 目标：CI 产出的 Wayland 版 Armbian 镜像是否「默认带 rkmpp + mpv（含 wayland 后端）」，
#       且 rkmpp-mpv 扩展没有把 Wayland 会话强制改回 X11（WaylandEnable=false）。
#
# 适用主机：arm64 Linux（如 neardi-lz200 / 187），因为要 chroot 进 arm64 rootfs 跑 mpv 二进制。
# 用法：
#   sudo bash verify-img-wayland.sh <镜像路径|.img.xz|release-tag|http(s) URL>
#   例：
#     sudo bash verify-img-wayland.sh /tmp/Armbian-*-noble-*_gnome_desktop.img.xz
#     sudo bash verify-img-wayland.sh rkmpp-stack-v0.41.0-noble-arm64   # 仅作 tag 示例，不会下镜像
#  环境变量：
#     RKMPP_MPV_SESSION=wayland  预期会话（默认 wayland；校验 WaylandEnable 未被强制 false）
#     KEEP=1                     校验后保留解压的 .img（默认删临时文件）
#
# 返回值：0 = 关键项全过；非 0 = 有 FAIL
# -----------------------------------------------------------------------------
set -uo pipefail

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [ OK ] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }
chk()  { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi; }

EXPECT_SESSION="${RKMPP_MPV_SESSION:-wayland}"

cleanup() {
  # 卸载 chroot 绑定与分区挂载，释放 loop
  for m in dev proc sys tmp boot; do
    mountpoint -q "/mnt/img/root/$m" 2>/dev/null && umount -l "/mnt/img/root/$m" 2>/dev/null
  done
  mountpoint -q /mnt/img/root 2>/dev/null && umount -l /mnt/img/root 2>/dev/null
  mountpoint -q /mnt/img/boot 2>/dev/null && umount -l /mnt/img/boot 2>/dev/null
  [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null
  [ "${KEEP:-}" != "1" ] && [ -n "${IMG_TMP:-}" ] && [ -f "$IMG_TMP" ] && rm -f "$IMG_TMP"
  rm -rf /mnt/img 2>/dev/null
}
trap cleanup EXIT

ARG="${1:-}"
if [ -z "$ARG" ]; then
  echo "用法: sudo bash $0 <镜像.img/.img.xz | release-tag | http(s)URL>"; exit 2
fi

echo "======================================================================"
echo " Wayland 镜像 rkmpp+mpv 镜像级校验 (expect session=${EXPECT_SESSION})"
echo "======================================================================"

# ---- 1. 取得本地 .img 文件 ----
IMG=""
if [ -f "$ARG" ]; then
  IMG="$ARG"
elif [[ "$ARG" == http://* || "$ARG" == https://* ]]; then
  echo "--- 下载镜像 ---"
  mkdir -p /tmp/imgverify && IMG_TMP=/tmp/imgverify/dl.img.xz
  ( command -v curl >/dev/null && curl -fL "$ARG" -o "$IMG_TMP" ) \
    || ( command -v wget >/dev/null && wget -O "$IMG_TMP" "$ARG" ) \
    || { echo "下载失败: $ARG"; exit 3; }
  IMG="$IMG_TMP"
else
  # 当作 GitHub Release tag，拉取 *.img.xz
  echo "--- 从 Release 下载: $ARG ---"
  mkdir -p /tmp/imgverify
  gh release download "$ARG" --pattern '*.img.xz' --dir /tmp/imgverify 2>/dev/null \
    || { echo "gh release download 失败（需 gh 已登录且 tag 正确）"; exit 3; }
  IMG=$(ls -1 /tmp/imgverify/*.img.xz 2>/dev/null | head -1)
  [ -z "$IMG" ] && { echo "未在 release $ARG 找到 *.img.xz"; exit 3; }
fi

# ---- 2. 解压 .xz（如需）----
if [[ "$IMG" == *.img.xz ]]; then
  echo "--- 解压 $IMG ---"
  DST="${IMG%.xz}"
  if [ ! -f "$DST" ]; then xz -dc "$IMG" > "$DST" 2>/dev/null || unxz -k "$IMG"; fi
  IMG="$DST"
fi
echo "  镜像: $IMG ($(du -h "$IMG" | cut -f1))"

# ---- 3. loop 挂载 ----
LOOP=$(losetup -fP --show "$IMG") || { echo "losetup 失败"; exit 4; }
sleep 1
mkdir -p /mnt/img/boot /mnt/img/root
# p1=boot(vfat, 含 armbianEnv.txt)  p2=rootfs(ext4)；个别板 p1=rootfs，按 fstype 自适应
for p in p1 p2; do
  dev="${LOOP}${p}"
  t=$(blkid -o value -s TYPE "$dev" 2>/dev/null)
  if [ "$t" = "vfat" ] || [ "$t" = "ext4" ]; then
    if mountpoint -q /mnt/img/boot || [ -z "${BOOT_DEV:-}" ]; then :; fi
  fi
done
# 简化：先挂 p1→boot, p2→root；若 p1 非 vfat 则交换
if blkid -o value -s TYPE "${LOOP}p1" 2>/dev/null | grep -q vfat; then
  BOOT_DEV="${LOOP}p1"; ROOT_DEV="${LOOP}p2"
else
  BOOT_DEV="${LOOP}p2"; ROOT_DEV="${LOOP}p1"
fi
mount "$BOOT_DEV" /mnt/img/boot 2>/dev/null \
  || echo "  [WARN] boot 分区挂载失败（CMA 检查将跳过）"
mount "$ROOT_DEV" /mnt/img/root 2>/dev/null || { echo "rootfs 挂载失败"; exit 4; }

MPV=/mnt/img/root/usr/local/bin/mpv
echo "--- 1. mpv 二进制 ---"
if [ -x "$MPV" ]; then ok "镜像内含 rkmpp-mpv 自编译二进制: $MPV"; else bad "镜像内未找到 /usr/local/bin/mpv（rkmpp-mpv 未安装）"; fi

echo "--- 2. rkmpp 后端 (chroot mpv --hwdec=help) ---"
if [ -x "$MPV" ]; then
  mount --bind /dev  /mnt/img/root/dev  2>/dev/null
  mount --bind /proc /mnt/img/root/proc 2>/dev/null
  mount --bind /sys  /mnt/img/root/sys  2>/dev/null
  mount --bind /tmp  /mnt/img/root/tmp  2>/dev/null
  HN=$(chroot /mnt/img/root /usr/local/bin/mpv --hwdec=help 2>/dev/null | grep -c rkmpp)
  echo "  rkmpp 项数: $HN"
  [ "$HN" -ge 2 ] && ok "mpv 含原生 rkmpp 后端（$HN 项）" || bad "mpv 无 rkmpp 后端（$HN 项）"
  echo "--- 3. wayland 后端 (chroot mpv --vo=help) ---"
  VOUT=$(chroot /mnt/img/root /usr/local/bin/mpv --vo=help 2>/dev/null)
  echo "  vo 列表(节选): $(echo "$VOUT" | grep -iE 'wayland|dmabuf-wayland|gpu|x11' | tr '\n' ' ')"
  echo "$VOUT" | grep -qE 'dmabuf-wayland|wayland' \
    && ok "mpv 含 wayland 后端（vo=help 见 wayland/dmabuf-wayland）" \
    || bad "mpv 未见 wayland 后端（vo=help 未列 wayland）"
fi

echo "--- 4. Wayland 会话未被强制改回 X11 ---"
# 扩展只在 x11 会话写 WaylandEnable=false；wayland 会话应保持缺省（不写 / 写 true）
WEF=0
for f in /mnt/img/root/etc/gdm3/daemon.conf \
         /mnt/img/root/etc/lightdm/lightdm.conf.d/*.conf \
         /mnt/img/root/etc/lightdm/lightdm.conf \
         /mnt/img/root/lib/systemd/system/gdm.service \
         /mnt/img/root/etc/gdm3/custom.conf; do
  if [ -f "$f" ] && grep -rqE '^\s*WaylandEnable\s*=\s*false' "$f" 2>/dev/null; then
    echo "  [FAIL] $f 含 WaylandEnable=false（会话被改回 X11）"; WEF=1
  fi
done
if [ "$WEF" = "0" ]; then
  ok "未在任何显示管理器配置中找到 WaylandEnable=false（Wayland 会话保留）"
else
  bad "WaylandEnable=false 存在 —— 与 RKMPP_MPV_SESSION=wayland 预期不符"
fi

echo "--- 5. CMA=512M（4K 硬解前提，缺失仅告警）---"
AE=/mnt/img/boot/armbianEnv.txt
if [ -f "$AE" ]; then
  if grep -qE 'cma=512M' "$AE"; then ok "armbianEnv.txt 含 cma=512M"; else warn "armbianEnv.txt 未见 cma=512M（首次启动请用 set-cma.sh --apply 后 reboot）"; fi
else
  warn "未找到 $AE（boot 分区可能未挂载或布局不同）"
fi

echo "--- 6. ffmpeg-rockchip 隔离安装 ---"
FF=/mnt/img/root/usr/local/lib/ffmpeg-rkmpp/ffmpeg
if [ -x "$FF" ]; then
  N=$("$FF" -decoders 2>/dev/null | grep -c _rkmpp)
  echo "  rkmpp 解码器数: $N"
  [ "$N" -ge 8 ] && ok "ffmpeg-rockchip 含 rkmpp 解码器（$N 个）" || warn "ffmpeg rkmpp 解码器仅 $N 个"
else
  warn "未找到隔离 ffmpeg-rockchip ($FF)；mpv 可能走系统 libav（硬解仍可能可用但需复核）"
fi

echo "======================================================================"
echo " 结果：PASS=$PASS  FAIL=$FAIL  WARN=$WARN"
[ "$FAIL" -eq 0 ] && echo " ✅ Wayland 镜像默认带 rkmpp+mpv（含 wayland 后端）" || echo " ❌ 有关键失败项"
echo "======================================================================"
exit "$FAIL"

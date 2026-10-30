# rkmpp-health-check.sh — RK35xx 全栈只读体检

RK3566 / RK3568 / RK3576 / RK3588 + Armbian vendor BSP + X11 桌面环境下，
一次性核查 **rkmpp 硬解栈 / mpv / ffmpeg / chromium / 中文环境 / 4K 实测**，
输出 PASS/WARN/FAIL 汇总与明细。**纯只读，不改系统**（仅向 /tmp 写临时文件）。

> 与 `verify-rkmpp-image.sh` 的分工：
> - `rkmpp-health-check.sh` → **只读体检**，不需要 sudo，适合随时复查 / 验收 / CI
> - `verify-rkmpp-image.sh` → **校验 + 自愈**，需 sudo，会修 udev 权限、图标缓存、补配置

---

## 一、快速开始

```bash
# 拷到板上（任选其一）
scp rkmpp-health-check.sh xiaobao@<板IP>:/tmp/
# 或用 base64 传输（scp 偶发不落地时更可靠）
printf '%s' '<base64>' | base64 -d > /tmp/rkmpp-health-check.sh

# 全量体检（含 4K 实播，自动搜索 /home/*/视频、Videos、/root、/tmp 下 >100M 的 mp4/mkv）
bash /tmp/rkmpp-health-check.sh

# 只看静态项（不播放，秒级完成）
bash /tmp/rkmpp-health-check.sh --no-play

# 指定测试片（可重复，建议真实高码率 4K 片源）
bash /tmp/rkmpp-health-check.sh --file /home/xiaobao/视频/4K-Chimei-inn-60mbps.mp4

# 额外输出 JSON 汇总（便于 CI / 批量采集）
bash /tmp/rkmpp-health-check.sh --json
```

退出码：`0` = 无 FAIL；`1` = 存在 FAIL；`2` = 环境不适用（非 arm64 / 非 RK 平台）。

---

## 二、检测分组（12 段）

| 段 | 内容 | 关键基线 |
|---|---|---|
| A | 平台与系统身份 | `aarch64` + 内核含 `vendor`/`rk35` + compatible 非 EVB |
| B | 镜像版本线索 | `/etc/armbian-release` 的 `BOARD` / `armbianEnv.txt` 的 `fdtfile` |
| C | 桌面会话 | `Xorg :0` 在跑（Wayland 会告警：应改用 mesa-vpu） |
| D | CMA 连续内存 | **`CmaTotal ≥ 524288 kB`（512M）** |
| E | VPU/RGA/DRM 节点 | `/dev/mpp_service`、`/dev/rga`、`/dev/dri/renderD128` |
| F | rkmpp 用户态库 | `librockchip_mpp`、`librga`、`ld.so.cache` 登记 |
| G | mpv | **`mpv --hwdec=help` 中 rkmpp 计数 = 20**；链接到 `ffmpeg-rkmpp` |
| H | ffmpeg | **`-decoders` 中 `_rkmpp` 计数 = 10**；`-hwaccels` 含 rkmpp |
| I | 浏览器 | chromium / firefox 是否存在 |
| J | 中文环境 | `LANG=zh_CN`、中文字体数、fcitx5/ibus、`*_IM_MODULE` |
| K | rkmpp-stack 元数据 | `/usr/local/share/rkmpp-stack/build-info` |
| L | **4K 实测** | `Using hardware decoding (rkmpp)` + `VO: [gpu] ... drm_prime[nv12]` |

---

## 三、判据说明

**硬解合格的铁证**（L 段）：

```
Using hardware decoding (rkmpp).
VO: [gpu] 3840x2160 drm_prime[nv12]
```

- `drm_prime[nv12]` = **零拷贝**（DMA-BUF 直通），PASS
- 只有 rkmpp 但 VO 不是 `drm_prime` = 走 copy 回退，WARN
- 无 `Using hardware decoding` 行 = 回退软解，FAIL

⚠️ 两个必须避免的踩坑：
1. **不要用 `--vo=null` 测硬解** —— vo=null 不经过 hwdec，会得出"软硬解一样快"的假结论
2. **合成测试片（testsrc2）无判据价值** —— 软解也能满帧，必须用真实高码率 4K 片

脚本已内置这两条约束。

---

## 四、常见 FAIL 处置

| FAIL 项 | 根因 | 处置 |
|---|---|---|
| `librockchip_mpp 缺失` | rkmpp-stack 未安装 | `sudo apt-get install -y ./rkmpp-stack_*_arm64.deb` 或跑 `install-rkmpp-stack.sh` |
| `mpv 无 rkmpp 后端` | 编译时缺 `libdisplay-info-dev`（meson `features['drm']` 不成立，`hwdec_drmprime.c` 未编译） | 重编，见 MEMORY 坑位 1 |
| `mpv 链接到系统 libavcodec` | `ld.so.conf.d/99-ffmpeg-rockchip.conf` 缺失或 RUNPATH 被覆盖 | 检查该文件是否含 `/usr/local/lib/ffmpeg-rkmpp` |
| `CmaTotal 低于 512M` | `armbianEnv.txt` 缺 `cma=512M` | 用 `set-cma.sh --apply` 后 reboot |
| `/dev/mpp_service 缺失` | 内核非 vendor BSP / 未启用 mpp_service | 换 vendor 内核 |
| `无任何浏览器` | 镜像未装（Armbian xfce mid 档默认不带） | `apt-get install -y chromium` 或写进 `customize-image.sh` |
| `无任何输入法框架` | 同上 | `apt-get install -y fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3` |
| `中文字体仅 1 个` | 只有 Droid Sans Fallback 兜底 | `apt-get install -y fonts-noto-cjk fonts-wqy-zenhei` |

---

## 五、已规避的环境坑

| 坑 | 脚本对策 |
|---|---|
| 中文 locale 下 `apt-cache` 输出"候选："而非 `Candidate:` | 用 `LC_ALL=C` 强制英文 |
| 镜像精简掉 `ldconfig` 命令 | 回退 `grep -a /etc/ld.so.cache` 二进制核查 |
| root 无 X MIT cookie，mpv 报 `Failed initializing GPU context` | 自动 `runuser` 切到带 `.Xauthority` 的桌面用户 |
| `grep -q` + `pipefail` 因 SIGPIPE 误报 | 全脚本不开 `pipefail`，一律落文件再 `grep -c` |
| `libavcodec` 的 NEEDED 是 `librockchip_mpp.so.1`，磁盘只见 `.so.0` | 打印完整 SONAME 链，说明 `.so.1 → .so.0` 软链属正常 |
| `bash` nounset 下空数组展开报 unbound | 用 `${arr[@]+"${arr[@]}"}` 写法 |

---

## 六、版本

- v1.0 — 12 段体检、PASS/WARN/FAIL 汇总、`--no-play` / `--file` / `--json` 参数、
  root 自动切桌面用户、i18n 与 ldconfig 缺失兼容。已在 RK3576（neardi-lz200 / trixie / X11）
  实测：PASS 24 / WARN 3 / FAIL 2，双片 4K 零拷贝硬解通过。

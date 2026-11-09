# RK35xx 内核补丁集统一：冲突评估报告

| 项 | 值 |
|---|---|
| 日期 | 2026-11-09 |
| 评估对象 | 把三块 rk35xx vendor 板的内核补丁合并成一份公共补丁集，供一次编译产出全板共享 debs |
| 基线提交 | `9881120`（本仓 main） |
| 方法 | 静态解析 13 个 `.patch` 的 `---/+++` 与 `@@` 头，构建「路径 → 补丁」映射并比对 hunk 旧行区间；交叉核对上游 `armbian/build` 与 `linux-rockchip` 源码 |
| 局限 | **未在任何真实内核源码树上执行 `git apply`**。本报告只做静态冲突判定与上游机制推演，第 6 节给出必须补做的实测步骤 |

## 0. 结论（先说结果）

**可以做，但「合并补丁」只解决了一半；不先统一 `.config`，合并后仍会得到至少两份 kernel 构件，达不到省一次编译的目的。**

- 补丁文本层面：**0 个新建文件重名冲突，0 个 hunk 旧行区间重叠**。13 个补丁共触碰 140 条路径，只有 3 条被多个补丁触碰，且都不重叠。真正的麻烦来自**机制冲突**（DTS/Makefile 的两套引入方式、`0000.patching_config.yaml` 全局生效）和**顺序敏感性**。
- 构件层面：`kernel-rk35xx-vendor` 的 `artifact_version` 由 8 个部分组成，其中 `P`（补丁集哈希）当前三板不同，`C`（.config 哈希）也因 neardi 独占 `LINUXCONFIG` 而不同。**只合并补丁集，`C` 仍不同 → 依然要编两次。**
- 最大风险不是 apply 失败，而是**合流后任一板的 DTS 编不过会拖垮整条共享构建**，且改动任意一个板的补丁会让所有板的 kernel 哈希失效、全部重编。
- 结论分级：**架构可行 / 需 2 个前置整改 / 建议分 5 阶段推进，不要一次性合并 13 个补丁。**

---

## 1. 评估范围

| 板卡 | BOARDFAMILY | LINUXFAMILY | BRANCH | LINUXCONFIG | kernel 补丁 | 是否纳入合并 |
|---|---|---|---|---|---|---|
| `neardi-lz200` | `rk35xx` | `rk35xx` | vendor | `linux-neardi-lz200-rk3576`（自定义 67 KB） | 7 个 `.patch` + 无 yaml | ✅ |
| `h96s`（BOARD=h96-m9） | `rk35xx` | `rk35xx` | vendor | 未设 → 框架默认 | 2 个 `.patch` | ✅ |
| `am60-sa12` | `rockchip-rk3588` | **`rk35xx`** | vendor | 未设 → 框架默认 | 4 个 `.patch` + `0000.patching_config.yaml` + `dt/*.dts` | ✅ |
| `aio-3288c` | `rockchip` | 不同 | **edge**（6.18） | 未设 | 0 | ❌ **排除** |

两条容易踩错的事实：

1. `am60` 虽是 `BOARDFAMILY=rockchip-rk3588`，但上游 `config/sources/families/rockchip-rk3588.conf:25` 明确写 `LINUXFAMILY=rk35xx` → 三板的 kernel 构件名同为 `kernel-rk35xx-vendor`（`artifact-kernel.sh:288`），**具备共享前提**。
2. 三板 vendor 分支的 `KERNELBRANCH='branch:rk-6.1-rkr7.2'`、`KERNELPATCHDIR='rk35xx-vendor-6.1'` 都由 `config/sources/families/include/rockchip_vendor_common.inc:16,26-27` 统一给出 → 补丁目录名一致，合并会直接影响全部三板。
3. `aio-3288c` 是 `ARCH=armhf` / `BRANCH=edge` / 另一个内核源，补丁集与三板毫无公共基座，**必须留在板级目录**。

---

## 2. 决定性发现：能不能共享，看 8 个哈希分量

上游 `artifact-kernel.sh:186-196` 定义 `artifact_version_parts = S / D / P / C / H / HK / V / B`，`:240-244` 拼进版本字符串。逐项对照：

| 分量 | 来源 | 合并前是否一致 | 合并后 |
|---|---|---|---|
| `S` | 内核 git SHA1（`:79`、`:188`） | ✅ 同一 `rk-6.1-rkr7.2` | ✅（需 pin `build_ref` 与内核 SHA） |
| `D` | drivers patch hash（`EXTRAWIFI`，`:81-89`） | ✅ 家族级 `patch/kernel/` | ✅ |
| **`P`** | **整个 `${KERNELPATCHDIR}` 目录文件哈希**（`:95-102`） | ❌ 三板补丁集互不相同 | ✅ 合并后一致 |
| **`C`** | **实际使用的 `.config` 文件哈希**（`:111-117`） | ❌ **neardi 用 67 KB 自定义，其余用框架默认** | ❌ **不整改就不一致** |
| `H` / `HK` | 扩展对 config 的修改 / hook 源码 | ✅ 扩展相同 | ✅ |
| `V` | 打包变量（`KERNEL_INSTALL_TYPE` 等，`:146` 起） | ✅ 家族级 | ✅ |
| `B` | 框架 bash 源码哈希 | ✅ 同一 armbian/build | ✅（需固定 `build_ref`） |

`.config` 的选择逻辑见上游 `lib/functions/compilation/kernel-config.sh:10-24`：优先 `userpatches/${LINUXCONFIG}.config`，其次 `config/kernel/${LINUXCONFIG}.config`，最后回退框架自带。而 `boards/neardi-lz200/config/boards/neardi-lz200.csc:13` 设了 `LINUXCONFIG='linux-neardi-lz200-rk3576'`，另两块板没设 → **`C` 必然分叉**。

> 这条比补丁冲突更根本：即使补丁集完全合并、DTS/Makefile 全部理顺，只要 neardi 还用专属 config，就会产生 `kernel-rk35xx-vendor` 的两个不同版本，各自编译一次。

顺带确认：`TABLE` 里 `CONFIG_SKW_BT=m`、`CONFIG_WLAN_VENDOR_SKW6316=m`、`CONFIG_SEEKWAVE_BSP_DRIVERS_V20=y` **只出现在 neardi 的 67 KB config 里**（第 548、605、897 行）。这正是「把 neardi WiFi/蓝牙驱动上移公共补丁集」时最需要处理的 config 差异。

---

## 3. 冲突清单

### 3.1 阻断级（不解决，合并无意义或必然出错）

| ID | 冲突 | 证据 | 影响 |
|---|---|---|---|
| **B1** | `LINUXCONFIG` 分叉 → `C` 哈希不同 | `neardi-lz200.csc:13`；`kernel-config.sh:14-23`；`artifact-kernel.sh:113-117` | 合并补丁后仍需编 2 份 kernel |
| **B2** | DTS 引入机制不统一：am60 靠 `0000.patching_config.yaml` 的 `dts-directories` + `auto-patch-dt-makefile`，h96s/neardi 靠手写 Makefile patch | `boards/am60-sa12/.../0000.patching_config.yaml`（`incremental: true`）；`h96s/9999...`；`neardi/0002...` | 合并后 yaml 对**所有板**生效，am60 的 `rk3588-am60-sa12.dts` 会被复制进 neardi/h96s 源码树并自动加进 Makefile；两套机制会在同一 Makefile 上叠加 |
| **B3** | `aio-3288c` 混入 | `aio-3288c.csc:6,9`；`build.env` `BRANCH=edge` | 完全不同的内核源与架构，公共补丁会直接 apply 失败 |

补充：上游 `patch/kernel/rk35xx-vendor-6.1/` 目前只有 `README.md`，**没有** `0000.patching_config.yaml` → am60 的 yaml 确实是板级独有，不是框架自带。另外 `neardi/0002` 的注释 `# Armbian: Incremental: assuming overlay targets are already in the Makefile` 来自内核源码里既有的注释，不能当作「neardi 也在用 auto-patcher」的证据。

### 3.2 高风险（apply 可能失败，或顺序一变就静默出错）

| ID | 冲突 | 证据 | 判定 |
|---|---|---|---|
| **H1** | `arch/arm64/boot/dts/rockchip/Makefile` 有三处写入来源 | `h96s/9999`：`@@ -1,1 +1,2 @@`，在第 1 行后插入 `rk3576-h96-m9s.dtb`；`neardi/0002`：`@@ -601,3 +601,4 @@`，在末尾追加 `rk3576-neardi-lz200-linux.dtb`；am60：yaml 自动重写 | 旧行区间 1–2 与 601–604 **不重叠**，按当前顺序可叠加；但 h96s 的 hunk 只有 1 行上下文、锚在文件第 1 行，是整份补丁集最脆弱的一点：内核 Makefile 首行一旦变化就 apply 失败 |
| **H2** | 合并后补丁按文件名字母序应用，顺序被重排 | 见第 5 节顺序表。两个 `0001-*` 并存（`neardi` 与 `h96s`）；`am60/001-hid-sony.patch` 会排到 `0009-*` 之后；`9999-*` 落到 neardi 所有补丁之后 | 顺序变化本身不冲突，但 H1 与 H3 都对顺序敏感；必须重新编号并固定顺序 |
| **H3** | `sound/soc/rockchip/rockchip_sai.c` 行号漂移 | `h96s/0001` 两个 hunk：`@@ -1230,6 +1230,18 @@`、`@@ -1246,6 +1258,15 @@` → **净增 21 行**；`neardi/0009`：`@@ -1345,7 +1345,7 @@` | 合并顺序下 h96s 先应用，neardi 的目标行会从 1345 漂到约 1366。两者上下文相隔约 100 行、不重叠，`git apply` 的 offset 容错大概率能命中；但这是全清单里唯一需要真实源码验证的「跨板同文件」组合 |

### 3.3 中风险（能 apply，需功能回归）

| ID | 冲突 | 证据 | 说明 |
|---|---|---|---|
| **M1** | `rockchip_sai.c` 语义叠加 | h96s 限制 `channels_max`（防 64 声道导致 bclk 98 MHz）；neardi 改 `rockchip_sai_reg_defaults[]` 的 pathsel 默认 SDO2 | 改同一驱动不同逻辑，需在 H96 M9 与 LZ200 上分别回归音频（HT5010 / ES8323 3.5 mm） |
| **M2** | Bluetooth 子系统耦合 | am60 `bluetooth-hci-quirk-...` 改 `drivers/bluetooth/hci_ldisc.c`、`include/net/bluetooth/hci.h`（在枚举中插入 `HCI_QUIRK_BROKEN_PARK_LINK_STATUS`）、`net/bluetooth/hci_sync.c`；neardi `0004` 改 `drivers/bluetooth/Kconfig`、`Makefile` 并新增 `skwbt/` | 路径不重叠，无文本冲突；但 `hci.h` 插入枚举值会改变后续编号，skwbt 驱动若按数值使用该枚举就会出问题（按符号名则安全）→ 需编译验证 |
| **M3** | 1.5 MB / 115 文件驱动进公共源码树 | `neardi/0004`：109 个新建文件 + 6 个 Kconfig/Makefile 注入，均无条件 `source "..."` | 好消息：`drivers/misc/seekwaveplatform_v20/Kconfig` 里 `menuconfig SEEKWAVE_BSP_DRIVERS_V20 ... default n`，`skwifi/Kconfig` 也需 `CFG80211`；非 neardi 板默认 config 不含 `=y` → **不会被编译**。代价是 109 个源码文件进所有板的内核源码树，且此后任何一处改动都会让三板 kernel 哈希一起失效 |
| **M4** | 三板 dtb 全部进 `linux-dtb-vendor-rk35xx` 包 | `artifact-kernel.sh:275`；三份 Makefile 追加 | 合并后一个 deb 会含三板全部 dtb。仓库已有 `rk35xx-chinese-desktop` 扩展里的 `_rk_cn_filter_dtb()` 在装配期裁剪，可复用；但需确认过滤白名单同时覆盖 `rk3576-neardi-lz200-linux.dtb`、`rk3576-h96-m9s.dtb`、`rk3588-am60-sa12.dtb` |
| **M5** | 任一板 DTS 编不过 → 全家族 kernel 构建失败 | `make dtbs` 会编译 Makefile 里所有 dtb | 这是共享化的固有代价，建议 CI 增加「一次 `make dtbs` 编全部三板 dtb」的门禁 |

### 3.4 低风险 / 已确认无冲突

- **新建文件重名：0**。109 个驱动文件、13 个 neardi DTS(I)、1 个 h96s DTS、1 个 am60 dts（yaml 复制）、1 个 kernel defconfig，路径两两不同。
- `sound/soc/codecs/es8323.c` 被 neardi `0007`（270–279）与 `0008`（237–249 / 292–300 / 349–368）触碰，区间不重叠，**当前 neardi 单独构建已通过**（r17 镜像成功），合并后不变。
- 其余 137 条路径均为单补丁独占：`hid-sony.c`、`es7243e_usr_cfg.h`、`dw-dp.c`、`rockchip_drm_vop2.c`、`hci_*.c`、`hci.h` 等。
- `.DS_Store`：`h96s`、`neardi` 的 `userpatches/kernel/` 下各有一个 6 KB 文件。`scripts/sync-board-to-build.sh:20-28` 的 `purge_macos_metadata()` 会在拷进构建树后删除 → 不进 `P` 哈希；但合并到公共目录时应直接排除，别把它带进去。
- `neardi/0003` 新建的 `arch/arm64/configs/rk3576_neardi_lz200_defconfig` 在四份板级 `.csc/.conf` 里**无任何引用**（`BOOTCONFIG` 指的是 U-Boot defconfig）。疑似历史遗留/本地手动编译用，合并时可保留但应确认后再决定去留。

---

## 4. 补丁清单（13 个）

| 板卡 | 补丁 | 大小 | 触碰 | NEW | MOD | 主要目标 |
|---|---|---:|---:|---:|---:|---|
| am60 | `001-hid-sony.patch` | 4.3 KB | 1 | 0 | 1 | `drivers/hid/hid-sony.c` |
| am60 | `0100-fix-es7243e-channels-max.patch` | 439 B | 1 | 0 | 1 | `sound/soc/codecs/es7243e_usr_cfg.h` |
| am60 | `bluetooth-hci-quirk-v6.1-v6.15.patch` | 2.5 KB | 3 | 0 | 3 | `hci_ldisc.c` / `hci.h` / `hci_sync.c` |
| am60 | `planb-typec-hdmib.patch` | 1.6 KB | 2 | 0 | 2 | `dw-dp.c` / `rockchip_drm_vop2.c` |
| h96s | `0001-rockchip-sai-cap-dai-channels-by-tdm-lanes.patch` | 2.7 KB | 1 | 0 | 1 | `rockchip_sai.c`（净 +21 行） |
| h96s | `9999-add-rk3576-h96-m9s-kernel-dts.patch` | 19 KB | 2 | 1 | 1 | DTS 782 行 + Makefile 首行 |
| neardi | `0001-add-rk3576-neardi-lz200-dtsi-files.patch` | 45 KB | 13 | 13 | 0 | 12 个 dtsi + 主 dts `rk3576-neardi-lz200-linux.dts` |
| neardi | `0002-add-rk3576-neardi-lz200-linux-dtb-to-makefile.patch` | 460 B | 1 | 0 | 1 | Makefile 601 行 |
| neardi | `0003-add-rk3576-neardi-lz200-kernel-defconfig.patch` | 19.7 KB | 1 | 1 | 0 | `arch/arm64/configs/rk3576_neardi_lz200_defconfig` |
| neardi | `0004-add-fd7352s-wifi-bt-drivers.patch` | **1.51 MB** | 115 | 109 | 6 | SeekWave WiFi/BT 驱动 + 6 处 Kconfig/Makefile 注入 |
| neardi | `0007-es8323-dac-stream-name.patch` | 2.4 KB | 1 | 0 | 1 | `es8323.c` DAPM stream name |
| neardi | `0008-es8323-out-always-on.patch` | 3.1 KB | 1 | 0 | 1 | `es8323.c` 输出常开 |
| neardi | `0009-sai-pathsel-default-sdo2.patch` | 1.5 KB | 1 | 0 | 1 | `rockchip_sai.c` 1345 行 |

合计 140 条唯一路径；其中 `drivers/` 116、`arch/arm64/boot/dts/rockchip/` 14、`sound/` 3、`net/` + `include/` 3。

---

## 5. 合并后的应用顺序（按文件名字母序推演）

| # | 文件 | 归属 | 与谁有关 |
|---|---|---|---|
| 1 | `0000.patching_config.yaml` | am60 | 全局配置，会作用于所有板（B2） |
| 2 | `0001-add-rk3576-neardi-lz200-dtsi-files.patch` | neardi | — |
| 3 | `0001-rockchip-sai-cap-dai-channels-by-tdm-lanes.patch` | h96s | H3：净增 21 行 |
| 4 | `0002-...dtb-to-makefile.patch` | neardi | H1：Makefile 601 行 |
| 5 | `0003-...kernel-defconfig.patch` | neardi | 疑似未使用 |
| 6 | `0004-...fd7352s-wifi-bt-drivers.patch` | neardi | M3：109 新文件 |
| 7–9 | `0007` / `0008` / `0009` | neardi | `0009` 受 H3 行号漂移 |
| 10 | `001-hid-sony.patch` | am60 | 因 `001-` > `0009-` 而后置 |
| 11 | `0100-fix-es7243e-channels-max.patch` | am60 | — |
| 12 | `9999-add-rk3576-h96-m9s-kernel-dts.patch` | h96s | H1：Makefile 第 1 行，此时才应用 |
| 13 | `bluetooth-hci-quirk-v6.1-v6.15.patch` | am60 | M2 |
| 14 | `planb-typec-hdmib.patch` | am60 | — |

建议合并时**统一重新编号**（如 `0100-` ~ `1400-`）并把 yaml 固定为 `0000-`，让顺序显式、可审计，而不是依赖文件名字母序。

---

## 6. 建议路线（本报告不执行任何改动）

| 阶段 | 动作 | 验收 |
|---|---|---|
| **P0 基线固化** | 记录当前 commit `9881120`；备份三板 `userpatches/kernel/rk35xx-vendor-6.1/` 与 `config/kernel/`；用 `reuse` 模式各跑一次并记下 debs 基线 run number | 三板现有镜像可复现 |
| **P1 统一 config（最难，先做）** | 把 neardi 的 67 KB config 与框架默认 `linux-rk35xx-vendor.config` 做 diff，逐项判断哪些是板专属（SeekWave 驱动、ES8323、SAI）、哪些可上移公共。目标是让三板 `LINUXCONFIG` 指向同一份文件，板专属开关改为扩展注入 `kernel_config_modifying_hashes` | `C` 哈希三板一致；三板音频/WiFi/BT 真机回归通过 |
| **P2 统一 DTS 引入机制** | 二选一：① 三板全部改用 `0000.patching_config.yaml` 的 `dts-directories` + `auto-patch-dt-makefile`，删掉 h96s/neardi 的手写 Makefile patch；② 三板全部改用手写 patch 并把 am60 的 dts 转成 patch。推荐 ①（上游已明确说「No more Makefile patching needed」） | 一份 Makefile 来源；三板 dtb 都能编出 |
| **P3 补丁集合并与重编号** | 新建 `common/kernel/rk35xx-vendor-6.1/`；`sync-board-to-build.sh` 增加公共目录拷贝（板级目录保留为覆盖层）；按第 5 节重编号；排除 `.DS_Store` | `P` 哈希三板一致 |
| **P4 编译回归** | 在真实 `linux-rockchip` `rk-6.1-rkr7.2` 源码上按顺序做 `git apply --check` 序列 + `make dtbs` 全量；再用 `fresh` 模式跑一次三板镜像构建 | 见下方命令 |
| **P5 独立构件流** | 新增 `build-kernel-uboot.yml`，产出 `kernel-rk35xx-vendor` debs 到固定 Release tag；四条镜像 workflow 预拉 debs 注入 `output/debs` | 三板跳过 kernel 编译 |

P4 必做的实测（静态报告无法替代）：

```bash
git clone --depth=1 -b rk-6.1-rkr7.2 https://github.com/armbian/linux-rockchip.git /tmp/lk
cd /tmp/lk
for p in $(ls /path/to/common/kernel/rk35xx-vendor-6.1/*.patch | sort); do
  git apply --check "$p" || { echo "FAIL(check): $p"; break; }
  git apply "$p" || { echo "FAIL(apply): $p"; break; }   # 序列验证必须真的落地
done
make ARCH=arm64 rockchip_defconfig && make ARCH=arm64 dtbs -j"$(nproc)"
```

---

## 7. 回滚方案

| 层级 | 手段 | 说明 |
|---|---|---|
| 文件 | 基线 commit `9881120`；合并只新增 `common/kernel/...` + `sync` 脚本一行 | 出问题时注释掉 sync 里的公共目录拷贝即可，板级目录原封不动，立即回到「每板各编一份」 |
| 单板 | 板级目录作为覆盖层保留 | 某块板不适配时，把该板排除出公共补丁集，不影响另外两板 |
| 构件 | 用 `9881120` 新增的 `cache_tag` | `kernel_uboot_mode=reuse` + `cache_tag=<合并前 run number>` 精确回退到合并前的 debs 基线；未命中会直接报错，不会静默用新构件 |
| 强制重建 | `kernel_uboot_mode=fresh` / `fresh-strict` | 不走历史 debs；`fresh-strict` 连 rootfs 与远程 OCI 一起禁用 |
| 镜像 | Release tag 按 run number 独立、不覆盖 | 合并前后镜像都在，可直接刷回 |

---

## 8. 待确认事项

1. `neardi/0003` 的 `rk3576_neardi_lz200_defconfig` 是否真的没被使用？若有外部脚本/本地编译流程引用，删它会影响那条流程。
2. `dts-directories` / `auto-patch-dt-makefile` 相对 `.patch` 应用的**确切先后顺序**需在真实构建日志里确认（本报告按 yaml 注释「patched-in」推断为 patch 之后）。
3. `0000.patching_config.yaml` 若上移公共目录，`dts-directories` 会否把 am60 的 dts 覆盖掉同名文件（注释写「later ones overwrite earlier ones」）——当前无同名，但后续加板需留意。
4. 统一 config 后，h96s 的 HT5010 / neardi 的 ES8323 / am60 的 Type-C DP 行为是否保持，需三板真机回归；上次联机核查时 `192.168.60.188` 离线，neardi 侧回归需先恢复板卡在线。
5. 收益量化：r17 实测 kernel 全量编译约 **31 min**；三板各编一次约 93 min/轮，共享后一次约 31 min，理论节省约 62 min/轮。代价是 P1 的统一 config 与每次补丁变更引发的「全家族一起重编」。

---

## 附录：上游依据（均为 `armbian/build` 主线文件）

| 结论 | 出处 |
|---|---|
| kernel 构件名是家族级 `kernel-${LINUXFAMILY}-${BRANCH}` | `lib/functions/artifacts/artifact-kernel.sh:288` |
| 版本 8 分量与 `P`/`C` 来源 | 同上 `:186-196`、`:95-102`、`:111-117`、`:240-244` |
| `.config` 选择优先级 | `lib/functions/compilation/kernel-config.sh:10-24` |
| U-Boot 构件名是板级 `uboot-${BOARD}-${BRANCH}`，哈希含 `BOOTCONFIG`/`DDR_BLOB`/`BL31_BLOB`/`BOOT_FDT_FILE` | `lib/functions/artifacts/artifact-uboot.sh:157` 及 `:108-130` |
| vendor 内核源 / 分支 / 补丁目录 | `config/sources/families/include/rockchip_vendor_common.inc:16,26-27` |
| `rockchip-rk3588` 家族 `LINUXFAMILY=rk35xx` | `config/sources/families/rockchip-rk3588.conf:25` |
| `ARTIFACT_IGNORE_CACHE=yes` 是全局开关（本地+远程全部绕过） | `lib/functions/artifacts/artifacts-obtain.sh:238-270` |
| 单板同步（各板补丁集互不干扰的根因） | 本仓 `scripts/sync-board-to-build.sh:31-38` |
| GHA 缓存不可变、primary key 命中不保存 | GitHub Actions 官方 dependency caching 文档 |

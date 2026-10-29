# Neardi LZ200 (RK3576) Armbian userpatches

基于项目目录内**之前已验证可启动**的配置文件生成，board 格式参考官方
`config/boards/armsom-sige5.csc`（同为 RK3576）。

## 使用方法

```bash
# 1. 整个 userpatches/ 目录拷贝（或软链）到 armbian/build/ 下
rsync -a userpatches/ /path/to/armbian/build/userpatches/

# 2. 构建（vendor 分支 = 6.1 BSP kernel）
./compile.sh neardi-lz200        # 自动 source userpatches/config-neardi-lz200.conf

# 或显式指定
./compile.sh BOARD=neardi-lz200 BRANCH=vendor RELEASE=noble BUILD_DESKTOP=yes
```

## 目录结构

```
userpatches/
├── config-neardi-lz200.conf                    # 构建预设（BOARD/BRANCH/RELEASE）
├── customize-image.sh                          # 镜像定制脚本（chroot 内执行）
├── config/
│   ├── boards/neardi-lz200.csc                 # 板级配置（含 WiFi/BT/首启脚本 hook）
│   └── kernel/linux-neardi-lz200-rk3576.config # 内核配置（LINUXCONFIG 对应）
├── kernel/rk35xx-vendor-6.1/                   # vendor 6.1 内核补丁（新增件，可干净套用）
│   ├── 0001-add-rk3576-neardi-lz200-dtsi-files.patch     # 13 个 neardi dts/dtsi（全新增）
│   ├── 0002-add-rk3576-neardi-lz200-linux-dtb-to-makefile.patch # DTB 注册（已重写锚点）
│   └── 0003-add-rk3576-neardi-lz200-kernel-defconfig.patch      # SDK defconfig（备用）
├── u-boot/legacy/u-boot-radxa-rk35xx/          # Radxa u-boot next-dev-v2024.10 补丁
│   └── 0001-add-neardi-lz200-uboot-support.patch # defconfig + u-boot dts（全新增）
├── neardi-lz200/
│   ├── wifi/         # FD7352S(SKW6316/SWT6652) WiFi 固件 13 个文件（csc 装入 /lib/firmware）
│   └── bluetooth/    # FD7352S BT 固件 3 个 nvbin（csc 装入 /lib/firmware）
└── overlay/          # customize-image.sh 可经 /tmp/overlay 访问的文件
```

## 与旧版文件的差异（本次修正）

| 项目 | 旧文件 | 新文件 | 原因 |
|------|--------|--------|------|
| kernel DTB 注册 patch | `0001-add-rk3576-neardi-lz200-dtb.patch`，锚点 `rk3576-nanopi-m5.dtb` | `0002-...-dtb-to-makefile.patch`，锚点 `rk3576-evb1-v10-linux.dtb` | nanopi-m5 行在当前 rk-6.1-rkr7.2 的 dts Makefile 中已不存在，旧 patch 会 hunk 失败（已在远端 rkr7.2 树核实） |
| u-boot 补丁 | 无（boot/ 下散文件） | `0001-add-neardi-lz200-uboot-support.patch` | Armbian rk35xx vendor 用 Radxa `next-dev-v2024.10`，BOOTCONFIG 指定的 `neardi-lz200-linux-rk3576_defconfig` 必须经补丁注入 |

## 已核实项（对照远端仓库）

- Radxa u-boot `next-dev-v2024.10`：`rk3576.dtsi`/`rk3576-u-boot.dtsi`/`dt-bindings/usb/pd.h` 均存在；
  其 rk3576 板（radxa-cm4-io）defconfig 与本项目 boot/ defconfig 同为 Rockchip BSP 风格
  （`USING_KERNEL_DTB_V2`、`TARGET_EVB_RK3576`、`make_fit_atf.sh`），可直接编译。
- `CONFIG_DEFAULT_DEVICE_TREE="rk3576-neardi-lz200-linux"` → 对应补丁内 dts 路径，无需改
  dts Makefile（BSP 树按 DEFAULT_DEVICE_TREE 构建，radxa 自家 rk3576 板同样未注册）。
- vendor kernel `rk-6.1-rkr7.2`：`rk3576-linux.dtsi`（linux.dts 依赖）存在；45K patch 全部为
  new-file hunk，可干净套用；`mipi-dsi-to-lvds.dtsi` 在 linux.dts 中已注释，缺失无影响。

## 注意事项

1. **仅支持 vendor 分支**：csc 的 `KERNEL_TARGET="vendor,edge"` 保留了原样，但本套补丁只覆盖
   `rk35xx-vendor-6.1`；构建 edge 会缺少 neardi dts/DTB 注册。如不需要 edge，建议把 csc 改为
   `KERNEL_TARGET="vendor"`。
2. kernel patch 中 `rk3576-neardi-lz200-linux.dts` 的 model 字符串仍是
   "Rockchip RK3576 EVB1 V10 Board"（历史遗留，不影响启动，BOOT_FDT_FILE 已显式指定 dtb）。
3. WiFi/BT 固件已包含（源自 `reference/vendor-sdk/neardi-lz200.zip` 解压，md5 校验一致）：
   wifi 13 个 + bluetooth 3 个 nvbin，构建时由 csc 的
   `post_family_tweaks__neardi_lz200_wireless` 复制进镜像 `/lib/firmware`。
4. 补丁基于 Armbian 当前 main 框架文档（userpatches/kernel/<KERNELPATCHDIR>、
   userpatches/u-boot/<BOOTPATCHDIR> 机制）；vendor 的 KERNELPATCHDIR=`rk35xx-vendor-6.1`、
   BOOTPATCHDIR=`legacy/u-boot-radxa-rk35xx`，均已在 `config/sources/families/rk35xx.conf`
   及其 include 中核实。
5. **`customize-image.sh` 是整个 userpatches 目录全局唯一的文件，不按板卡区分**
   （框架 `lib/functions/rootfs/customize.sh` 直接读 `$USERPATCHES_PATH/customize-image.sh`）。
   脚本开头已按 `$BOARD != neardi-lz200` 提前 `exit 0`，因此与 H96 MAX M9 / CM3588 /
   K50S / AM60 等共用同一 userpatches 不会污染其它板卡镜像。
   注意**不能**按 `LINUXFAMILY` 守卫——`rk35xx` 被 RK3566/RK3568/RK3576/RK3588 多板共用。
6. **本版 Armbian 不会自动拷贝 `overlay/`**：只 `mount -o bind,ro` 到 `/tmp/overlay`，
   脚本跑完即 `umount`。所以 overlay 里文件进入镜像的唯一路径是 `customize-image.sh`
   中的显式 `install`；同理 overlay 内文件的权限位不会自动带入，
   必须用 `install -Dm755`（脚本）/ `-Dm644`（unit、配置）显式设定。

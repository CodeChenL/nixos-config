# Xiaomi Elish NixOS Bring-up

`ChenXiaomiElish` 面向 Xiaomi Pad 5 Pro（代号 `elish`，SM8250），沿用已在
Armbian 上验证的 Qualcomm ABL 启动方式。构建过程只生成文件，不会读取或写入
`/dev`。系统成功进入 multi-user 后，`qbootctl -m` 会更新当前 slot 的"启动成功"
元数据，但不会写入 boot image。

> 本文档记录已确认的源码与本地工件状态，并明确任何写入 `/dev/sda35`、UFS、
> 重分区、设备重启等动作都需要单独授权。一次性人工部署的边界在本节末尾
> 单独列出；不构成本文档对具体分区目标的背书。

## 当前 HIL 现状

`boot-elish.img` 与 `.omo/artifacts/elish-edk2-allocator-fix-20260904/`
下其它文件（`SM8250_UEFI.fd`、debug ELF、`SHA256SUMS` 等）的字节、
长度与 SHA-256 仅证明该候选构建产物的 identity 与 hash，不构成任何
设备运行时证据。下面四条"实机观察"是用户在**当前会话**中提供给
本 runbook 维护者的报告；它们**尚未**持久化进
`.omo/artifacts/elish-edk2-allocator-fix-20260904/` 下任何 handoff
或 manual-QA 工件，因此本 runbook 与工件目录都不证明这些观察，
也不应把它们当成"旧 handoff/manual-QA 已经记录过的旧事实"来引用：

- 已越过原始的 `SimpleInitMain+0x1e3374 -> l_alloc -> free(NULL)`
  同步异常点（用户当前会话报告）；
- 已进入 EDK2 自定义 UI 并枚举到 Elish 的 UFS 设备（用户当前会话
  报告）；
- 但专用 `esp` 分区仍是空的，没有有效 EFI 文件被安装（用户当前
  会话报告）；
- 当前 EDK2 自定义 UI 上没有 USB HID 键盘可用，用户只能用方向键
  与电源键交互（用户当前会话报告）。

任何把"本地工件 hash 正确"读成"以上四条已被本 runbook 持久化"、
"以上四条已写进旧 handoff/manual-QA"或"以上四条属于历史证据"的
解读都是错的；该工件目录只能证明 `boot-elish.img` 的本地字节
身份，对实机行为不作任何承诺，也不构成对用户在当前会话中口头
报告内容的认证。

ESP/UEFI BDS/systemd-boot/NixOS 启动、`/boot` 持久切换、persistent
generation switching、`qbootctl` slot metadata 写回等阶段在本仓库中仍标
记为 PENDING，任何把"本地静态验证"读成"设备 HIL PASS"的表述都是错的。
本文档不声称这些阶段已经通过。

## 已确认的 ESP 分区

`fastboot getvar partition-size:esp` 在该设备上返回 `0x3BA00000`，对应
`1000341504` 字节、`954` MiB、`1953792` 个 512 字节扇区。Linux 侧该
分区对应 `/dev/sda35`。仓库曾经的注释把 `/dev/sda35` 写成"不是可挂载的
EFI 分区"，那是远期 ABL-only 阶段的模型；现在的状态是：该分区已经在
GPT 中被预留，专门留给 NixOS 标准 EFI 启动使用，但当前仍**为空**。
不要在没有明确写到 `/dev/sda35` 的授权情况下写入任何字节。

## 工件类别

本次交付引入三类产物，彼此不能互换：

1. **EDK2 启动容器**：`boot-elish.img`（由外部 EDK2 allocator 修复
   pipeline 产出，存放在 `.omo/artifacts/...`，不在本次 Nix bundle 之内）。
   本文档不复制也不重新构建；用户需要参考同目录 `OPENCODE-HANDOFF.md`。
2. **EFI 系统分区（ESP）原始镜像**：`ChenXiaomiElish-esp.fat32`，由
   `nix build .#packages.aarch64-linux.chen-xiaomi-elish-bundle` 产出，
   长度恰好为 `1000341504` 字节，分区卷标 `NIXOS_ESP`，固定 volume id
   `454c4953`，512 字节扇区，无 GPT/MBR 包装，无压缩。该镜像同时安装
   `EFI/systemd/systemd-bootaa64.efi` 与 `EFI/BOOT/BOOTAA64.EFI`。
3. **已有保留件**：未压缩 `ChenXiaomiElish-rootfs.btrfs`（卷标
   `NIXOS_ROOT`），以及四个 ABL 直启恢复镜像 `boot-a-boe.img`、
   `boot-a-csot.img`、`boot-b-boe.img`、`boot-b-csot.img`。

bundle 内同时包含一份 `BUILD-INFO.txt`（记录 ESP 字节数、卷标、CSOT DTB
路径、systemd-boot 源路径、`system.build.toplevel` 与 `boot.json`
identity、`Flashing performed: no`），以及一份覆盖以上 7 个 payload 与
元数据条目的 `SHA256SUMS`。

## 面板与 DTB

`ChenXiaomiElish` 的 EFI 启动路径只针对 CSOT 面板：从 `boot.json`
派生的初始条目使用 `qcom/sm8250-xiaomi-elish-csot.dtb`。BOE DTB 仍在
保留的 ABL 镜像里作为四档直启恢复选项之一，不会被 ESP 启动路径选中。

如需再次确认面板类型，再走 Armbian：

```sh
tr -d '\0' </sys/firmware/devicetree/base/model
```

输出 `Xiaomi Mi Pad 5 Pro (CSOT)` 时才能按本文档执行；其他面板需要回
到 ABL 直启路径或重写 ESP 启动条目，且不在本 runbook 的覆盖范围。

## 构建

在安装了 Nix 且启用 flakes 的 x86_64 Linux 构建机上执行（当前 ESP 与
rootfs 镜像都使用宿主机原生 `mkfs.vfat`/`mkfs.btrfs` 与 user namespace，
不能在 QEMU 下运行 aarch64 构建工具）：

```sh
nix flake check --no-build --all-systems
nix build .#nixosConfigurations.ChenXiaomiElish.config.system.build.toplevel --dry-run
nix build .#packages.aarch64-linux.chen-xiaomi-elish-bundle
```

bundle 把 Btrfs rootfs、新 ESP FAT32 镜像与四个 ABL 恢复镜像同时放在
同一输出目录里（编排脚本使用 x86_64 原生工具构建并链接）：

```text
BUILD-INFO.txt
ChenXiaomiElish-esp.fat32
ChenXiaomiElish-rootfs.btrfs
SHA256SUMS
boot-a-boe.img
boot-a-csot.img
boot-b-boe.img
boot-b-csot.img
```

写卡前在本地对照预期字节数与校验和：

```sh
(cd result && sha256sum -c SHA256SUMS)
stat -Lc '%n %s' result/ChenXiaomiElish-esp.fat32
file -L result/ChenXiaomiElish-esp.fat32
blkid -p -s TYPE -o value result/ChenXiaomiElish-esp.fat32
blkid -p -s LABEL -o value result/ChenXiaomiElish-esp.fat32
fsck.vfat -vn result/ChenXiaomiElish-esp.fat32
blkid result/ChenXiaomiElish-rootfs.btrfs
btrfs check --readonly result/ChenXiaomiElish-rootfs.btrfs
unpack_bootimg --boot_img result/boot-a-csot.img --out /tmp/elish-boot
```

`stat` 报告 `ChenXiaomiElish-esp.fat32` 长度为 `1000341504`；分别以
`-s TYPE` 和 `-s LABEL` 调用 `blkid -p -o value` 应分别报告
`vfat` 与 `NIXOS_ESP`；`fsck.vfat -vn` 必须退出 0；`mtools`
（`mdir -i` / `mcopy -i`）能列出 `EFI/systemd/`、`EFI/BOOT/`、`loader/`、
`EFI/nixos/`。`boot-elish.img` 的 SHA-256 校验在
`.omo/artifacts/elish-edk2-allocator-fix-20260904/SHA256SUMS` 里独立
核对，不混入本次 bundle 的 `SHA256SUMS`。

## 首次启动行为（待 HIL 验证）

文末的 HIL 边界单列说明本节描述的是契约行为，而不是已观测结果。

图形界面使用 SDDM/Wayland 与 KDE Plasma 6，禁用自动登录；需要在 SDDM
中手动认证登录 `chen`，不会在启动后直接进入该用户的桌面。

USB NCM 恢复链路保留 `172.18.42.0/24`：平板 `usb0` 使用
`172.18.42.1/24`，连接端通过 DHCP 获取唯一租约 `172.18.42.2`（1 小时）。
DHCP 显式抑制默认网关与 DNS 服务器选项，不把平板宣告为路由器或 DNS
服务器，也不应改变连接端现有的默认路由或 DNS 设置。此链路仅用于本地
恢复访问，例如 `ssh chen@172.18.42.1`，不提供互联网共享。

首次从 `esp` 启动时使用 AArch64 fallback 路径：

```text
Qualcomm ABL
  -> Android boot image / BootShim
  -> edk2-msm SM8250 UEFI
  -> UFS GPT + FAT ESP
  -> EFI/BOOT/BOOTAA64.EFI (systemd-boot fallback)
  -> NixOS kernel + initrd + CSOT DTB
  -> nixos-rebuild switch --target-host 后无需重刷固件
```

systemd-boot 配置为：3 秒自动选择默认值（systemd-boot 在该设备
上的按键/输入行为尚未经 HIL 验证；首次启动必须不依赖菜单交互，
故默认不能依赖编辑菜单）、菜单编辑关闭
(`editor = false`)、控制台模式保持 (`consoleMode = "keep"`)、不写
EFI 变量 (`canTouchEfiVariables = false`)、最多保留两个 NixOS
generation (`configurationLimit = 2`)。挂载时按卷标 `NIXOS_ESP` 把
ESP 显式挂在 `/boot`，挂载选项 `nofail`、`umask=0077`，防止 ESP 损坏
时把系统挡在 rootfs 之前。EFI 变量存储不会被本配置改动。

后续 `nixos-rebuild --target-host ... switch` 在 ESP 实际挂载后会更新
`loader/entries/`、`EFI/nixos/` 与 `loader/loader.conf`，但只在 ESP 已
挂载时进行；ESP 离线时复用现有 rootfs 不会破坏运行状态。

## 可配置参数

`hosts/ChenXiaomiElish/abl.nix` 的 `hardware.xiaomiElish.abl.extraKernelArgs`
用于附加内核参数。ABL 直启 slot suffix 由四个输出文件名固定
（`boot-a-*` / `boot-b-*`），不再由一个全局选项控制。ESP 启动路径不写
入 `slot_suffix`，因为 `qbootctl -m` 仍然用 `boot_a`/`boot_b` slot
metadata 来保持当前 ABL 行为；不能在 ESP 入口里擅自加 `slot_suffix=_a`
或 `_b`，那会让 active-slot 回退与 `qbootctl` 状态机脱钩。

`hosts/ChenXiaomiElish/rootfs.nix` 的 `hardware.xiaomiElish.rootfs.uuid`
控制 Btrfs UUID。initrd 通过 `root=fstab` 读取系统配置，并按固定卷标
`NIXOS_ROOT` 挂载根文件系统；修改 UUID 不需要重建 boot cmdline。

`hosts/ChenXiaomiElish/efi.nix` 提供 ESP 镜像与 systemd-boot 配置，
与 rootfs 和 bundle 模块共享同一 NixOS closure。

## 部署边界

本阶段仍然不提供 `fastboot flash`、`dd`、disko 或任意重分区命令。
部署前必须先确认并备份：

1. 实机面板类型（EFI 路径只对 CSOT）。
2. 当前活动 slot（A 还是 B）以及可安全测试的 boot slot。
3. ESP 分区的容量与现有内容（`fastboot getvar partition-size:esp`、
   `fastboot getvar partition-type:esp`）。
4. rootfs 实际对应的分区名称、容量和现有数据。
5. boot 与 rootfs 分区的完整备份及恢复路径，包括回到 Android 的
   最简步骤。

rootfs 分区容量必须大于生成的镜像；首次启动会把 Btrfs 文件系统扩展
到该分区的完整容量。

确认这些映射后，再为该设备记录一次性的人工部署步骤；不要根据
Android 设备的通用分区名称猜测写入目标。

`qbootctl -m` 单元保留：当 multi-user 启动成功时它仅写回 ABL 的 slot
metadata，不动 boot image。它仍是 ESP 启动的 active-slot 兜底，不能
在接入 systemd-boot 后被禁用或重排；任何对 `qbootctl` 的修改都属于
跨域行为，请在单独会话里评估。

实机 user-run 写盘命令（无论是 ESP 写盘目标、rootfs 写盘目标、当前
与目标 slot 的关系、`set_active` 还是 reboot 步骤）在 rootfs 实际对应
分区、当前活动 slot、可恢复路径这三项被分别确认之前，本 runbook 不再
给出具体命令；上述清单一旦落定，应作为该设备的一次性人工操作记录，
而不是本 runbook 的一部分。本文档作者与 agent 执行都没有写过
`/dev/sda35` 上的任何字节，也未授权 agent 在任何后续会话里直接执行
写盘命令；任何把"占位示例"或"已经写盘"读成"agent 已执行"的解读都
越权。

`nixos-rebuild --target-host ... switch` 只更新正在运行的 system
generation；当 ESP 真正挂载在 `/boot` 之后，它会写入 systemd-boot 的
loader entries 与 NixOS kernel/initrd/DTB；在此之前，若要修复在重启
后仍生效，必须经由用户一次性写盘把 ABL 直启镜像放回 boot slot，而
不是依赖 ESP 启动路径。

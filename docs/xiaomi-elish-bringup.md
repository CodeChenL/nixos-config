# Xiaomi Elish NixOS Bring-up

`ChenXiaomiElish` 面向 Xiaomi Pad 5 Pro（代号 `elish`，SM8250），沿用已在
Armbian 上验证的 Qualcomm ABL 启动方式。构建过程只生成文件，不会读取或写入
`/dev`。系统成功进入 multi-user 后，`qbootctl -m` 会更新当前 slot 的“启动成功”
元数据，但不会写入 boot image。

## 已实现范围

- 内核固定到 postmarketOS SM8250 Linux 7.2 commit
  `71f4068cb254730bcf334cde9bdd6ca183e4fcd0`。
- 内核配置派生自已验证的 Armbian `linux-sm8250-edge.config`，并补充 Nix/Linux 7.2
  所需的 ASLR 与 Zstandard 固件解压选项。
- 同时构建 BOE 与 CSOT 两种 DTB，并包含触摸、面板和关键 Qualcomm 固件。
- 生成独立 Btrfs rootfs，卷标为 `NIXOS_ROOT`。
- 为 BOE/CSOT 与 slot A/B 生成四个明确命名的 boot image。
- 首次启动使用最小 Home Manager 配置；`chen` 复用本仓库公共主机配置中的密码，
  同时保留仓库中的 SSH 公钥，root SSH 登录仍禁用。
- 内建屏幕显示旋转后的 DRM framebuffer 控制台、systemd 状态和 `tty1` 登录提示。
- USB OTG 提供 NCM 网卡；电脑通过 DHCP 获得 `172.16.42.2/24`，平板固定为
  `172.16.42.1`，SSH 端口只对该接口开放。
- `qbootctl` 在 `boot-complete.target` 后标记当前 slot 启动成功。

音频 UCM、Hexagon RPC、蓝牙固定 MAC 和运行时自动更新 boot image 尚未移植。
这些功能不属于根文件系统挂载的阻塞项。

## 确认面板

在仍可工作的 Armbian 系统中执行：

```sh
tr -d '\0' </sys/firmware/devicetree/base/model
```

- `Xiaomi Mi Pad 5 Pro (BOE)` 使用名称中带 `boe` 的镜像。
- `Xiaomi Mi Pad 5 Pro (CSOT)` 使用名称中带 `csot` 的镜像。
- 写入 `boot_a` 时必须使用 `boot-a-*`；写入 `boot_b` 时必须使用 `boot-b-*`。

## 构建

在安装了 Nix 且启用 flakes 的 aarch64 构建机上执行：

```sh
nix flake check --no-build --all-systems
nix build .#nixosConfigurations.ChenXiaomiElish.config.system.build.toplevel --dry-run
nix build .#chen-xiaomi-elish-bundle
```

bundle 将配对的 Btrfs rootfs 与 boot image 放在同一输出中：

```text
BUILD-INFO.txt
ChenXiaomiElish-rootfs.btrfs
SHA256SUMS
boot-a-boe.img
boot-a-csot.img
boot-b-boe.img
boot-b-csot.img
```

可以在写入前检查产物：

```sh
(cd result && sha256sum -c SHA256SUMS)
file -L result/ChenXiaomiElish-rootfs.btrfs result/boot-*.img
blkid result/ChenXiaomiElish-rootfs.btrfs
btrfs check --readonly result/ChenXiaomiElish-rootfs.btrfs
unpack_bootimg --boot_img result/boot-a-csot.img --out /tmp/elish-boot
```

## 首次启动输出与恢复网络

内建屏幕应依次显示内核、systemd 启动状态和顺时针旋转的 `tty1`。首启镜像不包含
GNOME，也不启用本机自动登录；使用与 `ChenIdeaCentre` 相同的 `chen` 用户密码登录。

连接支持 USB NCM 的电脑后，电脑应自动取得 `172.16.42.2/24`。使用 bundle 中
内置公钥对应的私钥或 `chen` 用户密码连接：

```sh
ssh chen@172.16.42.1
```

该 USB 链路不提供 NAT、默认路由或 DNS，只用于本机恢复管理。若电脑没有获得地址，
先在屏幕上检查 `usb-ncm-gadget.service` 和 `dnsmasq.service` 的失败状态；不要在未
确认失败原因时反复改写 boot slot。

## 可配置参数

`hosts/ChenXiaomiElish/abl.nix` 的 `hardware.xiaomiElish.abl.extraKernelArgs`
用于附加内核参数。slot suffix 由四个输出文件名固定，不再由一个全局选项控制。

`hosts/ChenXiaomiElish/rootfs.nix` 的
`hardware.xiaomiElish.rootfs.uuid` 控制 Btrfs UUID。initrd 通过 `root=fstab` 读取系统
配置，并按固定卷标 `NIXOS_ROOT` 挂载根文件系统；修改 UUID 不需要重建 boot cmdline。

## 部署边界

本阶段故意不提供 `fastboot flash`、`dd` 或 disko 命令。部署前必须先确认并备份：

1. 实机 BOE/CSOT 面板类型。
2. 当前活动 slot 以及可安全测试的 boot slot。
3. rootfs 实际对应的分区名称、容量和现有数据。
4. boot 与 rootfs 分区的完整备份及恢复路径。

rootfs 分区容量必须大于生成的镜像；首次启动会把 Btrfs 文件系统扩展到该分区的
完整容量。

确认这些映射后，再为该设备记录一次性的人工部署步骤；不要根据 Android 设备的
通用分区名称猜测写入目标。

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
设备运行时证据。下面四条原始"实机观察"是用户在**此前会话**中提供给
本 runbook 维护者的报告（ESP 状态现已更新，见第三条）；原始报告**尚未**持久化进
`.omo/artifacts/elish-edk2-allocator-fix-20260904/` 下任何 handoff
或 manual-QA 工件，因此本 runbook 与工件目录都不证明这些观察，
也不应把它们当成"旧 handoff/manual-QA 已经记录过的旧事实"来引用：

- 已越过原始的 `SimpleInitMain+0x1e3374 -> l_alloc -> free(NULL)`
  同步异常点（用户此前会话报告）；
- 已进入 EDK2 自定义 UI 并枚举到 Elish 的 UFS 设备（用户此前会话
  报告）；
- 当时报告专用 `esp` 分区为空；此项已被 2026-09-06 的本机只读
  检查更新：分区已有 `NIXOS_ESP` 文件系统标识，但扇区大小不匹配
  （详见下一节），未检查已安装 EFI 文件的内容；
- 当时 EDK2 自定义 UI 上没有 USB HID 键盘可用，用户只能用方向键
  与电源键交互（用户此前会话报告）。

该工件目录只能证明 `boot-elish.img` 的本地字节身份，不能把本地 hash
校验解读为原始报告已写进旧 handoff/manual-QA 或实机验证已通过。
下面新增的本机只读观测也不构成对其余用户报告或完整启动链的认证。

后续用户自行部署后，本机只读检查已确认通过 UEFI/systemd-boot 启动，
`/boot` 从 ESP 以 vfat 挂载。提交前再次检查时，`/run/booted-system`、
`/run/current-system` 和 system profile 均指向 `c2bqi2v2y9pc5b05d4m4m8sl0g598nm8`
这代 Elish 系统，且没有 failed 系统单元。这些是设备运行观察，不是从镜像
hash 推导的结论；不代表 BOE 面板、所有设备功能、回滚或 slot metadata 写回
已经完成专项 HIL 验收。agent 没有执行部署、切换或写盘。

## 已确认的 ESP 分区

`fastboot getvar partition-size:esp` 在该设备上返回 `0x3BA00000`，对应
`1000341504` 字节、`954` MiB、`244224` 个 4096 字节逻辑扇区。Linux 侧该
分区对应 `/dev/sda35`。仓库曾经的注释把 `/dev/sda35` 写成"不是可挂载的
EFI 分区"，那是远期 ABL-only 阶段的模型；现在的状态是：该分区已经在
GPT 中被预留，专门留给 NixOS 标准 EFI 启动使用，不能再视为**空分区**。
2026-09-06 在 Elish 本机只读执行
`lsblk -b -o NAME,SIZE,LABEL,PARTLABEL,LOG-SEC,PHY-SEC /dev/sda35`，测得
`SIZE=1000341504`、`LABEL=NIXOS_ESP`、`PARTLABEL=esp`，逻辑与物理
扇区均为 `4096` 字节。同一次启动的 `journalctl -b -k` 反复报告
`FAT-fs (sda35): logical sector size too small for device (logical sector size = 512)`。
这确认当时部署的 512 字节文件系统与设备不匹配，而不是分区为空。
仓库生成器已改为 4096 字节扇区；用户随后重新部署，目前已正常挂载。
只改生成器不会原地修复其它设备上已经写入的旧文件系统。
不要在没有明确写到 `/dev/sda35` 的授权情况下写入任何字节。

## 工件类别

本次交付引入三类产物，彼此不能互换：

1. **EDK2 启动容器**：`boot-elish.img`（由外部 EDK2 allocator 修复
   pipeline 产出，存放在 `.omo/artifacts/...`，不在本次 Nix bundle 之内）。
   本文档不复制也不重新构建；用户需要参考同目录 `OPENCODE-HANDOFF.md`。
2. **EFI 系统分区（ESP）原始镜像**：`ChenXiaomiElish-esp.fat32`，由
   `nix build .#packages.aarch64-linux.chen-xiaomi-elish-bundle` 产出，
   长度恰好为 `1000341504` 字节，分区卷标 `NIXOS_ESP`，固定 volume id
   `454c4953`，4096 字节扇区、每簇一个扇区，无 GPT/MBR 包装，无压缩。该镜像同时安装
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

在安装了 Nix 且启用 flakes 的 aarch64 Linux 构建机上可原生执行。
ESP、rootfs、bundle 与 ABL 的组装工具统一使用
`hardware.xiaomiElish.buildPkgs`，默认 `pkgs.buildPackages`：它跟随声明的
`nixpkgs.buildPlatform`，不会检测执行 `nix` 的机器架构。当前 flake 声明的
目标与默认构建平台均为 `aarch64-linux`；kernel、initrd、DTB 与
`config.systemd.package` 提供的 AA64 systemd-boot 始终来自目标配置。

仅构建 ESP（不构建巨大 rootfs 或完整 bundle，也不创建 result 链接）：

```sh
nix build --no-link --print-out-paths --max-jobs 1 --cores 2 --no-write-lock-file .#nixosConfigurations.ChenXiaomiElish.config.system.build.elishEspImage
```

完整 bundle 的独立构建命令：

```sh
nix flake check --no-build --all-systems
nix build .#nixosConfigurations.ChenXiaomiElish.config.system.build.toplevel --dry-run
nix build .#packages.aarch64-linux.chen-xiaomi-elish-bundle
```

在 x86_64 Linux 上直接调用同一 flake 不会自动得到 x86 工具。可以使用
原生 aarch64 远程 builder；或者在专用配置中显式声明
`nixpkgs.buildPlatform = "x86_64-linux"`，保留 aarch64 hostPlatform，
进行目标系统交叉构建（整个系统及 overlays 的交叉支持需另行验证）。
若只想在 x86 上组装已有 ARM64 payload，可通过附加模块设置
`hardware.xiaomiElish.buildPkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;`
（模块参数需要 `inputs`）。这个外部组装器 override 不改变目标 closure，
也不会交叉构建或自动提供它：ARM64 payload 仍需缓存或原生 builder。
rootfs 的 `unshare --map-root-user` 要求所选 builder 支持 user namespace，
不能依赖 QEMU user emulation 来实现。这里不承诺任意架构自动构建。

bundle 把 Btrfs rootfs、新 ESP FAT32 镜像与四个 ABL 恢复镜像同时放在
同一输出目录里（编排脚本使用所选构建平台的原生工具构建并链接）：

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

独立普通文件回归（dosfstools 4.2，未访问设备）确认：相同 `1000341504`
字节容量下，旧 `-F 32 -S 512` 虽然通过 `fsck.vfat -vn`，BPB 仍是
512 字节扇区，不能据此判断适配 Elish。新 `-F 32 -S 4096 -s 1` 的
BPB 为 4096 字节/扇区、1 扇区/簇、244224 总扇区、243714 数据簇，
超过 FAT32 的 65525 簇下限；卷标与 volume id 不变，`fsck.vfat -vn`
退出 0，mtools 目录创建与文件复制读回也通过。本机 dosfstools 4.2 在省略
`-s` 时也选择 1 扇区/簇；生成器仍显式使用 `-s 1` 固定这一有效几何。
这些 scratch 检查不替代实机挂载/启动验证。

### 2026-09-06 原生 ARM64 ESP 工件验证

上述 ESP-only 命令在 Elish 本机实际构建成功。默认配置的
`cache.nixos-cuda.org` 连接超时后，仅对本次命令增加
`--option substituters https://cache.nixos.org`；没有修改系统缓存配置或 lock。

```text
ESP: /nix/store/8awkj6yadbfgqgyw75qvfr66pqdn82b7-ChenXiaomiElish-esp.fat32
SHA-256: d8245af447e6d658be67b584d9fa5ae170c1438dfd96ed52f980f5365cdb0203
Toplevel: /nix/store/fkx3ci1w7si64mbdlb7jkri09ljn6fxi-nixos-system-ChenXiaomiElish-26.05.20260903.a5cc6f2
```

对该 store 普通文件执行 `fsck.vfat -vn` 退出 0；`stat`、BPB 原始字段与
`blkid -p` 确认 1000341504 字节、4096 字节/扇区、1 扇区/簇、244224
总扇区、卷标 `NIXOS_ESP`、volume id `454c4953`（UUID `454C-4953`）。
`mdir` 显示 909885440 字节空闲；`mcopy -s -i` 提取全部目录到临时目录后，
用 `cmp` 与源文件逐字节比较 kernel、initrd、CSOT DTB 和两个 EFI loader，
五项全部一致。三个 payload 的规范 store-derived 路径及完整 `options`
与该 toplevel 的 `boot.json` 一致；loader 配置的默认 entry、3 秒超时、
禁用 editor 与 console-mode keep 也一致。`file` 确认 kernel 与 fallback
EFI loader 为 ARM64。原生与显式 x86 工具 override 的四个组装 derivation
均通过平台评估，且保留同一个上述 ARM64 toplevel。

该次 agent 操作只构建并读取 ESP 工件，没有构建 rootfs/bundle、挂载、写设备、
激活系统或重启。以上是当时工件的历史记录；用户后续部署状态见“当前 HIL 现状”。

## 首次启动与安装接管

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

raw ESP 生成器预置启动文件，不等同于在设备上执行完整的 `bootctl install`。
首次部署后，先确认 `/boot` 已挂载为实际 ESP，再由用户执行一次标准接管：

```sh
sudo nixos-rebuild switch --flake .#ChenXiaomiElish --install-bootloader
```

这会调用上游安装流程，在设备上生成随机种子，并维护 EFI 文件和 NixOS
generation 条目。`canTouchEfiVariables = false` 仍传递 `--no-variables`，
不写 EFI 启动变量或 system token。不能把固定随机种子放进共享镜像。
systemd 260.2 的 `bootctl status` 在缺少种子时可能返回非零；首次安装路径
不经过普通更新分支的该项状态查询。

之后普通 `nixos-rebuild switch --flake .#ChenXiaomiElish` 会更新系统和 ESP
启动条目，无需重刷 raw image。`nofail` 只允许启动时容忍 ESP 挂载失败，
并不保证 ESP 离线时 rebuild 安全；更新前必须确认 `/boot` 的实际挂载状态。

## 桌面与设备用户态集成

`hosts/desktop.nix` 由 IdeaCentre 和 Elish 共享，提供 Plasma/SDDM Wayland、
PipeWire、rtkit、BlueZ、fcitx5 中文插件、字体及 locale。自动登录、32 位 ALSA、
vinput 语音服务和主桌面额外应用仍在 IdeaCentre 模块中；Elish 保留禁用自动
登录和现有内存限制。Home Manager 继续管理用户配置，不能替代这些系统服务。

`hosts/ChenXiaomiElish/device-integration.nix` 补充设备专用配置：

- 两份 UCM 文件逐字取自 pmaports `57cff102e1716bd87e7236146581d61dc8d76b23`
  的 `device/testing/device-xiaomi-elish/alsa-ucm-conf/`。与通用 UCM 合并后，
  通过 `ALSA_CONFIG_UCM2` 提供给会话及 PipeWire/WirePlumber，保留其它声卡
  配置。同时注册旧名称 `Xiaomi Mi Pad 5 Pro` 和当前内核长名称
  `Xiaomi-MiPad5Pro-elish`；ALSA 的默认查找使用长名称，只有旧名称时不会
  找到 HiFi profile。该 profile 描述内置扬声器，不承诺麦克风或蓝牙音频已验证。
- HexagonFS 独立固定到 `lujianhua/xiaomi-elish-firmware` 的
  `51e9ac8cd91d88de43fb016530b9421a2713467a`，仅打包 pmaports 保留的
  `sensors`/`socinfo`，不替换正在使用的 `d81ba3d` DSP、触控或功放固件。
  两个来源可核对到相同 SLPI image version，但运行兼容性仍待实机验收。
- `hexagonrpcd-sdsp` 使用 `fastrpc` 系统用户和 `/dev/fastrpc-sdsp`，资源根为
  大小写一致的 `share/qcom/sm8250/Xiaomi/elish`。设备 udev 规则带 systemd
  标记与启动依赖，服务不在构建过程中访问 DSP。
- 启用带 libssc 后端的 `iio-sensor-proxy`，增加 Elish 的传感器方向矩阵和
  FastRPC 传感器类型，复用已有内核 pd-mapper，不增加旧 userspace pd-mapper。

首次启用这些配置需要用户自行切换并重新登录桌面。Plasma Wayland 下应检查
“虚拟键盘”中的 Fcitx 5 选择；仅安装输入法包不等于所有应用的输入路径已验收。
切换后再验证 BlueZ 控制器和配对、实际 Speaker 输出、传感器数据，以及 SLPI
是否仍循环恢复。本轮构建和静态检查不包含播放、配对、旋转或休眠实测。

参考：[pmaports Elish 设备包](https://gitlab.postmarketos.org/postMarketOS/pmaports/-/blob/57cff102e1716bd87e7236146581d61dc8d76b23/device/testing/device-xiaomi-elish/APKBUILD)、
[Armbian HexagonRPC 集成](https://github.com/armbian/build/commit/73cd002cd48021abe5fadfa33138c4950ecc836a)。

## 蓝牙公共地址初始化

2026-09-06 用户启用共享 BlueZ 配置后，QCA6390 固件初始化成功且 rfkill
没有软/硬阻止，但 `bluetoothctl show` 报 `No default controller available`。
只读 `btmgmt config` 确认内置控制器处于 unconfigured 状态，唯一缺失项为
`public-address`；缺少 BNEP 的另一个日志不是控制器无法出现的原因。

`hosts/ChenXiaomiElish/bluetooth.nix` 声明按 HCI 实例启动的地址初始化服务。
脚本同时检查内置 UART 的完整 DT 路径、`qcom,qca6390-bt` compatible 和
`hci_uart_qca` 驱动，不假定它一定编号为 `hci0`。只有完整管理响应确认该
控制器支持且仅缺失 `public-address` 时，才调用 `btmgmt public-addr`；
已正常配置的控制器及其它蓝牙设备均保持不变。

没有可用公共地址时，沿用 Armbian 的设备专属派生方式：对运行时
`/etc/machine-id` 加 ` bluetooth\n` 求 SHA-256，以 `42:` 开头并选取固定
摘要字节。它不是恢复原厂地址，也不是厂商分配的全局地址；同一 machine-id
得到同一地址，克隆系统必须使用各自唯一的 machine-id。原始 machine-id
不进入 Nix store、源码或日志，也不在共享 ESP 中预置固定蓝牙地址。

udev 仅匹配 `DEVTYPE=host`，现有设备枚举也只选择完整 `hciN` 名称，避免把
连接子设备 `hci0:1` 误当成适配器。额外的枚举单元覆盖首次 `switch`；单条管理命令、
就绪等待和写后确认都有超时。初始化器不执行 power/scan/pair；控制器完成
注册后的自动上电由现有 BlueZ `powerOnBoot` 策略处理。配置只有在用户自行
激活时才会改变控制器运行状态，构建和测试不访问真实蓝牙管理接口。

不向 `btmgmt` 传入 `--timeout`：BlueZ 5.86 的该选项会保持事件循环直到定时
退出，期间忽略命令完成时的退出请求，可能在延迟 ACK 到达前返回 0。
由 Python 的 3 秒 subprocess 硬超时限制单次命令，正常情况按命令结果退出。
隔离 Unix socket 管理接口测试复现了旧模式丢失延迟确认、新模式保留确认，
没有向真实控制器重放写地址操作。历史失败日志未记录原始输出，无法还原当次
具体残余内容；新异常会包含转义后的非预期响应，以便区分后续故障。

BlueZ 5.86 的非交互查询仍可能夹带异步通知。解析器仅分离已知的设置、名称
和设备类别事件；索引或配置选项变化会使快照失效，最多重取三次只读查询。
未知输出、错误状态和不完整记录仍拒绝处理，地址写命令不自动重试。测试同时
覆盖静态响应和事件混入，避免自动上电通知被误判为损坏响应。

模拟回归可独立构建：

```sh
nix build --no-link --print-out-paths --max-jobs 1 --cores 2 \
  .#nixosConfigurations.ChenXiaomiElish.config.system.build.elishBluetoothTests
```

用户切换后可只读检查 `bluetoothctl list`、`bluetoothctl show` 和
`journalctl -b -u 'elish-bluetooth-address@*'`。模拟测试及系统构建通过不等于
实机地址设置、自动上电、热插拔或配对已验收。

参考：[Armbian 地址初始化脚本](https://github.com/armbian/build/blob/4579e02a18b2cc34a69eacfeee3df98f8a9efcdd/packages/bsp/generate-bt-mac-addr/bt-fixed-mac.sh)、
[BlueZ 管理协议](https://github.com/bluez/bluez/blob/74770b1fd2be612f9c2cf807db81fcdcc35e6560/doc/mgmt-protocol.rst)。

## 延后处理的内核 FIXME

2026-09-06 本机只读检查发现以下 Linux 7.2.0 启动告警。用户要求本轮仅
记录，不修改内核源码、Kconfig 或设备树，也不通过降低日志等级隐藏告警。
使用 `journalctl -b -k -o short-monotonic` 核对启动顺序；同步系统时间前的
墙钟日期不能用于判断日志是否属于旧启动。

- **FIXME(elish-touch-workqueue)**：启动约 1.84 秒，`nvt_ts_probe` 创建
  `nvt_esd_check_wq` 时仅传入 `WQ_MEM_RECLAIM`，内核报告未选择
  `WQ_PERCPU`/`WQ_UNBOUND` 并自动采用 `WQ_PERCPU`。后续检查
  `drivers/input/touchscreen/nt36523/nt36xxx.c` 的 workqueue API 适配，
  保持现有调度语义，并验证触控及 ESD 检测，不在本轮打补丁。
- **FIXME(elish-dsi-clock-handoff)**：启动约 1.43 秒，
  `dsi0_phy_pll_out_dsiclk already disabled/unprepared` 触发
  `clk_core_disable`/`clk_core_unprepare` 告警。后续检查 DSI PHY probe、
  orphan clock reparent 与固件显示状态交接，不能只删 WARN。
- **FIXME(elish-spmi-probe)**：启动约 1.42 秒，
  `pmic_arb_check_chnl_status_v1` 报 `0xa/0xb 0x104: transaction failed (0x3)`，
  对应 `reg: 0x9708/0xa688`。后续核对实际 PMIC 节点和访问权限；尚未证明
  与充电功能异常存在因果关系，不应凭此修改 regulator 或电源时序。

SLPI 的 `sensor_process` 初始化超时和循环恢复另属设备用户态集成问题的
排查范围。补齐 HexagonRPC/HexagonFS 后仍需由用户激活配置并观察日志、
传感器数据和待机行为；构建通过不等于该运行故障已修复。

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

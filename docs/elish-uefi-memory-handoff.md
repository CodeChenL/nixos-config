# Elish UEFI 内存映射缺陷 — 交接文档

> 生成时间：2026-09-07（会话总结）
> 状态：**只读调查完成；补丁草案已生成，未应用、未构建、未烧写**
> 下一站：另一台机器继续验证补丁草案 / 推送上游 / 决定烧录流程

---

## 1. 问题一句话

Xiaomi Pad 5 Pro (**elish**, SM8250) 在 **edk2-msm UEFI** 下 `MemTotal ≈ 4.83 GiB`。
根因：UEFI 内嵌 FDT 报告 **8.13 GiB（8 GB 版布局）**，但 Elish 私有内存映射表
`PlatformMemoryMapLib.c` **没有 Mem8G 分档**，只有 6G 版布局（RAM Partition 止于
8 GiB），导致 **8–10 GiB 共 2 GiB 物理内存从未发布给 Linux**。
与 NixOS 配置、tmpfs、zram 均无关。

---

## 2. 实测数据（来源机 A）

| 项目 | 值 |
|---|---|
| `MemTotal` | 5060148 KiB ≈ **4.8257 GiB** |
| dmesg Memory line | `4981832K/5608484K available (… 586648K reserved, 32768K cma-reserved)` |
| `/proc/iomem` 顶层 System RAM | 5168.832 MiB；reserved 308.203 MiB |
| 物理可见范围 | `0x805d0000 .. 0x1ffffffff`（上限 8 GiB） |
| UEFI 固件 | Renegade Project UEFI 2.70 / `edk2-msm 2302.1-mh2lm-169-ge195262` |
| 固件 commit | `e1952621f419f8db60ed28271264e1b5184c571d`（= 仓库 master，2026-03-07） |
| SMBIOS Type17 Size | `0x2000` = 8192 MiB（**模板值**，见 §4） |
| 蓝牙 | 已工作：控制器 `42:91:45:42:15:01`，Powered yes |
| NixOS 运行系统 | `/nix/store/c2bqi2v2y9pc5b05d4m4m8sl0g598nm8-…`（与本问题无关） |
| `zram` | 4.8 GiB zstd，数据 1.3 GiB → 压缩 387 MiB |

---

## 3. 证据链（源码，均 pin 到 `e1952621f419f8db60ed28271264e1b5184c571d`）

### 3.1 UEFI 内嵌 FDT 声明 8.13 GiB

`Platform/Xiaomi/sm8250/FdtBlob_compat/elish.dtb`（已下载到 `/tmp/opencode/elish-fdt.dtb` 验证）：

```text
memory@80000000:  addr 0x0000000080000000  size 0x000000003BB00000   → 2.0G ~ 2.93G (955 MiB)
                 addr 0x00000000C0000000  size 0x00000001C0000000   → 3.0G ~ 10.0G (7 GiB)
合计 8123 MiB（≈ 8 GB 设备布局，DRAM 上限 0x280000000）
```

`#address-cells=2, #size-cells=2`；`mem-offline/offline-sizes` 第二组
(`1 C0000000 0 80000000`) 佐证主 DRAM 覆盖 10 GiB 级地址。

复现命令（机器 B）：
```sh
fdtget -t x elish.dtb /memory reg
# 0 80000000 0 3bb00000 0 c0000000 1 c0000000
```

### 3.2 内存探测：FDT_DIRECT + fdt_get_memory

`Silicon/Qualcomm/QcomPkg/Library/MemoryInitPeiLib/MemoryInitPeiLib.c`：
- 首行 `#define FDT_DIRECT`
- `while (fdt_get_memory(Fdt, Node, …)) MemoryTotal += …`
- 分档：`SIZE_MB_IN(3072,4608,4) / (5120,6656,6) / (7168,8704,8) / (9216,10752,10) / (11520,12488,12)`
- **8123 MiB → 命中 `(7168, 8704)` → 选中 Mem8G 档**

### 3.3 GetFdt 来源：只读固件内固定地址，不依赖 ABL

`Silicon/Qualcomm/QcomPkg/Include/Library/FdtParserLib.h`：
```c
#ifndef FDT_DIRECT
  gBS->LocateProtocol(&gKernelFdtProtocolGuid, …)   // 其它设备路径
#else
  FdtAddress = *(UINT64*)FixedPcdGet64(PcdDeviceTreeStore);   // Elish 走这里
#endif
```

### 3.4 该 FDT 编译进 UEFI FD

`Platform/Xiaomi/sm8250/elish.fdf.inc`：
```
FILE FREEFORM = 25462CDA-221F-47DF-AC1D-259CFAA4E326 {
  SECTION RAW = Platform/Xiaomi/sm8250/FdtBlob_compat/elish.dtb
}
```

### 3.5 私有内存表无 8G 分档（根因）

`Platform/Xiaomi/sm8250/Library/elish/PlatformMemoryMapLib/PlatformMemoryMapLib.c`
（约第 31 行）：

```c
{"Kernel",           0xA0000000, 0x10000000, AddMem, …},                               // 2.5G~2.75G
{"DXE Heap",         0xC0000000, 0x0E000000, AddMem, …},                               // 3.0G~3.22G
{"UEFI FD",          0xCE000000, 0x02000000, AddMem, …},                               // 3.22G~3.25G
{"RAM Partition",    0xD0000000,0x130000000, AddMem, …},                               // 3.25G~8G  ⛔ 止于 0x200000000
```

- `0xD0000000 + 0x130000000 = 0x200000000`（8 GiB 结束）
- **没有任何 `Mem6G` / `Mem8G` 标签**，因此 MemoryInitPeiLib 选出的 Mem8G 档
  在该表上无对应条目，RAM Partition 以无条件 `AddMem` 身份发布 → 只有 6G 版布局。
- 兄弟设备 `alioth / apollo / lmi / pipa` 同款 `0x130000000 AddMem`（家族性行为；本次只改 Elish，见 §6 备注）。

### 3.6 BootShim 不传递内存布局

`tools/BootShim/BootShim.Dualboot.S`：
- `_KernelStart: b #0x02000000`（ABL 视其为普通 ARM64 内核 boot image）
- 只做 `CopyUEFI`（FD → `UEFI_BASE`）后 `br` 跳转
- 无 FDT 指针 / 无 DRAM 大小 / 无内存描述符
- 结论：**ABL → BootShim → edk2 链路不存在“内存布局传递”**；edk2 完全从
  固件内 compat FDT + 静态表自建内存。

### 3.7 SMBIOS 8 GiB 是模板

`Silicon/Qualcomm/sm8250/Library/SOCSmbiosInfoLib/SOCSmbiosInfo.c`：
- `mMemDevInfoType17.Size = 0x2000`（8192 MiB **硬编码**），
  `VolatileSize` 留待 `PhyMemArrayInfoUpdateSmbiosType16()` 运行时更新。
- **不能单独作为物理容量证据**；与 §3.1 FDT 互证后才指向 8 GB 版。

---

## 4. 变体判定（重要，仍未 100% 闭环）

- FDT = 8.13 GiB + SMBIOS 模板 8 GiB + 当前结果恰好 = 6G 版布局数值
  → **推断实机为 8 GB 版**（6 GB 版预期 FDT 应为 `0x3bb00000 + 0x140000000 ≈ 6076 MiB`）。
- ⚠️ 最终确认途径（机器 B 可选）：原厂 Android `build.prop` 的
  `ro.boot.dram` / dmesg `Total RAM`；或销售 BOM。
- **护栏**：即使实机是 6 GB 版，补丁也不会误加内存——6G 走 `Mem6G` 分支保持现值，
  `Mem8G` 分支不生效。

---

## 5. 补丁草案

文件：`/tmp/opencode/elish-8g-ram-partition.patch`（内容如下，也可从本文件复制）

```patch
diff --git a/Platform/Xiaomi/sm8250/Library/elish/PlatformMemoryMapLib/PlatformMemoryMapLib.c
--- a/Platform/Xiaomi/sm8250/Library/elish/PlatformMemoryMapLib/PlatformMemoryMapLib.c
+++ b/Platform/Xiaomi/sm8250/Library/elish/PlatformMemoryMapLib/PlatformMemoryMapLib.c
@@ -28,7 +28,12 @@ static ARM_MEMORY_REGION_DESCRIPTOR_EX gDeviceMemoryDescriptorEx[] = {
 	{"Log Buffer",       0x9FFF7000, 0x00008000, AddMem, SYS_MEM, SYS_MEM_CAP, Reserv, WRITE_BACK_XN},
 	{"Info Blk",         0x9FFFF000, 0x00001000, AddMem, SYS_MEM, SYS_MEM_CAP, Reserv, WRITE_BACK_XN},
 
 	{"Kernel",           0xA0000000, 0x10000000, AddMem, SYS_MEM, SYS_MEM_CAP, Reserv, WRITE_BACK_XN},
 	{"DXE Heap",         0xC0000000, 0x0E000000, AddMem, SYS_MEM, SYS_MEM_CAP, Conv,   WRITE_BACK_XN},
 	{"UEFI FD",          0xCE000000, 0x02000000, AddMem, SYS_MEM, SYS_MEM_CAP, BsData, WRITE_BACK},
 
-	{"RAM Partition",    0xD0000000,0x130000000, AddMem, SYS_MEM, SYS_MEM_CAP, Conv,   WRITE_BACK_XN},
+	/* MemoryInitPeiLib selects Mem8G when the bundled FDT reports >=7.0 GiB
+	 * (0x80000000+0x3bb00000 shared low bank and 0xc0000000+0x1c0000000 high
+	 * bank, total 8123 MiB).  The previous unconditional AddMem entry ended at
+	 * 8 GiB, silently hiding 0x200000000-0x280000000 (2 GiB) on 8 GB units.
+	 * Mem6G keeps the 6 GB units at the historical 8 GiB end. */
+	{"RAM Partition",    0xD0000000,0x130000000, Mem6G,  SYS_MEM, SYS_MEM_CAP, Conv,   WRITE_BACK_XN},
+	{"RAM Partition",    0xD0000000,0x1B0000000, Mem8G,  SYS_MEM, SYS_MEM_CAP, Conv,   WRITE_BACK_XN},
 
 	/* Other memory regions */
```

设计理由：
- 只改 Elish 表；`MemoryInitPeiLib.c` 无需动（已有档位过滤：不匹配 `continue`，匹配进 HOB+MMU）。
- 字段序对齐 `ARM_MEMORY_REGION_DESCRIPTOR_EX`：
  `{Name, Address, Length, HobOption, ResourceType, ResourceAttribute, MemoryType, ArmAttributes}`
  （见 `Silicon/Qualcomm/QcomPkg/Include/Library/PlatformMemoryMapLib.h`）。
- `Mem6G` = 现值（0xD0000000+0x130000000=0x200000000）；`Mem8G` = 0xD0000000+0x1B0000000=**0x280000000**（10 GiB 结束）。

**预期结果**：
```
新增 System RAM = 0x280000000 − 0x200000000 = 2048 MiB
MemTotal ≈ 5,060,148 + 2,097,152 ≈ 7,157,300 KiB ≈ 6.83 GiB
free -h 总计 ≈ 6.8 ~ 6.9 GiB（以实机为准）
```

---

## 6. 下一步（机器 B）

### 6.1 源码验证（不烧录）
```sh
git clone https://github.com/edk2-porting/edk2-msm
git checkout e1952621f419f8db60ed28271264e1b5184c571d
git am /tmp/opencode/elish-8g-ram-partition.patch   # 先 git apply --check
# 确认当前 master 的该文件是否仍无分档（会话时已确认 master 相同 → 可作独立修复/上游 PR）
```

### 6.2 构建（aarch64 GCC）
```sh
source edksetup.sh
build -a AARCH64 -t GCC5 -p Platform/Xiaomi/sm8250/elish.dsc
```
构建前核对两处：
- `MemoryDescriptor[MAX_ARM_MEMORY_REGION_DESCRIPTOR_COUNT]` 不触发 `ASSERT`
  （Elish 表 ~62 条 +1；宏定义未在本次会话定位到具体头文件，机器 B 直接 grep）。
- 生成 FD 中 FDT section（GUID `25462CDA-…`）仍带 8G `memory` 节点。

### 6.3 烧录（需独立授权 + 备份）
- 遵循原仓库 `docs/xiaomi-elish-bringup.md` 部署边界：
  先备份当前 UEFI，确认恢复路径（回 Android 最简步骤），再确定目标分区/槽位。
- 会话未执行任何烧录命令，也不提供未经确认的分区写入命令。

### 6.4 验证
- 启动后 `free -h` 总计 ≈ 6.8 GiB；`/proc/meminfo MemTotal ≈ 7157300 KiB`。
- `dmesg | grep Memory` 总量增加约 2 GiB；`/proc/iomem` System RAM 约 7.35 GiB。
- 若回归（启动失败/黑屏）：用备份固件回滚。

### 6.5 上游方向（建议）
- 向 `edk2-porting/edk2-msm` 提 issue/PR：elish 私有表缺少 Mem6G/Mem8G 分档，
  8 GB 版丢失 8–10G 段。可引用本文档证据链。
- 兄弟设备（alioth/apollo/lmi/pipa）同款 `0x130000000 AddMem`，若它们的 FDT
  也按 8G/12G 分布，存在同样问题——建议一并核查但**本补丁不动它们**。

---

## 7. 已做 / 未做清单

已做（只读）：
- 本机 dmesg/meminfo/iomem/DT/FDT 提取与算数
- edk2-msm 对应版本源码全链路核对（FDT → 分档 → 静态表 → BootShim）
- 生成补丁草案 `/tmp/opencode/elish-8g-ram-partition.patch`

未做：
- 未应用补丁 / 未构建 UEFI / 未烧写任何分区
- 未修改 `nixos-config` 仓库（该仓库有 9 个先前提交，与此问题无关；
  `bootctl.log`、`switch.log` 为未跟踪文件，勿一并上传）
- 未能 100% 确认 6G/8G 变体（见 §4）

---

## 8. 相关文件速查（机器 A 本地）

| 文件 | 说明 |
|---|---|
| `/tmp/opencode/elish-fdt.dtb` | UEFI 内嵌 compat FDT |
| `/tmp/opencode/elish-8g-ram-partition.patch` | 补丁草案 |
| `/tmp/opencode/elish-uefi-memory-handoff.md` | 本文档 |

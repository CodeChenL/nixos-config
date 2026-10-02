# linux-cix-main: Linux 7.1.5 (stable) + CIX patches from cixtech/cix-linux-main
# https://github.com/cixtech/cix-linux-main
{
  lib,
  stdenv,
  fetchurl,
  fetchFromGitHub,
  buildLinux,
  runCommand,
  ...
}@args:

let
  # ── upstream Linux 7.1.5 (latest stable) ─────────────────────────────
  linuxVersion = "7.1.5";
  linuxTarball = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${linuxVersion}.tar.xz";
    hash = "sha256-IqAZazy83zTcJ7d1YfTQQFhf00R+3JqzUxoax54wQec=";
  };

  # CIX patches 现在原生支持 7.1，使用 patches-7.1 目录
  cixConfigVersion = "7.1";

  # ── CIX patches & config ──────────────────────────────────────────
  cixPatchesRev = "19f294730367";
  cixPatchesSrc = fetchFromGitHub {
    owner = "cixtech";
    repo = "cix-linux-main";
    rev = cixPatchesRev;
    hash = "sha256-1BBS/ipb4qnhQBd24ZOvoJz58r39CPeV7RhTMt2N7rc=";
  };

  # 使用 patches-7.1 目录（原生针对 7.1 内核）
  patchDir = "${cixPatchesSrc}/patches-7.1";
  patchFiles = lib.pipe (builtins.readDir patchDir) [
    (lib.filterAttrs (_name: type: type == "regular"))
    (lib.filterAttrs (name: _: lib.hasSuffix ".patch" name))
    builtins.attrNames
    (builtins.map (name: "${patchDir}/${name}"))
  ];

  # patches-7.1 原生针对 7.1 内核，但以下补丁在 7.1.5 上有冲突：
  # - 0011 (panthor ACPI): panthor_regs.h→panthor_gpu_regs.h, gpu_read/write API 变更
  # - 0038 (panthor suspend/resume): 依赖 0011 上下文
  # - 0040 (panthor DPM flag): panthor_drv.c 上下文偏移
  # 使用手动移植的 7.1.5 修复版本替代

  panthorConflicts = [
    "0011-drm-panthor-add-acpi-support-for-cix-p1"
    "0038-gpu-panthor-fix-suspend-resume-for-sky1"
    "0040-panthor-set-DPM_FLAG_NO_DIRECT_COMPLETE-for-STR-on-s"
  ];

  kernelPatches = builtins.filter (p: !(builtins.elem p.name panthorConflicts)) (
    builtins.map (patchFile: {
      name = lib.removeSuffix ".patch" (builtins.baseNameOf patchFile);
      patch = patchFile;
    }) patchFiles
  );

  # pl011 BSP 驱动补丁未包含在 patches-7.1 中。
  # 7.1.5 的 nbcon console API 与此补丁冲突，暂时禁用，先用上游 pl011 驱动。
  # pl011Patch = {
  #   name = "pl011-cix-bsp-7.1";
  #   patch = ./0046-tty-amba-pl011-use-driver-from-cix-bsp-7.1.patch;
  # };

  # 手动移植到 7.1.5 的 panthor 补丁
  panthorA7_1_5Patches = [
    {
      name = "0011-drm-panthor-add-acpi-support-for-cix-p1-7.1.5";
      patch = ./0011-drm-panthor-add-acpi-support-for-cix-p1-7.1.5.patch;
    }
    {
      name = "0038-gpu-panthor-fix-suspend-resume-for-sky1-7.1.5";
      patch = ./0038-gpu-panthor-fix-suspend-resume-for-sky1-7.1.5.patch;
    }
    {
      name = "0040-panthor-set-DPM_FLAG_NO_DIRECT_COMPLETE-for-STR-on-sky1-7.1.5";
      patch = ./0040-panthor-set-DPM_FLAG_NO_DIRECT_COMPLETE-for-STR-on-sky1-7.1.5.patch;
    }
  ];

  # panthor GPU register 修复：在 7.1.5 中 panthor_regs.h 已拆分为 panthor_gpu_regs.h，
  # 需要将 CIX 新增的寄存器定义添加到正确的文件中
  panthorGpuRegsPatch = {
    name = "panthor-gpu-regs-cix-7.1.5";
    patch = ./panthor-gpu-regs-cix-7.1.5.patch;
  };

  # linlon-dp Makefile 中 ccflags-y 使用 $(src) 在 Nix 构建环境中展开失败，
  # 导致 `#include "linlondp_drm.h"` 找不到 include/ 子目录下的头文件
  linlondpIncludeFix = {
    name = "linlondp-makefile-include-fix";
    patch = ./linlondp-makefile-include-fix.patch;
  };

  allPatches = kernelPatches
    # ++ [ pl011Patch ]
    ++ panthorA7_1_5Patches
    ++ [ panthorGpuRegsPatch linlondpIncludeFix ];

  # 解压 kernel.org tarball + 放入 CIX defconfig
  patchedSrc = runCommand "linux-${linuxVersion}-cix-src" { } ''
    mkdir -p $out
    tar -xf ${linuxTarball} -C $out --strip-components=1
    chmod -R u+w $out
    cp ${cixPatchesSrc}/config/config-${cixConfigVersion}.defconfig $out/arch/arm64/configs/cix.config
    chmod u+w $out/arch/arm64/configs/cix.config
  '';

in
buildLinux {
  pname = "linux-cix-main";
  version = linuxVersion;
  src = patchedSrc;

  modDirVersion = linuxVersion;

  kernelPatches = allPatches;

  # 先应用基础 defconfig，再叠加 CIX 专用配置片段
  defconfig = "defconfig cix.config";

  # 禁用 debug info + BTF：CIX defconfig 编译全部内核模块，
  # 服务器用途不需要内核调试信息（kallsyms 足够）。
  structuredExtraConfig = with lib.kernel; {
    DEBUG_INFO = lib.mkForce no;
    DEBUG_INFO_BTF = lib.mkForce no;

    # ── 削减无关模块（arm64 服务器用不到）────────────────
    # CIX defconfig 是全量配置，几千个模块既拖慢构建又耗尽
    # O6N 的磁盘空间。MEDIA_SUPPORT 必须保留（cix-vpu-driver
    # 依赖 V4L2/VIDEOBUF2 符号 vb2_queue_init/v4l2_fh_* 等），
    # 但 TV/Radio/SDR 等子类对 O6N 无用且模块量巨大，禁用。
    MEDIA_ANALOG_TV_SUPPORT = lib.mkForce no;
    MEDIA_DIGITAL_TV_SUPPORT = lib.mkForce no;
    MEDIA_RADIO_SUPPORT = lib.mkForce no;
    MEDIA_SDR_SUPPORT = lib.mkForce no;
    MEDIA_TEST_SUPPORT = lib.mkForce no;
    COMEDI = no;                   # 数据采集卡
    DRM_AMDGPU = no;               # x86 GPU
    DRM_NOUVEAU = no;
    DRM_XE = no;
    DRM_I915 = no;
    DRM_RADEON = no;
    MEI = no;                      # Intel Management Engine
    ISDN = no;                     # 老式 ISDN
    NFC = no;                      # NFC
    HAMRADIO = no;                 # 业余无线电
    CAN = no;                      # CAN 总线
  };

  # 标记忽略配置错误（defconfig 可能有未知选项）
  ignoreConfigErrors = true;

  # cix-linux-main 不是 LTS
  isLTS = false;

  extraMeta = {
    description = "Linux ${linuxVersion} (stable) with CIX Sky1 patches for Radxa Orion O6/O6N";
    homepage = "https://github.com/cixtech/cix-linux-main";
    platforms = [ "aarch64-linux" ];
  };
}

# linux-cix-main: Linux v7.0 + CIX patches from cixtech/cix-linux-main
# https://github.com/cixtech/cix-linux-main
{
  lib,
  fetchFromGitHub,
  buildLinux,
  runCommand,
  ...
}@args:

let
  # ── upstream Linux v7.0 ───────────────────────────────────────────
  linuxVersion = "7.0";
  linuxSrc = fetchFromGitHub {
    owner = "torvalds";
    repo = "linux";
    rev = "v${linuxVersion}";
    hash = "sha256-7TjYHhJdD67P3lquusrjjVtUIUzhLPtA5Oy7tc82gYA=";
  };

  # ── CIX patches & config ──────────────────────────────────────────
  cixPatchesRev = "3aad82491a599648d87ba1c47cec7968862fa165";
  cixPatchesSrc = fetchFromGitHub {
    owner = "cixtech";
    repo = "cix-linux-main";
    rev = cixPatchesRev;
    hash = "sha256-ntc23Nh3eOWgRcfZTTUWigLrs/LqEtIrYhFwiFiSDUc=";
  };

  # 动态读取 patches-7.0 目录下的所有 .patch 文件
  # 文件名已按数字编号排序（0001-xxxx, 0002-xxxx, ..., 2001-xxxx）
  patchDir = "${cixPatchesSrc}/patches-7.0";
  patchFiles = lib.pipe (builtins.readDir patchDir) [
    (lib.filterAttrs (_name: type: type == "regular"))
    (lib.filterAttrs (name: _: lib.hasSuffix ".patch" name))
    builtins.attrNames
    (map (name: "${patchDir}/${name}"))
  ];

  kernelPatches = map (patchFile: {
    name = lib.removeSuffix ".patch" (builtins.baseNameOf patchFile);
    patch = patchFile;
  }) patchFiles;

  # 将 CIX defconfig 放入内核源码树的 arch/arm64/configs/
  # 同时修补关键驱动为内建（原 defconfig 中是模块，initrd 不可用）
  patchedSrc = runCommand "linux-${linuxVersion}-cix-src" { } ''
    cp -r ${linuxSrc} $out
    chmod -R u+w $out
    cp ${cixPatchesSrc}/config/config-${linuxVersion}.defconfig $out/arch/arm64/configs/cix_defconfig

    # 修补 defconfig：将关键启动驱动从模块改为内建。
    # rootfs 当前在 USB 读卡器上，USB Mass Storage 还需要 SCSI disk(sd_mod)。
    chmod u+w $out/arch/arm64/configs/cix_defconfig

    set_config() {
      local key="$1"
      local value="$2"
      if grep -q "^CONFIG_$key=" $out/arch/arm64/configs/cix_defconfig; then
        sed -i "s/^CONFIG_$key=.*/CONFIG_$key=$value/" $out/arch/arm64/configs/cix_defconfig
      else
        printf 'CONFIG_%s=%s\n' "$key" "$value" >> $out/arch/arm64/configs/cix_defconfig
      fi
    }

    set_config SCSI y
    set_config BLK_DEV_SD y
    set_config BLK_DEV_NVME y
    set_config BTRFS_FS y
    set_config VFAT_FS y
    set_config USB_STORAGE y
    set_config USB_UAS y
  '';

in
buildLinux {
  pname = "linux-cix-main";
  version = linuxVersion;
  src = patchedSrc;

  modDirVersion = "${linuxVersion}.0";

  inherit kernelPatches;

  # 先应用基础 defconfig，再叠加 CIX 专用配置片段
  # 与 BSP 内核 (defconfig = "defconfig cix.config") 逻辑一致
  defconfig = "defconfig cix_defconfig";

  # 标记忽略配置错误（defconfig 可能有未知选项）
  ignoreConfigErrors = true;

  # cix-linux-main 不是 LTS
  isLTS = false;

  extraMeta = {
    description = "Linux ${linuxVersion} with CIX Sky1 patches for Radxa Orion O6/O6N";
    homepage = "https://github.com/cixtech/cix-linux-main";
    platforms = [ "aarch64-linux" ];
  };
}

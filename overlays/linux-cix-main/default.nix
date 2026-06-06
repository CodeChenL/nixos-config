# linux-cix-main: Linux 7.0.11 (stable) + CIX patches from cixtech/cix-linux-main
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
  # ── upstream Linux 7.0.11 (stable) ──────────────────────────────────
  linuxVersion = "7.0.11";
  linuxTarball = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${linuxVersion}.tar.xz";
    hash = "sha256-5WyDVt2gETamBBxu+DK9Dsmb0tNd/5eDKqXsEO0BQwQ=";
  };

  # CIX defconfig 始终用 7.0 的配置文件名
  cixConfigVersion = "7.0";

  # ── CIX patches & config ──────────────────────────────────────────
  cixPatchesRev = "3aad82491a599648d87ba1c47cec7968862fa165";
  cixPatchesSrc = fetchFromGitHub {
    owner = "cixtech";
    repo = "cix-linux-main";
    rev = cixPatchesRev;
    hash = "sha256-ntc23Nh3eOWgRcfZTTUWigLrs/LqEtIrYhFwiFiSDUc=";
  };

  # 动态读取 patches-7.0 目录下的所有 .patch 文件
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

  inherit kernelPatches;

  # 先应用基础 defconfig，再叠加 CIX 专用配置片段
  # 与 BSP 内核 (defconfig = "defconfig cix.config") 逻辑一致
  defconfig = "defconfig cix.config";

  # 标记忽略配置错误（defconfig 可能有未知选项）
  ignoreConfigErrors = true;

  # cix-linux-main 不是 LTS (但 v7.0.11 是 stable)
  isLTS = false;

  extraMeta = {
    description = "Linux ${linuxVersion} (stable) with CIX Sky1 patches for Radxa Orion O6/O6N";
    homepage = "https://github.com/cixtech/cix-linux-main";
    platforms = [ "aarch64-linux" ];
  };
}

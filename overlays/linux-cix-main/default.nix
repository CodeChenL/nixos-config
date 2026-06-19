# linux-cix-main: Linux 7.0.12 (stable) + CIX patches from cixtech/cix-linux-main
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
  # ── upstream Linux 7.0.12 (latest 7.0 stable) ───────────────────────
  linuxVersion = "7.0.12";
  linuxTarball = fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${linuxVersion}.tar.xz";
    hash = "sha256-V+3JpB78HKa3l6+o9KWHow2ir2vKc1brVuHhpK2iZdo=";
  };

  # CIX defconfig 始终用 7.0 的配置文件名
  cixConfigVersion = "7.0";

  # ── CIX patches & config ──────────────────────────────────────────
  cixPatchesRev = "759efc09237e7728e2881b3f6083fd80b3106ae3";
  cixPatchesSrc = fetchFromGitHub {
    owner = "cixtech";
    repo = "cix-linux-main";
    rev = cixPatchesRev;
    hash = "sha256-0EGfG3izB6UeMqCEM5GFXU81jhukag4ohB4hmaFt74E=";
  };

  # 动态读取 patches-7.0 目录下的所有 .patch 文件
  patchDir = "${cixPatchesSrc}/patches-7.0";
  patchFiles = lib.pipe (builtins.readDir patchDir) [
    (lib.filterAttrs (_name: type: type == "regular"))
    (lib.filterAttrs (name: _: lib.hasSuffix ".patch" name))
    builtins.attrNames
    (map (name: "${patchDir}/${name}"))
  ];

  fixedRegulatorAcpiPatch = builtins.toFile "0033-regulator-add-acpi-support.patch" (
    let
      original = builtins.readFile "${patchDir}/0033-regulator-add-acpi-support.patch";
      fixedIsErr = builtins.replaceStrings
        [ "	if (IS_ERR(n_phandles))" ]
        [ "	if (n_phandles < 0)" ]
        original;
    in
    builtins.replaceStrings
      [ "		n_phandles = max(n_phandles, 0);\n" ]
      [ "" ]
      fixedIsErr
  );

  fixedLinlondpDriverPatch = builtins.toFile "0010-drm-add-cix-linlon-dp-driver.patch" (
    let
      original = builtins.readFile "${patchDir}/0010-drm-add-cix-linlon-dp-driver.patch";
    in
    builtins.replaceStrings
      [ ''+    -I $(srctree)/$(src)
'' ]
      [ ''+    -I $(srctree)/$(src) \
+    -I $(srctree)/drivers/gpu/drm/cix/dptx
'' ]
      original
  );

  kernelPatches = map (patchFile:
    let
      patchName = builtins.baseNameOf patchFile;
    in
    {
      name = lib.removeSuffix ".patch" patchName;
      patch = if patchName == "0010-drm-add-cix-linlon-dp-driver.patch"
        then fixedLinlondpDriverPatch
        else if patchName == "0033-regulator-add-acpi-support.patch"
        then fixedRegulatorAcpiPatch
        else patchFile;
    }
  ) patchFiles;

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

  # cix-linux-main 不是 LTS (但 v7.0.12 是 stable)
  isLTS = false;

  extraMeta = {
    description = "Linux ${linuxVersion} (stable) with CIX Sky1 patches for Radxa Orion O6/O6N";
    homepage = "https://github.com/cixtech/cix-linux-main";
    platforms = [ "aarch64-linux" ];
  };
}

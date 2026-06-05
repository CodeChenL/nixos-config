# cix-vpu-driver: CIX Sky1 VPU DKMS 驱动
# 参考 radxa-pkg/cix-drivers-dkms 的构建方式
{
  lib,
  stdenv,
  fetchFromGitHub,
  kernel,
  applyDebianPatches,
  ...
}:

stdenv.mkDerivation {
  pname = "cix-vpu-driver";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "cixtech";
    repo = "cix_opensource__vpu_driver";
    rev = "cix_mainline_dev";
    hash = "sha256-YyOsuomP+jpAOoRfYySeCmmK/EzL799WQukaaLMmDdA=";
  };

  # 自动应用 debian/patches/series 中的所有补丁
  postPatch = applyDebianPatches;

  # 参考 Radxa 的构建方式
  buildPhase = ''
    runHook preBuild

    # 参考 src/Makefile 中的 VPU 构建命令
    # scons -j$(shell nproc) -C vpu target=linux
    # 但 CIX 源码使用 Makefile，使用 make 构建
    export COMPASS_DRV_BTENVAR_KPATH="${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    make -j$NIX_BUILD_CORES

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # NixOS 使用标准内核模块路径
    mkdir -p $out/lib/modules/${kernel.modDirVersion}/kernel/drivers/media/platform/cix
    install -m 644 amvx.ko $out/lib/modules/${kernel.modDirVersion}/kernel/drivers/media/platform/cix/

    runHook postInstall
  '';

  meta = with lib; {
    description = "CIX Sky1 VPU driver (amvx) for video processing";
    homepage = "https://github.com/cixtech/cix_opensource__vpu_driver";
    license = licenses.gpl2;
    platforms = [ "aarch64-linux" ];
    maintainers = [ ];
  };
}

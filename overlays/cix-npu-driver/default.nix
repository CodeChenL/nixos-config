# cix-npu-driver: CIX Sky1 NPU DKMS 驱动
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
  pname = "cix-npu-driver";
  version = "5.11.0";

  src = fetchFromGitHub {
    owner = "cixtech";
    repo = "cix_opensource__npu_driver";
    rev = "cix_mainline_dev";
    hash = "sha256-eq95TOZwG7lisyq5koSaoRK4QB+QVQcgDJj+3Ekgf2s=";
  };

  # 自动应用 debian/patches/series 中的所有补丁
  postPatch = applyDebianPatches;

  # 参考 Radxa 的构建方式
  buildPhase = ''
    runHook preBuild

    # 参考 src/Makefile 中的 NPU 构建命令
    # cd npu/driver && $(MAKE) -C $(KDIR) M=$(PWD)/npu/driver modules \
    #   COMPASS_DRV_BTENVAR_KPATH=$(KDIR) \
    #   BUILD_AIPU_VERSION_KMD=BUILD_ZHOUYI_V3 \
    #   COMPASS_DRV_BTENVAR_KMD_VERSION=5.11.0 \
    #   BUILD_TARGET_PLATFORM_KMD=BUILD_PLATFORM_SKY1 \
    #   BUILD_NPU_DEVFREQ=y
    cd driver
    make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build M=$(pwd) modules \
      COMPASS_DRV_BTENVAR_KPATH="${kernel.dev}/lib/modules/${kernel.modDirVersion}/build" \
      BUILD_AIPU_VERSION_KMD=BUILD_ZHOUYI_V3 \
      COMPASS_DRV_BTENVAR_KMD_VERSION=5.11.0 \
      BUILD_TARGET_PLATFORM_KMD=BUILD_PLATFORM_SKY1 \
      BUILD_NPU_DEVFREQ=y

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # NixOS 使用标准内核模块路径
    mkdir -p $out/lib/modules/${kernel.modDirVersion}/kernel/drivers/misc/cix
    install -m 644 aipu.ko $out/lib/modules/${kernel.modDirVersion}/kernel/drivers/misc/cix/

    runHook postInstall
  '';

  meta = with lib; {
    description = "CIX Sky1 NPU driver (aipu) for neural processing";
    homepage = "https://github.com/cixtech/cix_opensource__npu_driver";
    license = licenses.gpl2;
    platforms = [ "aarch64-linux" ];
    maintainers = [ ];
  };
}

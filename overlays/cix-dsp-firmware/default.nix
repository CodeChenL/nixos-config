# cix-dsp-firmware: CIX Sky1 DSP 固件
# https://github.com/cixtech/cix_proprietary__cix_proprietary
{
  lib,
  stdenv,
  fetchurl,
  ...
}:

stdenv.mkDerivation {
  pname = "cix-dsp-firmware";
  version = "2026.06";

  # 从 cixtech 私有仓库获取 DSP 固件
  # 注：cix_proprietary 仓库没有 cix_mainline_dev 分支，该文件是固件 blob，
  # 不依赖内核版本，使用 cix_p1_k6.6_master 分支的最新版本即可
  src = fetchurl {
    url = "https://github.com/cixtech/cix_proprietary__cix_proprietary/raw/refs/heads/cix_p1_k6.6_master/cix_proprietary-debs/cix-audio-dsp/usr/lib/firmware/dsp_fw.bin";
    hash = "sha256-FQ4BBHqEKpqlQbf852qWVavoAWHeVBaiyQdaBNLlFAg=";
  };

  # 不需要解压，直接安装二进制文件
  unpackPhase = "true";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/firmware
    cp $src $out/lib/firmware/dsp_fw.bin

    runHook postInstall
  '';

  meta = with lib; {
    description = "CIX Sky1 DSP firmware for audio processing";
    homepage = "https://github.com/cixtech/cix_proprietary__cix_proprietary";
    license = licenses.unfree; # 私有固件
    platforms = [ "aarch64-linux" ];
    maintainers = [ ];
  };
}

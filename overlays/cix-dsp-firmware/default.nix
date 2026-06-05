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
  version = "2026.02";

  # 从 cixtech 私有仓库获取 DSP 固件
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

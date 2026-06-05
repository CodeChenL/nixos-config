{
  lib,
  stdenv,
  fetchFromGitHub,
  ...
}:

stdenv.mkDerivation {
  pname = "cix-vpu-headers";
  version = "2026.02";

  src = fetchFromGitHub {
    owner = "cixtech";
    repo = "cix_opensource__vpu_driver";
    rev = "cix_mainline_dev";
    hash = "sha256-YyOsuomP+jpAOoRfYySeCmmK/EzL799WQukaaLMmDdA=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/include
    install -m 644 driver/linux/mvx-v4l2-controls.h $out/include/

    runHook postInstall
  '';

  meta = with lib; {
    description = "CIX Sky1 VPU uAPI headers (mvx-v4l2-controls.h)";
    homepage = "https://github.com/cixtech/cix_opensource__vpu_driver";
    license = licenses.gpl2;
    platforms = [ "aarch64-linux" ];
    maintainers = [ ];
  };
}

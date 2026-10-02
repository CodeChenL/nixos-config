{
  lib,
  stdenv,
  fetchFromGitHub,
  ...
}:

stdenv.mkDerivation {
  pname = "cix-vpu-firmware";
  version = "2026.07";

  src = fetchFromGitHub {
    owner = "cixtech";
    repo = "cix_opensource__vpu_driver";
    rev = "cix_mainline_dev";
    hash = "sha256-/OB4NvqG1smJHZX5TiTsV31jEtZMEMsdaxvjI6OjsSg=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/firmware
    cp firmware-binaries/*.fwb $out/lib/firmware/

    runHook postInstall
  '';

  meta = with lib; {
    description = "CIX Sky1 VPU firmware binaries for amvx video codec";
    homepage = "https://github.com/cixtech/cix_opensource__vpu_driver";
    license = licenses.unfree;
    platforms = [ "aarch64-linux" ];
    maintainers = [ ];
  };
}

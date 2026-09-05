{
  fetchFromGitHub,
  fetchurl,
  lib,
  stdenvNoCC,
  ...
}:

let
  venusFirmware = fetchurl {
    url = "https://raw.githubusercontent.com/armbian/firmware/f50a2a21bcdb77a562b3976930c5c6b521a1df08/qcom/sm8250/xiaomi/elish/venus.mbn";
    hash = "sha256-BvenDlQkL6HJ3Z/lJ1QSQu58eXOf7T7qHi4sEF6uBTU=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "xiaomi-elish-firmware";
  version = "0-unstable-2026-08-17";

  src = fetchFromGitHub {
    owner = "lujianhua";
    repo = "xiaomi-elish-firmware";
    rev = "d81ba3dfd6b13a719906b1e1f708fd3e46c8c39b";
    hash = "sha256-4DXID4fLdXI796uEbJqoay6zUDLx2OdAZiP2Ea4a4c0=";
  };

  installPhase = ''
    runHook preInstall

    install -Dm644 sm8250/* -t $out/lib/firmware/qcom/sm8250/xiaomi/elish
    install -Dm644 ${venusFirmware} $out/lib/firmware/qcom/sm8250/xiaomi/elish/venus.mbn
    install -Dm644 novatek/* -t $out/lib/firmware/novatek
    install -Dm644 cirrus/* -t $out/lib/firmware/cirrus

    runHook postInstall
  '';

  meta = {
    description = "Firmware for the Xiaomi Pad 5 Pro (elish)";
    homepage = "https://github.com/lujianhua/xiaomi-elish-firmware";
    license = lib.licenses.unfree;
    platforms = [ "aarch64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryFirmware ];
  };
}

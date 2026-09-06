{
  fetchFromGitHub,
  lib,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "xiaomi-elish-hexagonfs";
  version = "0-unstable-2024-09-16";

  src = fetchFromGitHub {
    owner = "lujianhua";
    repo = "xiaomi-elish-firmware";
    rev = "51e9ac8cd91d88de43fb016530b9421a2713467a";
    hash = "sha256-9NlKqAqMZ1pvgeZdwlHDY3NBE2BC29iVmqGnGAC7g/4=";
  };

  passthru = {
    firmwareRevision = "51e9ac8cd91d88de43fb016530b9421a2713467a";
    compatibleFirmwareRevision = "d81ba3dfd6b13a719906b1e1f708fd3e46c8c39b";
    compatibleSlpiImageVersion = "SLPI.HY.3.0-00253-SM8250AZL-1";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    root="$out/share/qcom/sm8250/Xiaomi/elish"
    mkdir -p "$root"
    cp -a hexagonfs/sensors hexagonfs/socinfo "$root/"

    test ! -e "$root/acdb"
    test ! -e "$root/dsp"

    test -f "$root/sensors/sns_reg.conf"
    test -f "$root/sensors/sns_reg_version"
    test -f "$root/sensors/registry/sns_reg_config"
    test -f "$root/socinfo/soc_id"

    runHook postInstall
  '';

  meta = {
    description = "HexagonFS sensor resources for the Xiaomi Pad 5 Pro (elish)";
    homepage = "https://github.com/lujianhua/xiaomi-elish-firmware";
    license = lib.licenses.unfree;
    platforms = [ "aarch64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryFirmware ];
  };
}

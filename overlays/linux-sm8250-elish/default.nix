{
  lib,
  fetchurl,
  linuxKernel,
  ...
}:

let
  version = "7.2.0";
  rev = "71f4068cb254730bcf334cde9bdd6ca183e4fcd0";

  kernel = linuxKernel.manualConfig {
    pname = "linux-sm8250-elish";
    inherit version;
    modDirVersion = version;

    src = fetchurl {
      url = "https://gitlab.postmarketos.org/soc/qualcomm-sm8250/linux/-/archive/${rev}/linux-${rev}.tar.gz";
      hash = "sha256-EmsnD0IBGHHjdannu6Cfk0bqGCVzEBtTRvvDFA874Qg=";
    };

    configfile = ./linux-sm8250-edge.config;

    extraMeta = {
      description = "Linux ${version} for the Xiaomi Pad 5 Pro (elish)";
      homepage = "https://gitlab.postmarketos.org/soc/qualcomm-sm8250/linux";
      license = lib.licenses.gpl2Only;
      platforms = [ "aarch64-linux" ];
    };
  };
in
kernel.overrideAttrs (oldAttrs: {
  postInstall = (oldAttrs.postInstall or "") + ''
    test -f "$out/dtbs/qcom/sm8250-xiaomi-elish-boe.dtb"
    test -f "$out/dtbs/qcom/sm8250-xiaomi-elish-csot.dtb"
  '';
})

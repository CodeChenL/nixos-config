{ lib, pkgs, ... }:

{
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  boot = {
    kernelPackages = lib.mkForce pkgs.linuxPackages-sm8250-elish;
    kernelParams = [ "rootwait" ];

    initrd = {
      includeDefaultModules = false;
      supportedFilesystems.btrfs = true;
      # Linux 7.2 renamed Btrfs crypto modules; btrfs.ko carries the real dependencies.
      availableKernelModules = lib.mkForce [ ];
      systemd.tpm2.enable = false;
      kernelModules = [
        "spi-geni-qcom"
        "nt36523_ts"
        "panel_novatek_nt36523"
      ];
      extraFirmwarePaths = [
        "qcom/a650_sqe.fw"
        "qcom/a650_gmu.bin"
        "qcom/sm8250/xiaomi/elish/a650_zap.mbn"
        "qcom/sm8250/xiaomi/elish/adsp.mbn"
        "qcom/sm8250/xiaomi/elish/adspr.jsn"
        "qcom/sm8250/xiaomi/elish/adspua.jsn"
        "qcom/sm8250/xiaomi/elish/cdsp.mbn"
        "qcom/sm8250/xiaomi/elish/cdspr.jsn"
        "qcom/sm8250/xiaomi/elish/slpi.mbn"
        "qcom/sm8250/xiaomi/elish/slpir.jsn"
        "qcom/sm8250/xiaomi/elish/slpius.jsn"
        "qcom/sm8250/xiaomi/elish/venus.mbn"
        "novatek/nt36523-boe.bin"
        "novatek/nt36523-csot.bin"
      ];
    };

    loader = {
      grub.enable = false;
      systemd-boot.enable = false;
      generic-extlinux-compatible.enable = false;
    };
  };

  hardware.firmware = [
    pkgs.linux-firmware
    pkgs.xiaomi-elish-firmware
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_ROOT";
    fsType = "btrfs";
    autoResize = true;
  };
}

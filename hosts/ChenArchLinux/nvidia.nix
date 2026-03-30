{ config, pkgs, ... }:

{
  # ── NVIDIA 驱动 (开源内核模块) ──────────────────────────────────
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    open = true;
    modesetting.enable = true;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    # PRIME — Intel 核显 + NVIDIA 独显
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      # Intel Arrow Lake 核显 — PCI 总线 00:02.0
      intelBusId = "PCI:0:2:0";
      # NVIDIA RTX 5060 Ti — PCI 总线 01:00.0
      nvidiaBusId = "PCI:1:0:0";
    };

    powerManagement = {
      enable = false;
      finegrained = false;
    };
  };

  # ── 图形加速 / 显卡 ──────────────────────────────────────────────
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      intel-media-driver   # iHD — Intel Arrow Lake
      nvidia-vaapi-driver  # NVIDIA VA-API
    ];
    extraPackages32 = with pkgs.pkgsi686Linux; [
      intel-media-driver
    ];
  };

  # ── 环境变量 ────────────────────────────────────────────────────
  environment.sessionVariables = {
    __NV_DISABLE_EXPLICIT_SYNC = "1";
    KWIN_USE_OVERLAYS = "1";
  };
}

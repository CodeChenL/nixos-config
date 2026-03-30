{ config, pkgs, ... }:

{
  # ── NVIDIA driver (open kernel module) ──────────────────────────
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    open = true;
    modesetting.enable = true;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    # PRIME — Intel iGPU + NVIDIA dGPU
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      # Intel Arrow Lake iGPU — PCI bus 00:02.0
      intelBusId = "PCI:0:2:0";
      # NVIDIA RTX 5060 Ti — PCI bus 01:00.0
      nvidiaBusId = "PCI:1:0:0";
    };

    powerManagement = {
      enable = false;
      finegrained = false;
    };
  };

  # ── OpenGL / Graphics ──────────────────────────────────────────
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

  # ── Environment variables ───────────────────────────────────────
  environment.sessionVariables = {
    __NV_DISABLE_EXPLICIT_SYNC = "1";
    KWIN_USE_OVERLAYS = "1";
  };
}

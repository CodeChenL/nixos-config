{ config, pkgs, ... }:

{
  # ── NVIDIA 驱动 (开源内核模块) ──────────────────────────────────
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    open = true;
    nvidiaSettings = true;
    # 跟随 boot.kernelPackages (unstable 最新内核) 的 NVIDIA 驱动
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    # 显示器直连 NVIDIA，无需 PRIME
    # Intel 核显仍可通过 intel-media-driver 提供 VA-API 硬件解码
  };

  # ── NVIDIA 环境变量 ─────────────────
  environment.variables.__NV_DISABLE_EXPLICIT_SYNC = "1";

  # ── 图形加速 / 显卡 ──────────────────────────────────────────────
  hardware.graphics = {
    enable32Bit = true;
    extraPackages = with pkgs; [
      intel-media-driver   # iHD — Intel Arrow Lake
      nvidia-vaapi-driver  # NVIDIA VA-API
    ];
    extraPackages32 = with pkgs.pkgsi686Linux; [
      intel-media-driver
    ];
  };

}

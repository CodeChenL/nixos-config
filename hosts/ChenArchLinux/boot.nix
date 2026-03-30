{ config, pkgs, ... }:

{
  # ── 引导加载器 (GRUB EFI) ───────────────────────────────────────
  boot.loader = {
    efi.canTouchEfiVariables = true;
    efi.efiSysMountPoint = "/boot";

    grub = {
      enable = true;
      device = "nodev";
      efiSupport = true;
      useOSProber = true;
      default = "saved";
      splashImage = null;

      extraConfig = ''
        GRUB_SAVEDEFAULT=true
      '';

      # 如需 minegrub 主题，可在安装后手动配置或通过 overlay 提供
      # theme = "/boot/grub/themes/minegrub-world-selection";
    };

    timeout = 1;
  };

  # ── 内核 ───────────────────────────────────────────────────────
  boot.kernelPackages = pkgs.linuxPackages_zen;

  boot.kernelParams = [
    "splash"
    "quiet"
    "intel_iommu=on"
    "nvidia_drm.modeset=1"
    "plymouth.debug"
    "loglevel=7"
    "zswap.enabled=0"
    "mitigations=off"
    "usbcore.autosuspend=0"
    "rtw88_core.disable_lps_deep=1"
    "ibt=off"
  ];

  # ── 初始化内存盘 ───────────────────────────────────────────────────
  boot.initrd.systemd.enable = true;

  # ── 开机动画 ─────────────────────────────────────────────────────
  boot.plymouth = {
    enable = true;
    theme = "spinner";
  };

  # ── 额外内核模块配置 ─────────────────────────────────────────────
  boot.extraModprobeConfig = ''
    options cfg80211 ieee80211_regdom=CN
  '';
}

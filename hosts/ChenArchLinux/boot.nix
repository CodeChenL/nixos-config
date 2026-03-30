{ config, pkgs, ... }:

{
  # ── Bootloader (GRUB EFI) ───────────────────────────────────────
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

  # ── Kernel ──────────────────────────────────────────────────────
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

  # ── Initrd ──────────────────────────────────────────────────────
  boot.initrd.systemd.enable = true;

  # ── Plymouth ────────────────────────────────────────────────────
  boot.plymouth = {
    enable = true;
    theme = "spinner";
  };

  # ── Additional kernel modules ───────────────────────────────────
  boot.extraModprobeConfig = ''
    options cfg80211 ieee80211_regdom=CN
  '';
}

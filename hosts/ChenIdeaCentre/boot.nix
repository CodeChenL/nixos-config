{ config, pkgs, ... }:

let
  ch347-vcp = config.boot.kernelPackages.callPackage ../../overlays/ch347-vcp { };
in
{
  # ── 内核 (使用 release 默认内核) ─────────────────────────────────
  boot.kernelPackages = pkgs.linuxPackages;

  boot.extraModulePackages = [ ch347-vcp ];

  # ── 引导加载器 (GRUB EFI) ───────────────────────────────────────
  boot.loader = {
    efi.canTouchEfiVariables = true;

    grub = {
      enable = true;
      device = "nodev";
      efiSupport = true;
      useOSProber = true;
      default = "saved";
      splashImage = null;
      gfxmodeEfi = "1920x1080,auto";
      gfxmodeBios = "1920x1080,auto";
      gfxpayloadEfi = "keep";
      gfxpayloadBios = "keep";

      extraConfig = ''
        GRUB_SAVEDEFAULT=true
      '';

      # 手动添加 Arch Linux 启动项（防止 os-prober 未检测到）
      # search 用 EFI 分区 UUID（内核在此分区），root= 用 Arch 根分区 UUID
      extraEntries = ''
        menuentry "Arch Linux" {
          search --no-floppy --fs-uuid --set=root 511B-0061
          linux /vmlinuz-linux root=UUID=b0ab7171-dd4f-42cf-87e6-6c4958752652 rw
          initrd /initramfs-linux.img
        }
      '';

      # 如需 minegrub 主题，可在安装后手动配置或通过 overlay 提供
      theme = "/boot/grub/themes/minegrub-world-selection";
    };

    timeout = 1;  # 双启动需要足够时间选择
  };

  # ── 内核 ───────────────────────────────────────────────────────
  boot.kernelParams = [
    "loglevel=10"
    "splash"
    "intel_iommu=on"
    "nvidia_drm.modeset=1"
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

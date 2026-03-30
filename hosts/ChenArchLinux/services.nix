{ config, pkgs, ... }:

{
  # ── 时区与 NTP ──────────────────────────────────────────────────
  time.timeZone = "Asia/Shanghai";
  services.timesyncd.enable = true;

  # ── 传感器 ──────────────────────────────────────────────────────
  hardware.sensor.iio.enable = true;

  # ── 硬件温度监控 ─────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    lm_sensors
    solaar
  ];

  # ── 打印 (CUPS) ─────────────────────────────────────────────────
  services.printing = {
    enable = true;
    drivers = [ pkgs.cups-filters ];
  };

  # ── 电源管理 ────────────────────────────────────────────────────
  services.power-profiles-daemon.enable = true;

  # ── USB/IP ──────────────────────────────────────────────────────
  # USB/IP 内核模块
  boot.kernelModules = [ "usbip-host" "vhci-hcd" ];

  # ── Sunshine（远程桌面主机）─────────────────────────────────────
  # Sunshine 需要安装后通过其 Web UI 配置
  # 软件包在用户级包中安装

  # ── Flatpak（国产应用备用）───────────────────────────────────────────
  services.flatpak.enable = true;

  # ── 固件更新 ─────────────────────────────────────────────────────
  services.fwupd.enable = true;

  # ── 磁盘管理（KDE 需要）──────────────────────────────────────────
  services.udisks2.enable = true;

  # ── D-Bus ───────────────────────────────────────────────────────
  services.dbus.enable = true;

  # ── udev rules ──────────────────────────────────────────────────
  # android-udev-rules 已被 systemd 内置 uaccess 规则取代，无需额外配置

  # ── Nix 设置 ─────────────────────────────────────────────────────
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      trusted-users = [ "root" "chen" ];
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  # ── 系统状态版本 ────────────────────────────────────────────────
  system.stateVersion = "24.11";
}

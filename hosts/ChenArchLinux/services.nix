{ config, pkgs, ... }:

{
  # ── Time & NTP ──────────────────────────────────────────────────
  time.timeZone = "Asia/Shanghai";
  services.timesyncd.enable = true;

  # ── Sensors ─────────────────────────────────────────────────────
  hardware.sensor.iio.enable = true;

  # ── lm_sensors ──────────────────────────────────────────────────
  environment.systemPackages = [ pkgs.lm_sensors ];

  # ── Printing (CUPS) ─────────────────────────────────────────────
  services.printing = {
    enable = true;
    drivers = [ pkgs.cups-filters ];
  };

  # ── Power management ────────────────────────────────────────────
  services.power-profiles-daemon.enable = true;

  # ── USB/IP ──────────────────────────────────────────────────────
  # usbip kernel modules
  boot.kernelModules = [ "usbip-host" "vhci-hcd" ];

  # ── Sunrise/Sunshine (remote desktop host) ──────────────────────
  # Sunshine needs to be configured via its web UI after install
  # Package installed in user packages

  # ── Logitech ──────────────────────────────────────────────────
  environment.systemPackages = [ pkgs.solaar ];

  # ── Flatpak (for Chinese apps fallback) ─────────────────────────
  services.flatpak.enable = true;

  # ── Firmware update ─────────────────────────────────────────────
  services.fwupd.enable = true;

  # ── Udisks (disk management for KDE) ────────────────────────────
  services.udisks2.enable = true;

  # ── D-Bus ───────────────────────────────────────────────────────
  services.dbus.enable = true;

  # ── udev rules ──────────────────────────────────────────────────
  services.udev.packages = with pkgs; [
    android-udev-rules
  ];

  # ── Nix settings ────────────────────────────────────────────────
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

  # ── System state version ────────────────────────────────────────
  system.stateVersion = "24.11";
}

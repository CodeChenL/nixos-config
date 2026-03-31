{ config, pkgs, lib, ... }:

{
  imports = [
    ./common.nix
    ./packages.nix
  ];

  # Yakuake 开机自启（用户级 XDG autostart）
  xdg.configFile."autostart/org.kde.yakuake.desktop".source =
    "${pkgs.kdePackages.yakuake}/share/applications/org.kde.yakuake.desktop";
}

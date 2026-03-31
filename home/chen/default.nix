{ config, pkgs, lib, ... }:

{
  imports = [
    ./shell.nix
    ./git.nix
    ./ssh.nix
    ./packages.nix
    ./dev.nix
  ];

  home.username = "chen";
  home.homeDirectory = "/home/chen";
  home.stateVersion = "24.11";

  # 让 Home Manager 管理自身
  programs.home-manager.enable = true;

  # ── 环境变量 ────────────────────────────────────────────────────
  home.sessionVariables = {
    EDITOR = "vim";
    LANGUAGE = "en_US";
  };

  # ── XDG 目录 ─────────────────────────────────────────────────────
  xdg.enable = true;

  # Yakuake 开机自启（用户级 XDG autostart）
  xdg.configFile."autostart/org.kde.yakuake.desktop".source =
    "${pkgs.kdePackages.yakuake}/share/applications/org.kde.yakuake.desktop";
}

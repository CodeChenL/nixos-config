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
}

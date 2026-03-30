{ config, pkgs, lib, ... }:

{
  imports = [
    ./shell.nix
    ./git.nix
    ./packages.nix
    ./dev.nix
  ];

  home.username = "chen";
  home.homeDirectory = "/home/chen";
  home.stateVersion = "24.11";

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  # ── Environment variables ───────────────────────────────────────
  home.sessionVariables = {
    EDITOR = "vim";
    LANGUAGE = "en_US";
  };

  # ── XDG directories ────────────────────────────────────────────
  xdg.enable = true;
}

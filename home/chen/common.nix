{ config, pkgs, lib, ... }:

{
  imports = [
    ./shell.nix
    ./git.nix
    ./ssh.nix
    ./dev.nix
  ];

  home.username = "chen";
  home.homeDirectory = "/home/chen";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  programs.gpg.enable = true;

  home.sessionVariables = {
    EDITOR = "vim";
    LANGUAGE = "en_US";
    PKG_CONFIG_PATH = "${config.home.profileDirectory}/lib/pkgconfig:${config.home.profileDirectory}/share/pkgconfig";
  };

  home.file.".claude/skills" = {
    source = ../../skills;
    recursive = true;
  };

  xdg.enable = true;
}

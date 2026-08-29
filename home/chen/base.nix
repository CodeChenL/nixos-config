{ config, pkgs, ... }:

{
  imports = [
    ./shell.nix
    ./git.nix
    ./ssh.nix
    ./opencode.nix
  ];

  home.username = "chen";
  home.homeDirectory = "/home/chen";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  programs.gpg.enable = true;
  programs.htop.enable = true;

  home.sessionVariables = {
    EDITOR = "vim";
    # 注意：不在此处设置 LANGUAGE / LANG。
    # 全局 sessionVariables 会被注入 systemd user session，KDE 会话会继承，
    # 从而覆盖 plasma-localerc 里的 Translations.LANGUAGE（KDE UI 语言）。
    # SSH/终端 shell 的英文环境由 shell.nix 的 profileExtra 单独 export。
    PKG_CONFIG_PATH = "${config.home.profileDirectory}/lib/pkgconfig:${config.home.profileDirectory}/share/pkgconfig";
  };

  home.file.".claude/skills" = {
    source = pkgs.claude-skills;
    recursive = true;
  };
  home.file.".agents/skills".source = pkgs.claude-skills;
  home.packages = [ pkgs.tcpdump ];
  xdg.enable = true;
  xdg.configFile."htop/htoprc".source = ./htoprc;
}

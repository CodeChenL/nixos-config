{ config, pkgs, lib, ... }:

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

  # htoprc: declare the baseline in the repo, but deploy it as a writable copy.
  # The XDG config source above would create a read-only /nix/store symlink that
  # htop cannot overwrite when settings change in the UI. Instead, install the
  # declared file as a regular file, and only replace it when it is still the
  # managed symlink or does not exist, so user tweaks survive a rebuild.
  home.activation.writeHtoprc = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    target="$HOME/.config/htop/htoprc"
    ${pkgs.coreutils}/bin/mkdir -p "$(dirname "$target")"
    if [ ! -e "$target" ]; then
      ${pkgs.coreutils}/bin/install -m 600 ${./htoprc} "$target"
    elif [ -L "$target" ]; then
      ${pkgs.coreutils}/bin/rm -f "$target"
      ${pkgs.coreutils}/bin/install -m 600 ${./htoprc} "$target"
      echo "htop: replaced read-only symlink with writable htoprc copy"
    fi
  '';
}

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
  home.stateVersion = "24.11";

  programs.home-manager.enable = true;

  home.sessionVariables = {
    EDITOR = "vim";
    LANGUAGE = "en_US";
  };

  xdg.enable = true;

  # WSL 专用的精简包列表（仅 CLI 工具）
  home.packages = with pkgs; [
    # ── 代理 / VPN ─────────────────────────────────────────────
    wireguard-tools
    proxychains-ng

    # ── 下载 ───────────────────────────────────────────────────
    aria2
    axel

    # ── 网络工具 ───────────────────────────────────────────────
    nmap
    iperf3
    traceroute
    bind
    inetutils
    net-tools

    # ── 系统监控 ───────────────────────────────────────────────
    btop
    sysstat

    # ── 文件工具 ────────────────────────────────────────────────
    bat
    dust
    yazi
    vifm
    lazygit
    tmux
    fastfetch
    most
    bc
    pv
    dos2unix
    mmv
    rsync

    # ── 压缩工具 ─────────────────────────────────────────────────
    lrzip
    lzip
    lzop
    cpio

    # ── 其他 CLI ────────────────────────────────────────────────
    shellcheck
    yamlfmt
  ];
}

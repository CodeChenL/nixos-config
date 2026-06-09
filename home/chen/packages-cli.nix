{ pkgs, ... }:

{
  home.packages = with pkgs; [
    # ── AI CLI ──────────────────────────────────────────────────
    github-copilot-cli
    radxa-linkr-debuggerctl
    unstable.opencode
    poppler-utils
    qpdf
    mupdf

    # ── 代理 / VPN ─────────────────────────────────────────────
    wireguard-tools
    proxychains-ng
    natfrp-service

    # ── 下载 ───────────────────────────────────────────────────
    aria2
    axel
    baidupcs-go

    # ── 网络工具 ───────────────────────────────────────────────
    nmap
    iperf3
    traceroute
    bind
    inetutils
    net-tools
    sshpass

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
    ripgrep

    # ── 压缩工具 ─────────────────────────────────────────────────
    lrzip
    lzip
    lzop
    cpio

    # ── 其他 CLI ────────────────────────────────────────────────
    shellcheck
    yamlfmt
    b4
    public-inbox
    debian-devscripts
    dpkg
  ];
}

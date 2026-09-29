{ pkgs, ... }:

{
  # Antigravity CLI（Google 的 Go TUI agent 客户端，命令名 agy）。
  # nixpkgs-unstable 已打包（stable 26.05 尚无），走 HM 声明式模块以便
  # 后续 settings/skills/MCP 全部进 Nix。注意：agy 本体在 /nix/store 只读，
  # 官方 install.sh 的自升级路径（~/.local/bin）天然失效，无需额外禁用。
  programs.antigravity-cli = {
    enable = true;
    package = pkgs.unstable.antigravity-cli;
  };

  home.packages = with pkgs; [
    # ── AI CLI ──────────────────────────────────────────────────
    radxa-linkr-debuggerctl
    unstable.opencode
    unstable.opencode-desktop
    unstable.codex
    pkgs.llm-agents.dsh
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
    ast-grep

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
    rustty
  ];
}

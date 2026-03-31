{ config, pkgs, ... }:

{
  home.packages = with pkgs; [
    # ── 浏览器 ────────────────────────────────────────────────
    firefox
    microsoft-edge

    # ── 通讯 ─────────────────────────────────────────────────
    feishu
    telegram-desktop
    qq                         # linuxqq
    wechat-uos                 # 微信
    element-desktop
    thunderbird

    # ── 办公 ──────────────────────────────────────────────────
    libreoffice-fresh

    # ── 媒体 ──────────────────────────────────────────────────
    obs-studio
    gimp
    darktable
    rawtherapee
    haruna
    mediainfo
    ffmpeg-full

    # ── 游戏 ──────────────────────────────────────────────────
    # Steam 在系统级配置 (programs.steam)
    # proton-ge-bin 通过 Steam 的 Proton 管理或 ProtonUp-Qt 安装
    moonlight-qt
    mangohud
    protonup-qt
    wineWow64Packages.stable
    dxvk

    # ── 3D 打印 / CAD ─────────────────────────────────────────────
    orca-slicer
    freecad
    kicad
    librecad

    # ── 远程桌面 ──────────────────────────────────────────────
    remmina
    freerdp
    scrcpy
    rustdesk
    putty

    # ── 代理 / VPN ─────────────────────────────────────────────
    clash-verge-rev
    wireguard-tools
    proxychains-ng

    # ── 下载 ───────────────────────────────────────────────────
    aria2
    axel

    # ── 网络工具 ───────────────────────────────────────────────
    nmap
    iperf3
    traceroute
    aircrack-ng
    bind          # dig, nslookup
    inetutils
    net-tools
    wakeonlan

    # ── 系统监控 ───────────────────────────────────────────────
    btop
    s-tui
    sysstat
    i7z
    unstable.linuxPackages_latest.cpupower
    intel-gpu-tools

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
    meld
    grsync

    # ── 压缩工具 ─────────────────────────────────────────────────
    lrzip
    lzip
    lzop
    cpio

    # ── 磁盘 / 文件系统 ───────────────────────────────────────────
    hdparm
    gptfdisk
    dosfstools
    exfatprogs
    squashfsTools
    ventoy
    testdisk
    foremost
    cdrtools
    wimlib
    mtools
    read-edid

    # ── 硬件工具 ─────────────────────────────────────────────────
    lshw
    evtest
    picocom
    minicom

    # ── 多媒体 CLI ────────────────────────────────────────────
    asciinema
    optipng
    gnuplot

    # ── 其他 CLI ────────────────────────────────────────────────
    # expac 是 Arch 专用工具，NixOS 中使用 nix-index 替代
    efibootmgr
    shellcheck
    yamlfmt
    yq
    pandoc

    # ── Ollama (AI) ─────────────────────────────────────────────
    ollama
  ];
}

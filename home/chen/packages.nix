{ config, pkgs, inputs, osConfig ? { }, ... }:

{
  imports = [ ./packages-cli.nix ];

  home.packages = with pkgs; [
    # ── 浏览器 ────────────────────────────────────────────────
    firefox
    microsoft-edge

    # ── 下载 ───────────────────────────────────────────────────
    freedownloadmanager

    # ── 通讯 ─────────────────────────────────────────────────
    pkgs.nur.repos.xddxdd.dingtalk
    feishu
    telegram-desktop
    master.qq                         # linuxqq
    unstable.wechat                 # 微信
    element-desktop
    thunderbird

    # ── 办公 ──────────────────────────────────────────────────
    libreoffice-fresh
    wpsoffice-cn

    # ── 媒体 ──────────────────────────────────────────────────
    obs-studio
    gimp
    darktable
    rawtherapee
    haruna
    mediainfo
    ffmpeg-full
    mpv
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-good

    # ── 游戏 ──────────────────────────────────────────────────
    # Steam 在系统级配置 (programs.steam)
    # proton-ge-bin 通过 Steam 的 Proton 管理或 ProtonUp-Qt 安装
    moonlight-qt
    mangohud
    protonup-qt
    wineWow64Packages.stable
    winetricks
    dxvk

    # ── 3D 打印 / CAD ─────────────────────────────────────────────
    bambu-studio
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

    # ── 代理 / VPN（桌面专用）──────────────────────────────────
    clash-verge-rev

    # ── 网络工具（桌面专用）──────────────────────────────────────
    aircrack-ng
    wakeonlan

    # ── 系统监控（桌面专用）──────────────────────────────────────
    s-tui
    i7z
    linuxPackages_latest.cpupower
    intel-gpu-tools

    # ── 文件工具（桌面专用）──────────────────────────────────────
    meld
    grsync

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
    v4l-utils
    picocom
    minicom

    # ── 多媒体 CLI ────────────────────────────────────────────
    asciinema
    optipng
    gnuplot

    # ── 其他 CLI（桌面专用）──────────────────────────────────────
    efibootmgr
    kdotool
    libnotify
    yq
    jq
    pandoc

    # ── Ollama (AI) ─────────────────────────────────────────────
    ollama
  ] ++ pkgs.lib.optionals (!(osConfig.services.linyaps.enable or false)) [
    # 容器化应用运行环境
    linyaps
  ];
}

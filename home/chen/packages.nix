{ config, pkgs, ... }:

{
  home.packages = with pkgs; [
    # ── Browsers ────────────────────────────────────────────────
    firefox
    microsoft-edge

    # ── Communication ───────────────────────────────────────────
    telegram-desktop
    qq                         # linuxqq
    wechat-uos                 # wechat-universal-bwrap equivalent
    element-desktop

    # ── Office ──────────────────────────────────────────────────
    libreoffice-fresh

    # ── Media ───────────────────────────────────────────────────
    obs-studio
    gimp
    darktable
    rawtherapee
    haruna
    mediainfo
    ffmpeg-full

    # ── Gaming ──────────────────────────────────────────────────
    # Steam is system-level (programs.steam)
    moonlight-qt
    mangohud
    proton-ge-bin
    wine
    winetricks
    dxvk

    # ── 3D Printing / CAD ───────────────────────────────────────
    orca-slicer
    freecad
    kicad
    librecad

    # ── Remote desktop ──────────────────────────────────────────
    remmina
    freerdp
    scrcpy
    rustdesk
    putty
    moonlight-qt

    # ── Proxy / VPN ─────────────────────────────────────────────
    clash-verge-rev
    wireguard-tools
    proxychains-ng

    # ── Download ────────────────────────────────────────────────
    aria2
    axel

    # ── Network tools ───────────────────────────────────────────
    nmap
    iperf3
    traceroute
    aircrack-ng
    bind          # dig, nslookup
    inetutils
    net-tools
    wakeonlan

    # ── System monitoring ───────────────────────────────────────
    btop
    htop
    s-tui
    sysstat
    i7z
    cpupower
    intel-gpu-tools

    # ── File tools ──────────────────────────────────────────────
    bat
    dust
    yazi
    vifm
    lazygit
    tmux
    neofetch
    most
    bc
    pv
    dos2unix
    mmv
    rsync
    meld
    grsync

    # ── Archive ──────────────────────────────────────────────────
    lrzip
    lzip
    lzop
    cpio

    # ── Disk / FS ───────────────────────────────────────────────
    hdparm
    gptfdisk
    dosfstools
    exfatprogs
    squashfs-tools
    ventoy
    testdisk
    foremost
    cdrtools
    wimlib
    mtools
    patchelf
    read-edid

    # ── Hardware ──────────────────────────────────────────────────
    lshw
    evtest
    picocom
    minicom
    usbutils
    pciutils

    # ── Multimedia CLI ──────────────────────────────────────────
    asciinema
    optipng
    gnuplot

    # ── Misc CLI ────────────────────────────────────────────────
    expac
    fwupd
    efibootmgr
    shellcheck
    yamlfmt
    yq
    pandoc

    # ── Ollama (AI) ─────────────────────────────────────────────
    ollama
  ];
}

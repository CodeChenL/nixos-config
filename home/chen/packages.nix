{ config, pkgs, inputs, ... }:

let
  copilot-api = pkgs.buildNpmPackage rec {
    pname = "copilot-api";
    version = "0.7.0";

    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
      hash = "sha256-H8z9K/6L+74AwapTX/uitxMfx7yR64MOPUx4v+TwYiA=";
    };

    sourceRoot = "package";
    patches = [ ../../overlays/copilot-api-refresh-retry.patch ];
    postPatch = ''
      cp ${../../overlays/copilot-api-package-lock.json} package-lock.json
    '';

    npmDepsHash = "sha256-WJTnG9xeyRnExMe26nIjF0ehOfEj+aCPF7SCu6LkJe0=";
    dontNpmBuild = true;
    npmFlags = [ "--ignore-scripts" ];
    npmPackFlags = [ "--ignore-scripts" ];

    meta = {
      description = "Turn GitHub Copilot into OpenAI/Anthropic API compatible server";
      homepage = "https://github.com/ericc-ch/copilot-api";
      license = pkgs.lib.licenses.mit;
      mainProgram = "copilot-api";
    };
  };
in

{
  imports = [ ./packages-cli.nix ];

  home.packages = with pkgs; [
    # AI Tools
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.cc-switch-cli
    copilot-api

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

    # ── 代理 / VPN（桌面专用）──────────────────────────────────
    clash-verge-rev

    # ── 网络工具（桌面专用）──────────────────────────────────────
    aircrack-ng
    wakeonlan

    # ── 系统监控（桌面专用）──────────────────────────────────────
    s-tui
    i7z
    unstable.linuxPackages_latest.cpupower
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
    picocom
    minicom

    # ── 多媒体 CLI ────────────────────────────────────────────
    asciinema
    optipng
    gnuplot

    # ── 其他 CLI（桌面专用）──────────────────────────────────────
    efibootmgr
    yq
    pandoc

    # ── Ollama (AI) ─────────────────────────────────────────────
    ollama
  ];
}

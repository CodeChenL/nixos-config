{ config, pkgs, lib, inputs, osConfig ? { }, ... }:

let
  codexDesktopLinuxFeatures = [
    "appshots"
    "api-key-model-visibility"
    "api-key-service-tier"
    "codex-micro"
    "codex-wrapper-updater"
    "directory-only-working-tree-watch"
    "frameless-titlebar"
    "global-dictation"
    "mcp-helper-reaper"
    "node-repl-reaper"
    "open-target-discovery"
    "persistent-status-panel"
    "pet-overlay"
    "remote-control-ui"
    "remote-mobile-control"
    "ssh-command-wrapper"
    "ui-tweaks"
  ];
  # Keep the authored ZIP in the flake so theme changes are reproducible and
  # do not depend on a runtime DreamSkin download/import. The package still
  # declares Windows/macOS, so the Linux adapter keeps the explicit mismatch
  # override below instead of mutating the upstream manifest.
  oneLastKissDreamSkinPackage = ./codex-themes/i-think-you-should-just-laugh-0.0.1.zip;
  codexDesktopPackage = pkgs."codex-desktop-api-key" {
    linuxFeatureIds = codexDesktopLinuxFeatures;
    enableComputerUseUi = true;
    # 仅解锁上游已有的 Ultra catalog/slider gates。
    enableApiKeyUltraUiPatch = true;
    dreamSkinThemePackage = oneLastKissDreamSkinPackage;
    dreamSkinAllowPlatformMismatch = true;
  };
  dshPackage = pkgs.llm-agents.dsh;
  dshHome = "${config.home.homeDirectory}/.dsh";
  dshReconciler = ./dsh/reconcile.mjs;
  dshSecretsDir = "${config.home.homeDirectory}/nixos-config/secrets/opencode";
  dshAtomicWriteModule = "${dshPackage}/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-atomic-write/lib/index.js";
  dshYamlModule = "${dshPackage}/lib/node_modules/@deepseek-ai/dsh/node_modules/yaml/dist/index.js";
  dshSettingsJson = pkgs.writeText "dsh-settings.json" (builtins.toJSON {
    "agent-default-model" = {
      provider = "deepseek-official";
      model = "deepseek-v4-flash";
      reasoningEffort = "max";
    };

    "ui-conversation".busyEnter = "steer";

    # Sub2API OpenAI passthrough must remain disabled for Responses API compatibility.
    "llm-pi-ai".providers.openai = {
      baseURL = "http://chenjaly.cn:8080/v1";
      apiKeyEnv = "OPENAI_API_KEY";
    };

    # Kimi For Coding（pi-ai 内置 catalog 路由，端点/模型随 catalog）
    "llm-pi-ai".providers."kimi-coding" = {
      apiKeyEnv = "KIMI_CODING_API_KEY";
    };

    # Xiaomi Token Plan (CN)
    "llm-pi-ai".providers."xiaomi-token-plan-cn" = {
      apiKeyEnv = "XIAOMI_TOKEN_PLAN_CN_API_KEY";
    };

    # MiniMax (CN)
    "llm-pi-ai".providers."minimax-cn" = {
      apiKeyEnv = "MINIMAX_CN_API_KEY";
    };
  });
in

{
  imports = [
    ./packages-cli.nix
    ./codex
    inputs.codex-desktop-linux.homeManagerModules.default
  ];

  # ── Codex Desktop（仅此桌面主机）──────────────────────────────────
  programs.codexDesktopLinux = {
    enable = true;
    package = codexDesktopPackage;
    cliPackage = pkgs.llm-agents.codex;
  };

  systemd.user.services.dsh-web = {
    Unit = {
      Description = "DeepSeek Harness Web";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      StartLimitBurst = 5;
      StartLimitIntervalSec = 60;
    };

    Service = {
      ExecStart = "${dshPackage}/bin/dsh web --host 127.0.0.1 --port 3080";
      WorkingDirectory = config.home.homeDirectory;
      Restart = "always";
      RestartSec = 5;
      TimeoutStartSec = 30;
      TimeoutStopSec = 10;
      KillMode = "control-group";
      Environment = [
        "HOME=${config.home.homeDirectory}"
        "DSH_HOME=${dshHome}"
      ];
    };

    Install.WantedBy = [ "default.target" ];
  };

  home.activation.dshConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.nodejs}/bin/node ${lib.escapeShellArgs [
      "${dshReconciler}"
      "--dsh-home" dshHome
      "--settings-json" dshSettingsJson
      "--secrets-dir" dshSecretsDir
      "--atomic-write-module" dshAtomicWriteModule
      "--yaml-module" dshYamlModule
    ]}
  '';

  home.packages = with pkgs; [
    # ── 浏览器 ────────────────────────────────────────────────
    firefox
    google-chrome
    chromium
    microsoft-edge

    # ── 下载 ───────────────────────────────────────────────────
    freedownloadmanager

    # ── 通讯 ─────────────────────────────────────────────────
    pkgs.nur.repos.xddxdd.dingtalk
    feishu
    telegram-desktop
    (master.qq.overrideAttrs (_: {
      version = "3.2.32-2026-07-30";
      src = fetchurl {
        url = "https://qqdl.gtimg.cn/qqfile/QQNT/9.9.33/release/c97651b2/QQ_3.2.32_260730_amd64_01.deb";
        hash = "sha256-ga4rhULvUxH8cuz1PJpSOSPINFacew2lLgv0Nguctfk=";
      };
    })) # linuxqq
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
    e2fsprogs
    exfatprogs
    squashfsTools
    ventoy
    testdisk
    foremost
    cdrtools
    wimlib
    mtools
    multipath-tools
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

    # ── AI / LLM ─────────────────────────────────────────────────
    ollama
    llama-cpp-full  # llama.cpp with OpenVINO, CUDA, Vulkan, OpenCL, BLAS support
  ] ++ pkgs.lib.optionals (!(osConfig.services.linyaps.enable or false)) [
    # 容器化应用运行环境
    linyaps
  ];
}

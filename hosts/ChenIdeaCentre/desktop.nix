{ config, lib, pkgs, inputs, ... }:

let
  kwallet5Compat = pkgs.runCommand "kwallet5-compat" { } ''
    mkdir -p $out/bin
    ln -s ${lib.getBin pkgs.kdePackages.kwallet}/bin/kwalletd6 $out/bin/kwalletd5
    ln -s ${lib.getBin pkgs.kdePackages.kwallet}/bin/kwalletd6 $out/bin/kwalletd
  '';

  vinputPackage = inputs.fcitx5-vinput.packages.${pkgs.stdenv.hostPlatform.system}.default;

  fontAliases = [
    { from = "Source Han Sans SC"; prefer = [ "Source Han Sans SC" ]; }
    { from = "思源黑体"; prefer = [ "Source Han Sans SC" ]; }
    { from = "Source Han Serif SC"; prefer = [ "Source Han Serif SC" ]; }
    { from = "思源宋体"; prefer = [ "Source Han Serif SC" ]; }
    { from = "SimSun"; prefer = [ "Source Han Serif SC" ]; }
    { from = "宋体"; prefer = [ "Source Han Serif SC" ]; }
    { from = "SimHei"; prefer = [ "Source Han Sans SC" ]; }
    { from = "黑体"; prefer = [ "Source Han Sans SC" ]; }
    { from = "Microsoft YaHei"; prefer = [ "Source Han Sans SC" ]; }
    { from = "微软雅黑"; prefer = [ "Source Han Sans SC" ]; }
    { from = "KaiTi"; prefer = [ "Source Han Serif SC" ]; }
    { from = "楷体"; prefer = [ "Source Han Serif SC" ]; }
    { from = "FangSong"; prefer = [ "Source Han Serif SC" ]; }
    { from = "仿宋"; prefer = [ "Source Han Serif SC" ]; }
    { from = "DengXian"; prefer = [ "Source Han Sans SC" ]; }
    { from = "等线"; prefer = [ "Source Han Sans SC" ]; }
    { from = "FZShuSong"; prefer = [ "Source Han Serif SC" ]; }
    { from = "FZHei"; prefer = [ "Source Han Sans SC" ]; }
    { from = "FZKai"; prefer = [ "Source Han Serif SC" ]; }
    { from = "FZFangSong"; prefer = [ "Source Han Serif SC" ]; }
    { from = "Symbol"; prefer = [ "Noto Sans Symbols" ]; }
    { from = "sans-serif"; prefer = [ "Source Han Sans SC" "Noto Sans CJK SC" "Noto Sans" ]; }
    { from = "serif"; prefer = [ "Source Han Serif SC" "Noto Serif CJK SC" "Noto Serif" ]; }
  ];
in

{
  # ── KDE Plasma 6 (Wayland) 桌面环境 ─────────────────────────────────
  services.desktopManager.plasma6.enable = true;

  services.displayManager = {
    sddm = {
      enable = true;
      wayland.enable = true;
      theme = "breeze";
      settings = {
        General.Numlock = "on";
        Theme = {
          CursorTheme = "breeze_cursors";
          Font = "Ubuntu Mono,18,-1,5,600,0,0,0,0,0,0,0,0,0,0,1,SemiBold";
        };
      };
    };

    autoLogin = {
      enable = true;
      user = "chen";
    };
  };

  # ── PipeWire 音频 ───────────────────────────────────────────────
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  security.rtkit.enable = true;

  systemd.user.services.vinput-daemon = {
    description = "Fcitx5 VInput daemon";
    after = [ "pipewire.service" ];
    wantedBy = [ "default.target" ];

    serviceConfig = {
      Type = "dbus";
      BusName = "org.fcitx.Vinput";
      ExecStart = "${vinputPackage}/bin/vinput-daemon";
    };
  };

  # ── 蓝牙 ───────────────────────────────────────────────────────
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Experimental = true;
        KernelExperimental = true;
      };
    };
  };

  # ── Fcitx5 中文输入法 ─────────────────────────────────────────
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.addons = with pkgs; [
      qt6Packages.fcitx5-chinese-addons
      fcitx5-gtk
      fcitx5-lua
      fcitx5-pinyin-moegirl
      fcitx5-pinyin-zhwiki
      vinputPackage
    ];
    fcitx5.waylandFrontend = true;
  };

  # ── 字体 ───────────────────────────────────────────────────────
  fonts = {
    enableDefaultPackages = true;
    packages = with pkgs; [
      # 中日韩字体
      source-han-sans       # Adobe 思源黑体（字族名: Source Han Sans SC）
      source-han-serif      # Adobe 思源宋体
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      wqy_microhei
      wqy_zenhei

      # 西文 / 等宽字体
      noto-fonts
      noto-fonts-color-emoji
      dejavu_fonts
      liberation_ttf
      fira-code
      fira-mono
      fira
      ubuntu-classic

      # Nerd Fonts
      nerd-fonts.fira-code
      nerd-fonts.fira-mono
    ];

    fontconfig = {
      defaultFonts = {
        serif = [ "Source Han Serif SC" "Noto Serif CJK SC" "Noto Serif" ];
        sansSerif = [ "Source Han Sans SC" "Noto Sans CJK SC" "Noto Sans" ];
        monospace = [ "FiraCode Nerd Font Mono" "Fira Code" "Noto Sans Mono" ];
        emoji = [ "Noto Color Emoji" ];
      };

      localConf = ''
        <?xml version="1.0"?>
        <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
        <fontconfig>
          ${lib.concatMapStringsSep "\n" (alias: ''
            <alias>
              <family>${alias.from}</family>
              <prefer>${lib.concatMapStringsSep "\n" (font: "              <family>${font}</family>") alias.prefer}</prefer>
            </alias>
          '') fontAliases}
        </fontconfig>
      '';
    };
  };

  # ── 语言与国际化 ────────────────────────────────────────────────
  # 系统默认英文（SSH/非 KDE 程序英文）；区域格式用中国标准（日期/货币/度量等）。
  # KDE 桌面 UI 的中文翻译由 home-manager 的 plasma-localerc 单独控制，
  # 不受此处 defaultLocale 影响（NixOS 下 KDE 系统设置页 locale 功能已损坏）。
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocales = [ "zh_CN.UTF-8/UTF-8" ];
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "zh_CN.UTF-8";
    LC_IDENTIFICATION = "zh_CN.UTF-8";
    LC_MEASUREMENT = "zh_CN.UTF-8";
    LC_MONETARY = "zh_CN.UTF-8";
    LC_NAME = "zh_CN.UTF-8";
    LC_NUMERIC = "zh_CN.UTF-8";
    LC_PAPER = "zh_CN.UTF-8";
    LC_TELEPHONE = "zh_CN.UTF-8";
    LC_TIME = "zh_CN.UTF-8";
  };

  # ── KDE 额外应用 ──────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    kmscube
    libdrm
    mesa-demos
    vulkan-tools
    kdePackages.kdeconnect-kde
    kdePackages.sddm-kcm
    kdePackages.yakuake
    kdePackages.wallpaper-engine-plugin
    kwallet5Compat
    vinputPackage
  ];

  environment.sessionVariables = {
    # 输入法
    XMODIFIERS = "@im=fcitx";
    SDL_IM_MODULE = "fcitx";
    GLFW_IM_MODULE = "ibus";
  };
}

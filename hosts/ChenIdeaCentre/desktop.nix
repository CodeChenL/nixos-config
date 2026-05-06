{ config, lib, pkgs, ... }:

let
  baseXwayland = pkgs.xwayland.override {
    defaultFontPath = lib.optionalString config.fonts.fontDir.enable "/run/current-system/sw/share/X11/fonts";
  };

  xwaylandWithMoreClients = pkgs.symlinkJoin {
    name = "xwayland-maxclients";
    paths = [ baseXwayland ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      rm $out/bin/Xwayland
      makeWrapper ${baseXwayland}/bin/Xwayland $out/bin/Xwayland \
        --add-flags "-maxclients 512"
    '';
  };

  kwallet5Compat = pkgs.runCommand "kwallet5-compat" { } ''
    mkdir -p $out/bin
    ln -s ${lib.getBin pkgs.libsForQt5.kwallet}/bin/kwalletd5 $out/bin/kwalletd5
    ln -s ${lib.getBin pkgs.libsForQt5.kwallet}/bin/kwalletd5 $out/bin/kwalletd
  '';
in

{
  # ── KDE Plasma 6 (Wayland) 桌面环境 ─────────────────────────────────
  services.desktopManager.plasma6.enable = true;
  programs.xwayland.package = xwaylandWithMoreClients;

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
    ];
    fcitx5.waylandFrontend = true;
  };

  # ── 字体 ───────────────────────────────────────────────────────
  fonts = {
    enableDefaultPackages = true;
    packages = with pkgs; [
      # 中日韩字体
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
        serif = [ "Noto Serif CJK SC" "Noto Serif" ];
        sansSerif = [ "Noto Sans CJK SC" "Noto Sans" ];
        monospace = [ "FiraCode Nerd Font Mono" "Fira Code" "Noto Sans Mono" ];
        emoji = [ "Noto Color Emoji" ];
      };
    };
  };

  # ── 语言与国际化 ────────────────────────────────────────────────
  i18n.defaultLocale = "en_US.UTF-8";
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
    kdePackages.sddm-kcm
    kdePackages.yakuake
    kdePackages.wallpaper-engine-plugin
    kwallet5Compat
  ];

  environment.sessionVariables = {
    # 输入法
    XMODIFIERS = "@im=fcitx";
    SDL_IM_MODULE = "fcitx";
    GLFW_IM_MODULE = "ibus";
  };
}

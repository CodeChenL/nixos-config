{ lib, pkgs, ... }:

let
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
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
  security.rtkit.enable = true;

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings.General = {
      Experimental = true;
      KernelExperimental = true;
    };
  };

  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5 = {
      addons = with pkgs; [
        qt6Packages.fcitx5-chinese-addons
        fcitx5-gtk
        fcitx5-lua
        fcitx5-pinyin-moegirl
        fcitx5-pinyin-zhwiki
      ];
      waylandFrontend = true;
    };
  };

  fonts = {
    enableDefaultPackages = true;
    packages = with pkgs; [
      source-han-sans
      source-han-serif
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      wqy_microhei
      wqy_zenhei
      noto-fonts
      noto-fonts-color-emoji
      dejavu_fonts
      liberation_ttf
      fira-code
      fira-mono
      fira
      ubuntu-classic
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

  environment.sessionVariables = {
    XMODIFIERS = "@im=fcitx";
    SDL_IM_MODULE = "fcitx";
    GLFW_IM_MODULE = "ibus";
  };
}

{ config, pkgs, ... }:

{
  # ── KDE Plasma 6 (Wayland) ─────────────────────────────────────
  services.desktopManager.plasma6.enable = true;

  services.displayManager = {
    sddm = {
      enable = true;
      wayland.enable = true;
      theme = "breeze";
      settings = {
        General = {
          Numlock = "on";
          HaltCommand = "/run/current-system/sw/bin/systemctl poweroff";
          RebootCommand = "/run/current-system/sw/bin/systemctl reboot";
        };
        Theme = {
          CursorTheme = "breeze_cursors";
          Font = "Ubuntu Mono,18,-1,5,600,0,0,0,0,0,0,0,0,0,0,1,SemiBold";
        };
        Users = {
          MaximumUid = 60513;
          MinimumUid = 1000;
        };
      };
    };

    autoLogin = {
      enable = true;
      user = "chen";
    };
  };

  # ── PipeWire (audio) ───────────────────────────────────────────
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
  };
  # Disable PulseAudio (replaced by PipeWire)
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;

  # ── Bluetooth ──────────────────────────────────────────────────
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # ── Fcitx5 (Chinese input) ─────────────────────────────────────
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.addons = with pkgs; [
      fcitx5-chinese-addons
      fcitx5-gtk
      fcitx5-lua
      fcitx5-pinyin-moegirl
      fcitx5-pinyin-zhwiki
    ];
    fcitx5.waylandFrontend = true;
  };

  # ── Fonts ──────────────────────────────────────────────────────
  fonts = {
    enableDefaultPackages = true;
    packages = with pkgs; [
      # CJK
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      wqy_microhei
      wqy_zenhei

      # Latin / Mono
      noto-fonts
      noto-fonts-emoji
      dejavu_fonts
      liberation_ttf
      fira-code
      fira-mono
      fira
      ubuntu_font_family

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

  # ── XDG portal (for Wayland screen sharing etc.) ────────────────
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-kde ];
  };

  # ── Locale & i18n ──────────────────────────────────────────────
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

  environment.sessionVariables = {
    XMODIFIERS = "@im=fcitx";
    SDL_IM_MODULE = "fcitx";
    GLFW_IM_MODULE = "ibus";
  };
}

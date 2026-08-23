{ config, lib, pkgs, inputs, ... }:

let
  kwallet5Compat = pkgs.runCommand "kwallet5-compat" { } ''
    mkdir -p $out/bin
    ln -s ${lib.getBin pkgs.kdePackages.kwallet}/bin/kwalletd6 $out/bin/kwalletd5
    ln -s ${lib.getBin pkgs.kdePackages.kwallet}/bin/kwalletd6 $out/bin/kwalletd
  '';

  vinputPackage = inputs.fcitx5-vinput.packages.${pkgs.stdenv.hostPlatform.system}.default;
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

          <!-- WPS Office: 思源黑体 → Source Han Sans SC -->
          <alias>
            <family>Source Han Sans SC</family>
            <prefer><family>Source Han Sans SC</family></prefer>
          </alias>
          <alias>
            <family>思源黑体</family>
            <prefer><family>Source Han Sans SC</family></prefer>
          </alias>

          <!-- WPS Office: 思源宋体 → Source Han Serif SC -->
          <alias>
            <family>Source Han Serif SC</family>
            <prefer><family>Source Han Serif SC</family></prefer>
          </alias>
          <alias>
            <family>思源宋体</family>
            <prefer><family>Source Han Serif SC</family></prefer>
          </alias>

          <!-- WPS Office Common Font Fallback: Windows 中文字体 → CJK 替代 -->
          <alias>
            <family>SimSun</family>
            <prefer><family>Source Han Serif SC</family></prefer>
          </alias>
          <alias>
            <family>宋体</family>
            <prefer><family>Source Han Serif SC</family></prefer>
          </alias>
          <alias>
            <family>SimHei</family>
            <prefer><family>Source Han Sans SC</family></prefer>
          </alias>
          <alias>
            <family>黑体</family>
            <prefer><family>Source Han Sans SC</family></prefer>
          </alias>
          <alias>
            <family>Microsoft YaHei</family>
            <prefer><family>Source Han Sans SC</family></prefer>
          </alias>
          <alias>
            <family>微软雅黑</family>
            <prefer><family>Source Han Sans SC</family></prefer>
          </alias>
          <alias>
            <family>KaiTi</family>
            <prefer><family>Source Han Serif SC</family></prefer>
          </alias>
          <alias>
            <family>楷体</family>
            <prefer><family>Source Han Serif SC</family></prefer>
          </alias>
          <alias>
            <family>FangSong</family>
            <prefer><family>Source Han Serif SC</family></prefer>
          </alias>
          <alias>
            <family>仿宋</family>
            <prefer><family>Source Han Serif SC</family></prefer>
          </alias>
          <alias>
            <family>DengXian</family>
            <prefer><family>Source Han Sans SC</family></prefer>
          </alias>

          <!-- WPS Office: 等线 → 无衬线 CJK -->
          <alias>
            <family>等线</family>
            <prefer><family>Source Han Sans SC</family></prefer>
          </alias>

          <!-- WPS Office: 方正系列字体 → CJK 替代 -->
          <alias>
            <family>FZShuSong</family>
            <prefer><family>Source Han Serif SC</family></prefer>
          </alias>
          <alias>
            <family>FZHei</family>
            <prefer><family>Source Han Sans SC</family></prefer>
          </alias>
          <alias>
            <family>FZKai</family>
            <prefer><family>Source Han Serif SC</family></prefer>
          </alias>
          <alias>
            <family>FZFangSong</family>
            <prefer><family>Source Han Serif SC</family></prefer>
          </alias>

          <!-- WPS 公式字体: 符号字体缺失时的回退 -->
          <alias>
            <family>Symbol</family>
            <prefer><family>Noto Sans Symbols</family></prefer>
          </alias>

          <!-- 通用 fallback: 当请求的字体不存在时优先使用 CJK -->
          <alias>
            <family>sans-serif</family>
            <prefer>
              <family>Source Han Sans SC</family>
              <family>Noto Sans CJK SC</family>
              <family>Noto Sans</family>
            </prefer>
          </alias>
          <alias>
            <family>serif</family>
            <prefer>
              <family>Source Han Serif SC</family>
              <family>Noto Serif CJK SC</family>
              <family>Noto Serif</family>
            </prefer>
          </alias>

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

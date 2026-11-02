{ lib, pkgs, inputs, ... }:

let
  kwallet5Compat = pkgs.runCommand "kwallet5-compat" { } ''
    mkdir -p $out/bin
    ln -s ${lib.getBin pkgs.kdePackages.kwallet}/bin/kwalletd6 $out/bin/kwalletd5
    ln -s ${lib.getBin pkgs.kdePackages.kwallet}/bin/kwalletd6 $out/bin/kwalletd
  '';

  # fcitx5-vinput 2.4.2 依赖 cpp-httplib 的 set_no_proxy / detail::parse_url /
  # set_payload_max_length（上游 FetchContent 钉 v0.62.0）；nixpkgs 自带
  # cpp-httplib 0.30.2 过旧，这里按上游钉的版本构建 header-only 安装供其使用。
  httplib062 = pkgs.stdenv.mkDerivation {
    pname = "cpp-httplib";
    version = "0.62.0";
    src = pkgs.fetchFromGitHub {
      owner = "yhirose";
      repo = "cpp-httplib";
      rev = "v0.62.0";
      hash = "sha256-CX0Da+S2I2V5bVxuxIfcGSzfroNkIJEs9SoWs3UO674=";
    };
    nativeBuildInputs = [ pkgs.cmake ];
    buildInputs = [ pkgs.openssl ];
    cmakeFlags = [
      "-DHTTPLIB_COMPILE=OFF"
      "-DHTTPLIB_INSTALL=ON"
      "-DHTTPLIB_TEST=OFF"
      "-DHTTPLIB_USE_OPENSSL_IF_AVAILABLE=ON"
    ];
  };
  vinputPackage = inputs.fcitx5-vinput.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      "-Dhttplib_DIR=${httplib062}/lib/cmake/httplib"
    ];
  });
in

{
  imports = [ ../desktop.nix ];

  services.displayManager = {
    sddm = {
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

  services.pipewire.alsa.support32Bit = true;

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

  i18n.inputMethod.fcitx5.addons = [ vinputPackage ];

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
}

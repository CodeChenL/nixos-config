{ lib, pkgs, inputs, ... }:

let
  kwallet5Compat = pkgs.runCommand "kwallet5-compat" { } ''
    mkdir -p $out/bin
    ln -s ${lib.getBin pkgs.kdePackages.kwallet}/bin/kwalletd6 $out/bin/kwalletd5
    ln -s ${lib.getBin pkgs.kdePackages.kwallet}/bin/kwalletd6 $out/bin/kwalletd
  '';

  vinputPackage = inputs.fcitx5-vinput.packages.${pkgs.stdenv.hostPlatform.system}.default;
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

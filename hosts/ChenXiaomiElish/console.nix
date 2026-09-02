{ pkgs, ... }:

{
  boot = {
    initrd.verbose = true;
    kernelParams = [
      "console=tty0"
      "fbcon=rotate:1"
      "systemd.show_status=1"
      "rd.systemd.show_status=1"
    ];
    plymouth.enable = false;
  };

  console = {
    enable = true;
    earlySetup = true;
    font = "ter-v24n";
    keyMap = "us";
    packages = [ pkgs.terminus_font ];
  };

  services.getty.autologinUser = null;

  systemd.services."getty@tty1" = {
    enable = true;
    wantedBy = [ "getty.target" ];
  };
}

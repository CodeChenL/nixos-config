{ lib, pkgs, ... }:

{
  imports = [
    ../common.nix
    ./abl.nix
    ./bundle.nix
    ./console.nix
    ./hardware-configuration.nix
    ./rootfs.nix
    ./usb-ncm.nix
  ];

  networking = {
    hostName = "ChenXiaomiElish";
    networkmanager.enable = true;
  };

  users.users.chen = {
    extraGroups = [
      "audio"
      "input"
      "networkmanager"
      "video"
    ];
    openssh.authorizedKeys.keyFiles = [ ../Aliyun/authorized_keys.pub ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = true;
      PermitRootLogin = "no";
    };
  };

  environment.systemPackages = [ pkgs.qbootctl ];

  systemd.services.qbootctl = {
    description = "Mark the current boot slot as successful";
    unitConfig.DefaultDependencies = false;
    requires = [ "boot-complete.target" ];
    after = [
      "boot-complete.target"
      "local-fs.target"
      "multi-user.target"
    ];
    before = [ "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${lib.getExe pkgs.qbootctl} -m";
    };
  };

  system.stateVersion = "25.11";
}

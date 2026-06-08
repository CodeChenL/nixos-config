{
  lib,
  inputs,
  ...
}:

{
  imports = [
    ../common.nix
    inputs.nixos-apple-silicon.nixosModules.apple-silicon-support
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "ChenAsahiLinux";

  users.users.chen.extraGroups = [
    "audio"
    "input"
    "networkmanager"
    "video"
  ];
  users.users.chen.linger = true;

  nixpkgs.config.allowUnsupportedSystem = true;

  hardware.asahi = {
    enable = true;
    extractPeripheralFirmware = false;
    setupAsahiSound = true;
  };

  boot.loader = {
    systemd-boot.enable = true;
    efi = {
      canTouchEfiVariables = false;
      efiSysMountPoint = "/boot/efi";
    };
  };

  networking.useDHCP = lib.mkDefault true;
  networking.interfaces.end0.useDHCP = lib.mkDefault true;

  services.openssh.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
  services.pulseaudio.enable = false;

  nix.settings = {
    substituters = [
      "https://nixos-apple-silicon.cachix.org"
    ];
    trusted-public-keys = [
      "nixos-apple-silicon.cachix.org-1:8psDu5SA5dAD7qA0zMy5UT292TxeEPzIz8VVEr2Js20="
    ];
    cores = 8;
    max-jobs = 2;
    max-substitution-jobs = 32;
    sandbox = true;
  };

  boot.loader.systemd-boot.configurationLimit = 30;
  system.stateVersion = "25.11";
}

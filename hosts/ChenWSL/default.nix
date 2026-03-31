{ config, pkgs, inputs, ... }:

{
  imports = [
    inputs.nixos-wsl.nixosModules.default
  ];

  wsl = {
    enable = true;
    defaultUser = "chen";
  };

  networking.hostName = "ChenWSL";

  # ── 用户账户 ─────────────────────────────────────────────────────
  users.users.chen = {
    isNormalUser = true;
    description = "Jiali Chen";
    extraGroups = [
      "wheel"
      "docker"
    ];
  };

  # ── 基础系统软件包 ────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    vim
    git
    wget
    curl
    htop
    pciutils
    usbutils
    lsof
    file
    unzip
    unrar
    p7zip
    tree
  ];

  programs.nano.enable = false;

  programs.command-not-found.enable = false;
  programs.nix-index = {
    enable = true;
    enableBashIntegration = true;
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = "24.11";
}

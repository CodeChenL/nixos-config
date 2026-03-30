{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./nvidia.nix
    ./desktop.nix
    ./networking.nix
    ./services.nix
    ./virtualization.nix
  ];

  # ── User account ────────────────────────────────────────────────
  users.users.chen = {
    isNormalUser = true;
    description = "Jiali Chen";
    extraGroups = [
      "wheel"
      "docker"
      "libvirtd"
      "kvm"
      "audio"
      "video"
      "input"
      "networkmanager"
      "dialout"  # serial ports (replaces uucp on Arch)
      "adbusers"
      "adm"
    ];
    shell = pkgs.bash;
  };

  # ── Sudo ────────────────────────────────────────────────────────
  security.sudo.wheelNeedsPassword = true;

  # ── Console ─────────────────────────────────────────────────────
  console = {
    font = "ter-v24n";
    packages = [ pkgs.terminus_font ];
    useXkbConfig = false;
  };

  # ── Base system packages ────────────────────────────────────────
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

  # ── Programs that need system-wide wrappers ─────────────────────
  programs.bash.completion.enable = true;
  programs.nano.enable = false;

  # ── Steam (needs system-level config for 32-bit libs) ───────────
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    gamescopeSession.enable = true;
  };
  programs.gamemode.enable = true;

  # ── command-not-found (via nix-index) ───────────────────────────
  programs.command-not-found.enable = false;
  programs.nix-index = {
    enable = true;
    enableBashIntegration = true;
  };
}

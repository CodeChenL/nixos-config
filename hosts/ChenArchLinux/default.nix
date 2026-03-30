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

  # ── 用户账户 ─────────────────────────────────────────────────────
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
      "dialout"  # 串口访问（对应 Arch 上的 uucp 组）
      "adbusers"
      "adm"
    ];
    shell = pkgs.bash;
  };

  # ── Sudo ────────────────────────────────────────────────────────
  security.sudo.wheelNeedsPassword = true;

  # ── 控制台 ──────────────────────────────────────────────────────
  console = {
    font = "ter-v24n";
    packages = [ pkgs.terminus_font ];
    useXkbConfig = false;
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

  # ── 需要系统级包装的程序 ─────────────────────────────────────────
  programs.bash.completion.enable = true;
  programs.nano.enable = false;

  # ── Steam（需要系统级 32 位库配置）────────────────────────────────
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    gamescopeSession.enable = true;
  };
  programs.gamemode.enable = true;

  # ── 命令未找到提示（通过 nix-index）──────────────────────────────────
  programs.command-not-found.enable = false;
  programs.nix-index = {
    enable = true;
    enableBashIntegration = true;
  };
}

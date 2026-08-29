{ inputs, lib, pkgs, config, ... }:

let
  adminKey = lib.trim (builtins.readFile ./authorized_keys.pub);
  rootPasswordHash = "$6$QU/kJXfPjVw8a1.O$f/pDLBGqZHYpidI5PAz1cJ7n4Is.m1QUbEmvcmC9yjPQhBGmv0AeLpWuAVcLHxWbDLcff3c8ilvqzA4Jt.YJV.";
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./hardware-configuration.nix
    ../ChenIdeaCentre/sub2api.nix
  ];

  networking.hostName = "ChenAliyun";
  networking.useDHCP = true;
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 5432 6379 ];
  };

  # Sub2API 已启用；Aliyun 是共享 PostgreSQL/Redis 后端。
  services.sub2api.enable = true;

  services.postgresql = {
    enableTCPIP = true;
    authentication = ''
      host all all 0.0.0.0/0 md5
    '';
  };

  services.redis.servers."" = {
    bind = "0.0.0.0";
    requirePassFile = "${config.users.users.chen.home}/nixos-config/secrets/sub2api/redis-password";
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = true;
    };
  };

  users.users.root.hashedPassword = rootPasswordHash;
  users.users.root.openssh.authorizedKeys.keys = [ adminKey ];
  users.users.chen = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = rootPasswordHash;
    openssh.authorizedKeys.keys = [ adminKey ];
  };
  # 声明式密码，确保 root/chen 每次 activation 都强制为同一密码。
  users.mutableUsers = false;

  boot.loader = {
    efi = {
      canTouchEfiVariables = true;
      efiSysMountPoint = "/boot/efi";
    };
    grub = {
      enable = true;
      device = "nodev";
      efiSupport = true;
      efiInstallAsRemovable = false;
      configurationLimit = 5;
      # 关闭 GRUB 图形 splash，优先使用文本/串口控制台。
      splashImage = null;
      font = null;
      gfxpayloadEfi = "text";
    };
  };
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200n8"
    "net.ifnames=0"
  ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = with pkgs; [
    curl
    git
    htop
    vim
    wget
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  system.stateVersion = "25.11";
}

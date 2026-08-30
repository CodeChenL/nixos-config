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

  # WireGuard：Aliyun 作为 OpenWrt `chen` 隧道的 ALIYUN peer。
  # 本端私钥使用 OpenWrt secret 中的 WG_CHEN_PEER1_PRIVATE_KEY。
  networking.wireguard.interfaces.chen = {
    ips = [ "10.0.33.2/32" ];
    privateKeyFile = "/run/secrets/wireguard-chen.key";
    dynamicEndpointRefreshSeconds = 300;
    peers = [
      {
        publicKey = "hoJX1qGLQ2M2k7YjwXUAVTPCROhyUawLj1zIs6iewXQ=";
        allowedIPs = [
          "10.0.33.0/24"
          "192.168.33.0/24"
        ];
        endpoint = "frp-ski.com:51888";
        persistentKeepalive = 25;
      }
    ];
  };

  # 从 OpenWrt secrets 文件提取 Aliyun 私钥，而不是把密钥写进 Nix store。
  systemd.services.wireguard-chen.preStart = ''
    set -euo pipefail
    source_file=/home/chen/nixos-config/secrets/o6n-openwrt.env
    destination=/run/secrets/wireguard-chen.key
    [ -r "$source_file" ] || {
      echo "missing WireGuard secret source: $source_file" >&2
      exit 1
    }
    install -d -m 0700 "$(dirname "$destination")"
    key=$(sed -n 's/^WG_CHEN_PEER1_PRIVATE_KEY=//p' "$source_file" | head -n1 | tr -d '\r\n')
    [ -n "$key" ] || {
      echo "WG_CHEN_PEER1_PRIVATE_KEY is missing or empty" >&2
      exit 1
    }
    umask 077
    printf '%s\n' "$key" > "$destination.tmp"
    mv "$destination.tmp" "$destination"
    chmod 600 "$destination"
  '';

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

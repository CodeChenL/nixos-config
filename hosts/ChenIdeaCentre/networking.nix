{ config, pkgs, ... }:

{
  # ── 主机名 ──────────────────────────────────────────────────────
  networking.hostName = "ChenIdeaCentre";

  # ── 网络管理 ────────────────────────────────────────────────────
  networking.networkmanager = {
    enable = true;
    ensureProfiles = {
      environmentFiles = [
        "${config.users.users.chen.home}/nixos-config/secrets/o6n-openwrt.env"
      ];
      profiles.chen-wireguard = {
        connection = {
          id = "Chen WireGuard";
          type = "wireguard";
          interface-name = "wg-chen";
          uuid = "6f17d306-a21c-55fb-b27b-e4441aeed1ee";
        };
        wireguard.private-key = "$WG_CHEN_PEER2_PRIVATE_KEY";
        "wireguard-peer.hoJX1qGLQ2M2k7YjwXUAVTPCROhyUawLj1zIs6iewXQ=" = {
          allowed-ips = "10.0.33.0/24;192.168.33.0/24;";
          endpoint = "frp-ski.com:51888";
          persistent-keepalive = "25";
        };
        ipv4 = {
          address1 = "10.0.33.3/32";
          method = "manual";
          never-default = "true";
        };
        ipv6.method = "disabled";
      };
    };
  };

  # ── 防火墙（已禁用）─────────────────────────────────────────────
  networking.firewall.enable = false;

  # ── WireGuard ───────────────────────────────────────────────────
  # WireGuard 由 NetworkManager 的 ensureProfiles 声明式管理

  # ── SSH ─────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true;
    };
  };

  # ── NFS 服务器 ──────────────────────────────────────────────────
  services.nfs.server = {
    enable = true;
    exports = ''
      /opt  192.168.2.0/24(rw,async)
    '';
  };

  # ── 无线网络监管域 ─────────────────────────────────────────────
  # cfg80211 监管域=CN 在 boot.nix 中通过 extraModprobeConfig 设置
  # 安装 wireless-regdb 提供监管数据
  hardware.wirelessRegulatoryDatabase = true;

  # ── 代理 / VPN ──────────────────────────────────────────────────
  # Clash Verge Rev 作为用户级软件包安装
  # 其系统服务由其自带的 systemd 单元管理
}

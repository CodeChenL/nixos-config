{ config, pkgs, ... }:

{
  # ── 主机名 ──────────────────────────────────────────────────────
  networking.hostName = "ChenArchLinux";

  # ── 网络管理 ────────────────────────────────────────────────────
  networking.networkmanager.enable = true;

  # ── 防火墙（已禁用）─────────────────────────────────────────────
  networking.firewall.enable = false;

  # ── WireGuard ───────────────────────────────────────────────────
  # WireGuard 由 NetworkManager 管理
  # 安装后通过 `nmcli connection import` 导入现有配置

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

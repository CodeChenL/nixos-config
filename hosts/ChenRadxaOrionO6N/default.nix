{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  imports = [
    # 本地基础配置（时区、用户、基础包、Nix 设置等）
    ../common.nix

    # Radxa 官方 nixos-hardware fork：开启 hardware.radxa + cix.sky1
    # 自动配置 systemd-boot + linuxPackages_latest + r8125 网卡驱动
    inputs.nixos-hardware-radxa.nixosModules.radxa-orion-o6

    # 声明式分区工具
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./hardware-configuration.nix
    ./console.nix
    ./networking.nix
    ./openwrt-container.nix
  ];

  # ── hostname ───────────────────────────────────────────────────────
  networking.hostName = "ChenRadxaOrionO6N";

  # ── 平台 ──────────────────────────────────────────────────────────
  # aarch64 设备在 nixpkgs 中部分包仍标记为 unsupported
  nixpkgs.config.allowUnsupportedSystem = true;

  # ── Radxa Cachix 二进制缓存（加速 ARM 构建）────────────────────────
  # 由 Radxa nixos-hardware 模块提供该 option
  hardware.radxa.cachix.enable = true;

  # ── 关闭 systemd runtime watchdog ─────────────────────────────────
  # CIX Sky1 的硬件 watchdog 行为在某些内核下会导致误触发 panic，
  # 参考上游 Radxa 配置关闭；如需硬件看门狗可在后续按 BSP 文档恢复
  systemd.settings.Manager.RuntimeWatchdogSec = "off";

  # ── Nix 构建并行度 ───────────────────────────────────────────────
  # Orion O6N 是 12 核 CPU，参考上游配置 8 cores / 2 max-jobs
  nix.settings.cores = 8;
  nix.settings.max-jobs = 2;

  # ── SSH（首次部署后远程管理）─────────────────────────────────────
  services.openssh.enable = true;

  # ── 宿主网络工具 ─────────────────────────────────────────────────
  # 用于首次部署时临时拨 PPPoE 或配置 DHCP
  environment.systemPackages = with pkgs; [
    ethtool
    ppp
    rp-pppoe
    dhcpcd
    gh
  ];

  # ── 系统状态版本 ─────────────────────────────────────────────────
  system.stateVersion = "25.11";
}

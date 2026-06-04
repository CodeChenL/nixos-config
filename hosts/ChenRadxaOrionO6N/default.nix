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
    ../natfrp.nix

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

  # ── 内核：默认使用 linux-cix-main（Linux v7.0 + CIX 补丁）────────
  # 覆盖 nixos-hardware-radxa 默认的 BSP 内核
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages-cix-main;
  # cix-linux-main README 要求的必要内核参数
  boot.kernelParams = lib.mkForce [
    "clk_ignore_unused"
  ];
  # cix-linux-main 使用上游 panthor 驱动，不需要 BSP 的 cix_vpu_driver
  boot.extraModulePackages = lib.mkForce [];
  boot.initrd.availableKernelModules = lib.mkForce [
    "btrfs"
    "sd_mod"
    "scsi_mod"
    "usb_storage"
    "uas"
    "nvme"
    "xhci_hcd"
    "xhci_pci"
  ];

  # ── specialisation：保留 BSP 内核启动项 ─────────────────────────
  # 开机时在 systemd-boot 菜单选择 "BSP Kernel (6.6)" 即可切回 BSP 内核
  specialisation.bsp-kernel.configuration = {
    boot.kernelPackages = lib.mkOverride 40 pkgs.linuxPackages_cix;
    boot.kernelParams = lib.mkOverride 40 [
      "acpi=force"
      "kasan=off"
    ];
    boot.extraModulePackages = lib.mkOverride 40 (with pkgs.linuxPackages_cix; [
      cix_vpu_driver
    ]);
  };

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

  services.natfrp = {
    enable = true;
    startAllTunnels = true;
    remoteManagement.enable = true;
  };

  # ── 系统状态版本 ─────────────────────────────────────────────────
  system.stateVersion = "25.11";
}

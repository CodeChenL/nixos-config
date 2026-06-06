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

  # ── 用户账户（服务器外设扩展）──────────────────────────────────────
  users.users.chen.extraGroups = [
    "dialout"   # 串口设备（ttyS*, ttyUSB*, ttyACM*）
    "plugdev"   # 可插拔 USB 设备
    "video"     # 视频设备（DRM、VPU 编解码）
    "input"     # 输入设备
    "audio"     # 音频设备（PipeWire）
  ];

  # ── hostname ───────────────────────────────────────────────────────
  networking.hostName = "ChenRadxaOrionO6N";

  # ── 平台 ──────────────────────────────────────────────────────────
  # aarch64 设备在 nixpkgs 中部分包仍标记为 unsupported
  nixpkgs.config.allowUnsupportedSystem = true;

  # ── 内核：默认使用 linux-cix-main（Linux v7.0 + CIX 补丁）────────
  # 覆盖 nixos-hardware-radxa 默认的 BSP 内核
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages-cix-main;
  # cix-linux-main README 要求的必要内核参数（补充而非覆盖）
  # cix-linux-main v7.0 已知 bug (cixtech/cix-linux-main#12):
  # PSCI cpuidle 深度休眠状态会导致 CPU 硬锁死 (cpuidle_enter_state 无法唤醒，
  # 引发 RCU stall、hung task、最终系统无响应)。
  # 临时 workaround: 完全禁用 cpuidle。代价: 空闲功耗升高约 3-5W。
  # 上游修复后移除本行。
  boot.kernelParams = [
    "clk_ignore_unused"
    "console=ttyAMA0,115200n8"
    "earlycon=pl011,0x040d0000"
    "cpuidle.off=1"
  ];
  # 添加 VPU 和 NPU DKMS 驱动（外部 DKMS，非 BSP 内置）
  boot.extraModulePackages = lib.mkForce (with pkgs.linuxPackages-cix-main; [
    cix-vpu-driver
    cix-npu-driver
  ]);

  # ── 固件：添加 CIX DSP 固件 ──────────────────────────────────────
  hardware.firmware = with pkgs; [
    linux-firmware  # 包含 panthor GPU 固件（版本 >20250808）
    cix-dsp-firmware  # CIX Sky1 DSP 固件
    cix-vpu-firmware  # CIX Sky1 VPU 编解码固件（h264/hevc/vp9/av1 等 .fwb）
  ];

  # ── 音频：启用 PipeWire 音频服务 ─────────────────────────────────
  # 支持 Headphone jack，DP Sound 暂不可用（README 标记为 TODO）
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  # 禁用 PulseAudio，使用 PipeWire 替代
  services.pulseaudio.enable = false;

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
  # Orion O6N 是 12 核 CPU，优化构建利用率：
  # max-jobs=4 × cores=3 = 12，刚好用满所有核心，避免过度竞争
  nix.settings = {
    cores = 12;
    max-jobs = 2;
    # 增加下载并行度，加速二进制缓存拉取
    max-substitution-jobs = 32;
    # 启用沙箱构建，提高安全性
    sandbox = true;
  };

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
    tokenSourceFile = "/home/chen/nixos-config/secrets/natfrp/token";
    remoteManagement.enable = true;
    remoteManagement.passwordSourceFile = "/home/chen/nixos-config/secrets/natfrp/remote-password";
  };

  # ── 系统状态版本 ─────────────────────────────────────────────────
  system.stateVersion = "25.11";
}

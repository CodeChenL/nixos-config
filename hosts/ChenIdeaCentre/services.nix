{ config, pkgs, ... }:

{
  # ── 时区与 NTP ──────────────────────────────────────────────────
  time.timeZone = "Asia/Shanghai";

  # ── 传感器 ──────────────────────────────────────────────────────
  hardware.sensor.iio.enable = true;

  # ── 硬件温度监控 ─────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    lm_sensors
    solaar
  ];

  # ── 打印 (CUPS) ─────────────────────────────────────────────────
  services.printing = {
    enable = true;
    drivers = [ pkgs.cups-filters ];
  };

  # ── USB/IP ──────────────────────────────────────────────────────
  # USB/IP 内核模块
  boot.kernelModules = [ "usbip-host" "vhci-hcd" ];

  # ── Sunshine（远程桌面主机 — Moonlight 客户端配对）─────────────────
  services.sunshine = {
    enable = true;
    autoStart = true;
    capSysAdmin = true;  # 屏幕捕获需要
    openFirewall = true;
    package = pkgs.sunshine.override {
      cudaSupport = true;
      cudaPackages = pkgs.cudaPackages;
    };
  };

  # ── RustDesk（远程桌面服务守护进程）─────────────────────────────────
  systemd.services.rustdesk = {
    description = "RustDesk Service";
    after = [ "systemd-user-sessions.service" ];
    wants = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.rustdesk}/bin/rustdesk --service";
      Restart = "on-failure";
    };
  };

  # ── Clash Verge Service（代理核心守护进程）──────────────────────────
  systemd.services.clash-verge-service = {
    description = "Clash Verge Service helps to launch Clash Core.";
    after = [ "network-online.target" "nftables.service" "iptables.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.clash-verge-rev}/bin/clash-verge-service";
      Group = "users";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # ── USB/IP 守护进程 ─────────────────────────────────────────────
  systemd.services.usbipd = {
    description = "USB/IP server";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.unstable.linuxPackages_latest.usbip}/bin/usbipd";
    };
  };

  # ── Flatpak（国产应用备用）───────────────────────────────────────────
  services.flatpak.enable = true;

  # ── 固件更新 ─────────────────────────────────────────────────────
  services.fwupd.enable = true;

  # ── 自定义 udev 规则 ───────────────────────────────────────────────
  services.udev.extraRules = ''
    # Allwinner aw_efex 设备
    ACTION!="add",GOTO="cfgend"
    KERNEL=="aw_efex*",MODE="0666"
    LABEL="cfgend"

    # Qualcomm EDL 模式 (9008)
    SUBSYSTEMS=="usb", ATTRS{idVendor}=="05c6", ATTRS{idProduct}=="9008", MODE="0666", GROUP="wheel"
    ACTION=="bind", SUBSYSTEM=="usb", ENV{ID_USB_VENDOR_ID}=="05c6", ENV{ID_USB_MODEL_ID}=="9008", GROUP="wheel"

    # USB 大容量存储重命名
    ACTION=="add", SUBSYSTEM=="block", ENV{ID_USB_DRIVER}=="usb-storage", ENV{DEVTYPE}=="disk", NAME="msd%n"
  '';

  # ── sysctl 调优 ────────────────────────────────────────────────
  boot.kernel.sysctl = {
    # KDE inotify 文件监控上限
    "fs.inotify.max_user_watches" = 540672;
  };

  # ── Nix 设置 ─────────────────────────────────────────────────────
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      trusted-users = [ "root" "chen" ];
      substituters = [
        "https://mirrors.ustc.edu.cn/nix-channels/store"
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 15d";
    };
  };

  # ── 系统状态版本 ────────────────────────────────────────────────
  system.stateVersion = "24.11";
}

{ config, pkgs, ... }:

{
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
    drivers = with pkgs; [
      cups-filters
      cups-browsed
      gutenprint
      hplipWithPlugin
      epson-escpr
    ];
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
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

  # ── 如意玲珑（容器化应用运行环境）────────────────────────────────────────
  services.linyaps.enable = true;

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

    # Raspberry Pi rpiboot / RPI2 Boot
    SUBSYSTEMS=="usb", ATTRS{idVendor}=="0a5c", ATTRS{idProduct}=="2763", MODE="0666", GROUP="wheel"
  '';

  # ── sysctl 调优 ────────────────────────────────────────────────
  boot.kernel.sysctl = {
    # KDE inotify 文件监控上限
    "fs.inotify.max_user_watches" = 540672;
  };
}

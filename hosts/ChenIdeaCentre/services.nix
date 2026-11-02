{ pkgs, ... }:

{
  # ── 传感器 ──────────────────────────────────────────────────────
  hardware.sensor.iio.enable = true;

  # I2C userspace device nodes and access rules (/dev/i2c-*).
  hardware.i2c.enable = true;

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
  boot.kernelModules = [ "usbip-host" "vhci-hcd" "spidev" ];

  # ── Sunshine（远程桌面主机 — Moonlight 客户端配对）─────────────────
  # 声明式配置（--config 指向 store 生成的 sunshine.conf）：Web UI 的"配置"
  # 页将不能保存（store 只读），改配置请编辑此处；"应用"页不受影响
  # （file_apps 默认仍指向 ~/.config/sunshine/apps.json）。
  services.sunshine = {
    enable = true;
    autoStart = true;
    capSysAdmin = true;  # 屏幕捕获需要
    openFirewall = true;
    package = pkgs.sunshine.override {
      cudaSupport = true;
      cudaPackages = pkgs.cudaPackages;
    };
    settings = {
      address_family = "both";
      bind_address = "0.0.0.0";  # 监听所有接口（wg / 局域网 / 回环）
      capture = "kms";
      key_rightalt_to_key_win = "enabled";
      locale = "zh";
      nvenc_preset = 1;
      origin_web_ui_allowed = "wan";
      output_name = "0";
      upnp = "enabled";
      wan_encryption_mode = 0;
      # CSRF 白名单（前缀匹配，覆盖任意端口）：
      #   0.0.0.0      —— 经 SSH 隧道/本机浏览（Origin 为 http(s)://0.0.0.0:…）
      #   192.168.2.x  —— LAN 动态 IP（当前 .237，曾为 .234；漂移后需同步改这里）
      #   10.0.33.3    —— wg-chen 静态入口（推荐 URL：https://10.0.33.3:47990）
      csrf_allowed_origins = "http://0.0.0.0,https://0.0.0.0,https://192.168.2.237,https://192.168.2.234,https://10.0.33.3,http://10.0.33.3";
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

    # Raspberry Pi RP2040/RP2350：BOOTSEL 免 root（picotool/openocd），
    # 并让 ModemManager 忽略其 CDC ACM 串口（避免 AT 探测长期占用 ttyACM）。
    SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", MODE="0666", GROUP="wheel", ENV{ID_MM_DEVICE_IGNORE}="1"
    SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1"
  '';

  # 保留 ModemManager（不禁用），但只探测显式白名单设备：
  # 普通 ttyACM/ttyUSB 不再被当作 modem 做 AT 探测（该探测会独占端口数十秒）。
  # 将来接真 modem 时按 VID/PID 加 udev 规则：
  #   SUBSYSTEM=="usb", ATTRS{idVendor}=="xxxx", ATTRS{idProduct}=="yyyy", ENV{ID_MM_DEVICE_WHITELIST}="1"
  networking.modemmanager.enable = true;
  systemd.services.ModemManager = {
    overrideStrategy = "asDropin";
    serviceConfig.ExecStart = [
      ""
      "${pkgs.modemmanager}/sbin/ModemManager --filter-policy=ALLOWLIST-ONLY"
    ];
  };

  # ── sysctl 调优 ────────────────────────────────────────────────
  boot.kernel.sysctl = {
    # KDE inotify 文件监控上限
    "fs.inotify.max_user_watches" = 540672;
  };

  # ── Sub2API（AI API 网关）────────────────────────────────────────
  services.sub2api = {
    enable = false;
    externalDatabase = true;
    environment = {
      DATABASE_HOST = "47.254.74.103";
      DATABASE_PORT = "5432";
      REDIS_HOST = "47.254.74.103";
      REDIS_PORT = "6379";
    };
  };
}

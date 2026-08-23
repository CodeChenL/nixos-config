{
  pkgs,
  inputs,
  ...
}:

{
  imports = [
    ../common.nix
    ../pgyvpn.nix
    ./hardware-configuration.nix
    ./boot.nix
    ./nvidia.nix
    ./desktop.nix
    ./networking.nix
    ./services.nix
    ./virtualization.nix
    ./sub2api.nix
  ];

  nix.settings = {
    max-jobs = 1;
    cores = 24;
    max-substitution-jobs = 32;
  };

  # ── 蒲公英访问端（异地组网）──────────────────────────────────────
  # 首次启用后需手动登录一次：sudo pgyvisitor login
  # 登录状态持久化在 /etc/oray/pgyvpn/，之后服务重启自动上线（autologin=true）
  services.pgyvpn.enable = true;

  # 强制按声明式账户状态写回 /etc/shadow，避免已有锁定账户跳过密码更新
  users.mutableUsers = false;

  # ── 用户账户（桌面专用扩展）──────────────────────────────────────
  users.users.chen = {
    linger = true;
    extraGroups = [
      "docker"
      "libvirtd"
      "kvm"
      "audio"
      "video"
      "input"
      "networkmanager"
      "dialout" # 串口访问（对应 Arch 上的 uucp 组）
      "adbusers"
      "adm"
    ];
  };

  # root 密码
  users.users.root.hashedPassword = "$6$4DL7XrtMGOISeaTG$u4qBpwa2ckcrXEVIq0owD/1LSo4Lx8Mnv4MADd8MwXNrYyIYQMgUT8Y.NqsYFkUrTfsSACSX7gytJTopATBLW0";

  # ── 控制台 ──────────────────────────────────────────────────────
  console = {
    font = "ter-v24n";
    packages = [ pkgs.terminus_font ];
  };

  # ── SBC 编程工具（CLI）──────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    alsa-utils
    inputs.edl-ng.packages.${pkgs.stdenv.hostPlatform.system}.edl-ng
    rkdeveloptool
    pyamlboot
    flashrom
  ];

  # Host udev policies must be installed by NixOS rather than Home Manager.
  services.udev.packages = [
    (pkgs.writeTextDir "lib/udev/rules.d/70-codex-micro.rules"
      (builtins.readFile "${inputs.codex-desktop-linux}/linux-features/codex-micro/resources/70-codex-micro.rules"))
    (pkgs.writeTextDir "lib/udev/rules.d/71-webhid.rules" ''
      # Allow the active local session to use WebHID devices.
      ACTION!="remove", KERNEL=="hidraw*", SUBSYSTEM=="hidraw", MODE="0660", TAG+="uaccess"
    '')
  ];

  # ── Steam（需要系统级 32 位库配置）────────────────────────────────
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    gamescopeSession.enable = true;
  };
  programs.gamemode.enable = true;

  # 只保留最近 30 个 generation（GRUB 启动菜单中的条目数）
  boot.loader.grub.configurationLimit = 30;
}

{ config, pkgs, inputs, ... }:

{
  imports = [
    ../common.nix
    ./hardware-configuration.nix
    ./boot.nix
    ./nvidia.nix
    ./desktop.nix
    ./networking.nix
    ./services.nix
    ./virtualization.nix
  ];

  # 强制按声明式账户状态写回 /etc/shadow，避免已有锁定账户跳过密码更新
  users.mutableUsers = false;

  # ── 用户账户（桌面专用扩展）──────────────────────────────────────
  users.users.chen = {
    extraGroups = [
      "docker"
      "libvirtd"
      "kvm"
      "audio"
      "video"
      "input"
      "networkmanager"
      "dialout"  # 串口访问（对应 Arch 上的 uucp 组）
      "adbusers"
      "adm"
    ];
    hashedPassword = "$6$WenrS6DTvNS5Kcq6$uW1rN2GwHQ.AgMeE4ISsidWfWBvRfzFc6XlFumoV8WvvD.S57rxPTKXkGbmF0qFZaQf/V3okI3ndsM7FufsNZ0";
  };

  # root 密码
  users.users.root.hashedPassword = "$6$4DL7XrtMGOISeaTG$u4qBpwa2ckcrXEVIq0owD/1LSo4Lx8Mnv4MADd8MwXNrYyIYQMgUT8Y.NqsYFkUrTfsSACSX7gytJTopATBLW0";

  # ── 控制台 ──────────────────────────────────────────────────────
  console = {
    font = "ter-v24n";
    packages = [ pkgs.terminus_font ];
  };

  # ── 桌面专用系统软件包 ──────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    # SBC program tools
    inputs.edl-ng.packages.${pkgs.stdenv.hostPlatform.system}.edl-ng
    rkdeveloptool
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

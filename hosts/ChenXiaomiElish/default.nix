{ lib, pkgs, ... }:

let
  # 与 ChenIdeaCentre 一致，复用现有 root 哈希。
  rootPasswordHash = "$6$4DL7XrtMGOISeaTG$u4qBpwa2ckcrXEVIq0owD/1LSo4Lx8Mnv4MADd8MwXNrYyIYQMgUT8Y.NqsYFkUrTfsSACSX7gytJTopATBLW0";
in

{
  imports = [
    ../common.nix
    ../desktop.nix
    ./abl.nix
    ./bundle.nix
    ./console.nix
    ./efi.nix
    ./hardware-configuration.nix
    ./rootfs.nix
    ./usb-ncm.nix
  ];

  networking = {
    hostName = "ChenXiaomiElish";
    networkmanager = {
      enable = true;
      # QCA6390 reports an unusable permanent address during activation;
      # `preserve` makes NetworkManager try 00:00:00:00:00:00.
      wifi.macAddress = "stable";
    };
  };

  # Elish 使用一个独立、显式管理的 ESP；保持 systemd 的 GPT 自动生成器关闭，
  # 避免它在这里合成 boot.mount/boot.automount。
  systemd.generators."systemd-gpt-auto-generator" = "/dev/null";

  boot.tmp.useTmpfs = false;
  boot.devShmSize = "512M";
  boot.runSize = "256M";
  services.logind.settings.Login.RuntimeDirectorySize = "128M";
  security.wrapperDirSize = "128M";

  nix.settings = {
    max-jobs = 1;
    cores = 2;
  };

  users.users.root.hashedPassword = rootPasswordHash;
  # 万一 initrd 再次进入 emergency，允许用同样的 root 密码进入 shell 排障。
  boot.initrd.systemd.emergencyAccess = rootPasswordHash;

  users.users.chen = {
    extraGroups = [
      "audio"
      "input"
      "networkmanager"
      "video"
    ];
    openssh.authorizedKeys.keyFiles = [ ../Aliyun/authorized_keys.pub ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = true;
      PermitRootLogin = "no";
    };
  };

  services.displayManager.autoLogin.enable = false;

  # Elish 的 msm DRM 需要 Mesa 的用户态驱动路径；不启用则 KWin 找不到
  # /run/opengl-driver/lib/gbm/dri_gbm.so。
  hardware.graphics.enable = true;
  services.fwupd.enable = false;

  environment.systemPackages = [ pkgs.qbootctl ];

  systemd.services.qbootctl = {
    description = "Mark the current boot slot as successful";
    unitConfig.DefaultDependencies = false;
    requires = [ "boot-complete.target" ];
    after = [
      "boot-complete.target"
      "local-fs.target"
      "multi-user.target"
    ];
    before = [ "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${lib.getExe pkgs.qbootctl} -m";
    };
  };

  system.stateVersion = "25.11";
}

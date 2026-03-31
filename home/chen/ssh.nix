{ config, pkgs, ... }:

{
  programs.ssh = {
    enable = true;
    # 禁用旧版默认值，未来将被移除
    enableDefaultConfig = false;

    # ── 局域网设备 ──────────────────────────────────────────────
    matchBlocks = {
      "192.168.33.221" = {
        user = "radxa";
      };
      "192.168.31.198" = {
        user = "chen";
      };
      "192.168.2.222" = {
        user = "radxa";
      };
      "192.168.2.35" = {
        user = "chen";
      };
      "192.168.2.232" = {
        user = "rock";
      };
      "192.168.2.152" = {
        user = "rock";
      };
      "192.168.2.108" = {
        user = "rock";
      };
      "192.168.2.14" = {
        user = "chenjiali";
      };
      "192.168.2.18" = {
        user = "chen";
      };
      "192.168.31.215" = {
        user = "rock";
      };
      "192.168.31.124" = {
        user = "rock";
      };
      "192.168.2.176" = {
        user = "rock";
      };

      # ── 全志 Gerrit ──────────────────────────────────────────
      "gerritsdk.allwinnertech.com" = {
        hostname = "gerritsdk.allwinnertech.com";
        port = 57418;
        user = "aw_vamrs";
        extraOptions = {
          HostKeyAlgorithms = "+ssh-rsa";
          PubkeyAcceptedAlgorithms = "+ssh-rsa";
        };
        identityFile = "~/.ssh/id_rsa";
        identitiesOnly = true;
      };

      # ── Amlogic OpenLinux ────────────────────────────────────
      "openlinux.amlogic.com" = {
        hostname = "openlinux.amlogic.com";
        user = "git";
        identityFile = "~/.ssh/amlogic_openlinux";
        identitiesOnly = true;
      };
      "openlinux2.amlogic.com" = {
        hostname = "openlinux2.amlogic.com";
        user = "git";
        identityFile = "~/.ssh/amlogic_openlinux";
      };
    };
  };

  # ── 提示：密钥文件需手动迁移 ──────────────────────────────────
  # 安装 NixOS 后，需将以下文件复制到 ~/.ssh/：
  #   id_rsa, id_rsa.pub
  #   amlogic_openlinux, amlogic_openlinux.pub
  #   authorized_keys
  #   ghp_token, gh_tk
  # 权限：私钥 600，公钥 644，目录 700
}

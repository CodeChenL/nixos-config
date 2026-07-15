{ config, pkgs, ... }:

{
  programs.ssh = {
    enable = true;
    # 禁用旧版默认值，未来将被移除
    enableDefaultConfig = false;

    # ── 局域网设备 ──────────────────────────────────────────────
    settings = {
      # ── 全志 Gerrit ──────────────────────────────────────────
      "gerritsdk.allwinnertech.com" = {
        HostName = "gerritsdk.allwinnertech.com";
        Port = 57418;
        User = "aw_vamrs";
        HostKeyAlgorithms = "+ssh-rsa";
        PubkeyAcceptedAlgorithms = "+ssh-rsa";
        IdentityFile = "~/.ssh/id_rsa";
        IdentitiesOnly = true;
      };

      # ── Amlogic OpenLinux ────────────────────────────────────
      "openlinux.amlogic.com" = {
        HostName = "openlinux.amlogic.com";
        User = "git";
        IdentityFile = "~/.ssh/amlogic_openlinux";
        IdentitiesOnly = true;
      };
      "openlinux2.amlogic.com" = {
        HostName = "openlinux2.amlogic.com";
        User = "git";
        IdentityFile = "~/.ssh/amlogic_openlinux";
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

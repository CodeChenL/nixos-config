{ config, pkgs, ... }:

{
  # ── Docker ──────────────────────────────────────────────────────
  virtualisation.docker = {
    enable = true;
    storageDriver = "overlay2";
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # NVIDIA 容器工具包
  hardware.nvidia-container-toolkit.enable = true;

  # ── Podman ──────────────────────────────────────────────────────
  virtualisation.podman = {
    enable = true;
    dockerCompat = false; # Docker 已启用，无需兼容模式
    defaultNetwork.settings.dns_enabled = true;
  };

  # ── libvirt / QEMU / KVM ───────────────────────────────────────
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu;
      runAsRoot = true;
      swtpm.enable = true;
      # OVMF 已由 QEMU 默认提供，无需手动配置
    };
  };
  programs.virt-manager.enable = true;

  # ── Waydroid（Android 容器）──────────────────────────────────────────
  virtualisation.waydroid.enable = true;

  # ── QEMU binfmt（多架构用户态模拟）─────────────────────────────
  boot.binfmt.emulatedSystems = [
    "aarch64-linux"
    "armv7l-linux"
  ];

  # ── 容器运行时软件包 ────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    docker-compose
    docker-buildx
    crun
  ];
}

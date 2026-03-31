{ config, pkgs, ... }:

{
  # ── Docker ──────────────────────────────────────────────────────
  virtualisation.docker = {
    enable = true;
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
  # preferStaticEmulators: 使用静态链接的 qemu，容器内无需访问宿主 /nix/store
  # fixBinary: 注册时预加载解释器，容器/chroot 中也能工作
  boot.binfmt.emulatedSystems = [
    "aarch64-linux"
    "armv7l-linux"
  ];
  boot.binfmt.preferStaticEmulators = true;
  boot.binfmt.registrations.aarch64-linux.fixBinary = true;
  boot.binfmt.registrations.armv7l-linux.fixBinary = true;

  # ── 容器运行时软件包 ────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    docker-compose
    docker-buildx
    crun
  ];
}

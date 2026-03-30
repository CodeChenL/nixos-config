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

  # NVIDIA container toolkit
  hardware.nvidia-container-toolkit.enable = true;

  # ── Podman ──────────────────────────────────────────────────────
  virtualisation.podman = {
    enable = true;
    dockerCompat = false; # Docker is already enabled
    defaultNetwork.settings.dns_enabled = true;
  };

  # ── libvirt / QEMU / KVM ───────────────────────────────────────
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_full;
      runAsRoot = true;
      swtpm.enable = true;
      ovmf = {
        enable = true;
        packages = [ pkgs.OVMF.fd ];
      };
    };
  };
  programs.virt-manager.enable = true;

  # ── Waydroid (Android container) ────────────────────────────────
  virtualisation.waydroid.enable = true;

  # ── QEMU binfmt (multi-arch user-mode emulation) ───────────────
  boot.binfmt.emulatedSystems = [
    "aarch64-linux"
    "armv7l-linux"
  ];

  # ── Container runtime packages ──────────────────────────────────
  environment.systemPackages = with pkgs; [
    docker-compose
    docker-buildx
    crun
  ];
}

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # ── 内核模块 ───────────────────────────────────────────────────
  boot.initrd.availableKernelModules = [
    "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod"
  ];
  boot.initrd.kernelModules = [
    "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm"
    "i915"  # Intel 核显早期 KMS
  ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # ── 文件系统 ───────────────────────────────────────────────────
  # / — SSD btrfs @nixos 子卷（NixOS 根分区）
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/a1b1655f-b54c-4931-9290-45a40d5b0b31";
    fsType = "btrfs";
    options = [
      "relatime" "ssd" "discard=async"
      "space_cache=v2" "subvol=/@nixos"
    ];
  };

  # /boot — EFI 系统分区（与 Arch 共享）
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/511B-0061";
    fsType = "vfat";
    options = [ "relatime" "fmask=0022" "dmask=0022" ];
  };

  # /home — SSD 上的 btrfs 子卷（与 Arch 共享）
  fileSystems."/home" = {
    device = "/dev/disk/by-uuid/a1b1655f-b54c-4931-9290-45a40d5b0b31";
    fsType = "btrfs";
    options = [
      "relatime" "ssd" "discard=async"
      "space_cache=v2" "subvol=/home"
    ];
  };

  # ── 交换分区 (zram) ─────────────────────────────────────────────
  swapDevices = [ ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
  };

  # ── 固件与 CPU 微码 ────────────────────────────────────────────
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;

  # ── 平台 ──────────────────────────────────────────────────────
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}

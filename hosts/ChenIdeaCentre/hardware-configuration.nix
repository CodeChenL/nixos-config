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
  # / — NVMe 上的 btrfs 顶层（迁移后的 NixOS 根分区）
  # 这样会直接复用 nvme0n1p2 现有顶层目录，/opt/work 会随根文件系统一起保留。
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/3e0e480a-17b6-40e0-ae94-f7004db9f92c";
    fsType = "btrfs";
    options = [
      "relatime" "ssd" "discard=async"
      "space_cache=v2" "subvol=/"
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

  # ── 固件与 CPU 微码 ────────────────────────────────────────────
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;

  # ── 平台 ──────────────────────────────────────────────────────
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}

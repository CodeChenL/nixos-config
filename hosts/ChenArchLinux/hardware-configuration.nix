{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # ── Kernel modules ──────────────────────────────────────────────
  boot.initrd.availableKernelModules = [
    "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # ── File systems ────────────────────────────────────────────────
  # / — NVMe ext4
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/b0ab7171-dd4f-42cf-87e6-6c4958752652";
    fsType = "ext4";
    options = [ "relatime" ];
  };

  # /boot — EFI System Partition
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/511B-0061";
    fsType = "vfat";
    options = [ "relatime" "fmask=0022" "dmask=0022" ];
  };

  # /home — btrfs on SSD (subvol)
  fileSystems."/home" = {
    device = "/dev/disk/by-uuid/a1b1655f-b54c-4931-9290-45a40d5b0b31";
    fsType = "btrfs";
    options = [
      "relatime" "ssd" "discard=async"
      "space_cache=v2" "subvol=/home"
    ];
  };

  # ── Swap (zram) ─────────────────────────────────────────────────
  swapDevices = [ ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
  };

  # ── Firmware & CPU microcode ────────────────────────────────────
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;

  # ── Platform ────────────────────────────────────────────────────
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}

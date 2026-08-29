{ lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
  ];
  boot.initrd.kernelModules = [
    "crc32c-cryptoapi"
    "btrfs"
    "vfat"
    "nls_cp437"
    "nls_iso8859-1"
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}

{
  description = "ChenArchLinux NixOS 配置";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs = { self, nixpkgs, home-manager, nixos-hardware, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ (import ./overlays) ];
      };
    in
    {
      nixosConfigurations.ChenArchLinux = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/ChenArchLinux

          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.chen = import ./home/chen;
            home-manager.extraSpecialArgs = { inherit inputs; };
          }

          {
            nixpkgs.config.allowUnfree = true;
            nixpkgs.config.permittedInsecurePackages = [
              "ventoy-1.1.10"
            ];
            nixpkgs.overlays = [ (import ./overlays) ];
          }
        ];
      };

      # ── U 盘测试配置 ──────────────────────────────────────────────
      nixosConfigurations.test-usb = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/ChenArchLinux

          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.chen = import ./home/chen;
            home-manager.extraSpecialArgs = { inherit inputs; };
          }

          {
            nixpkgs.config.allowUnfree = true;
            nixpkgs.config.permittedInsecurePackages = [
              "ventoy-1.1.10"
            ];
            nixpkgs.overlays = [ (import ./overlays) ];
          }

          # U 盘测试覆盖层
          ({ lib, pkgs, modulesPath, ... }: {
            # 替换硬件配置
            disabledModules = [ ./hosts/ChenArchLinux/hardware-configuration.nix ];
            imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

            # U 盘文件系统
            fileSystems."/" = lib.mkForce {
              device = "/dev/disk/by-label/nixos";
              fsType = "ext4";
            };
            fileSystems."/boot" = lib.mkForce {
              device = "/dev/disk/by-label/NIXBOOT";
              fsType = "vfat";
              options = [ "fmask=0022" "dmask=0022" ];
            };
            # 不挂载 /home，使用根分区下的 /home
            fileSystems."/home" = lib.mkForce {
              device = "none";
              fsType = "tmpfs";
              options = [ "size=4G" ];
            };
            swapDevices = lib.mkForce [ ];
            zramSwap = lib.mkForce { enable = true; algorithm = "zstd"; memoryPercent = 50; };

            # 引导配置（U 盘用 GRUB 兼容 BIOS+EFI）
            boot.loader.grub = lib.mkForce {
              enable = true;
              efiSupport = true;
              efiInstallAsRemovable = true;
              device = "nodev";
            };
            boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
            boot.plymouth.enable = lib.mkForce false;
            boot.initrd.availableKernelModules = lib.mkForce [
              "xhci_pci" "ahci" "usb_storage" "usbhid" "sd_mod"
              "ehci_pci" "uas"
            ];
            boot.kernelModules = lib.mkForce [ ];
            boot.extraModulePackages = lib.mkForce [ ];

            # 禁用 NVIDIA（测试不需要）
            services.xserver.videoDrivers = lib.mkForce [ "modesetting" ];
            hardware.nvidia.modesetting.enable = lib.mkForce false;
            hardware.nvidia.open = lib.mkForce false;
            hardware.nvidia.prime = lib.mkForce {};
            hardware.nvidia.package = lib.mkForce pkgs.linuxPackages.nvidiaPackages.stable;
            hardware.nvidia-container-toolkit.enable = lib.mkForce false;

            # 禁用不需要的服务
            services.nfs.server.enable = lib.mkForce false;
            virtualisation.waydroid.enable = lib.mkForce false;

            # 测试密码
            users.users.chen.initialPassword = "test";
            users.users.root.initialPassword = "test";

            # 不需要微码和固件
            hardware.cpu.intel.updateMicrocode = lib.mkForce false;
            hardware.enableRedistributableFirmware = lib.mkForce true;
          })
        ];
      };
    };
}

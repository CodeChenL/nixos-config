{
  description = "ChenIdeaCentre NixOS 配置";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # Radxa 官方维护的 nixos-hardware fork（带 orion-o6、cix/sky1 等 Radxa/CIX SoC 模块）
    # 与上游 nixos-hardware 独立，避免污染 ChenIdeaCentre 用的稳定模块
    # 该 fork 的 flake 不声明 nixpkgs input（继承 host nixpkgs），无需 follows
    nixos-hardware-radxa.url = "github:RadxaYuntian/nixos-hardware/radxa-clean-up";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";
    NUR.url = "github:nix-community/NUR";

    edl-ng = {
      url = "github:strongtz/edl-ng/de101db593b8ee92cb1c6ee8e2c60bd9037d66ed";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zephyr-nix = {
      url = "git+https://github.com/nix-community/zephyr-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    radxa-linkr-debugger = {
      url = "github:xzl01/agent-debugboard?ref=dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nixos-hardware,
      nixos-hardware-radxa,
      disko,
      edl-ng,
      llm-agents,
      ...
    }@inputs:
    let
      commonOverlay = import ./overlays inputs;
    in
    {
      nixosConfigurations.ChenIdeaCentre = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/ChenIdeaCentre

          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-bak";
            home-manager.users.chen = import ./home/chen;
            home-manager.extraSpecialArgs = { inherit inputs; };
          }

          {
            nixpkgs.config.allowUnfree = true;
            nixpkgs.config.permittedInsecurePackages = [
              # NUR 钉钉当前仍依赖 OpenSSL 1.1
              "openssl-1.1.1w"
              "python-2.7.18.12"
              "ventoy-1.1.10"
            ];
            nixpkgs.overlays = [ commonOverlay ];
          }
        ];
      };

      nixosConfigurations.ChenWSL = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/ChenWSL

          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-bak";
            home-manager.users.chen = import ./home/chen/wsl.nix;
            home-manager.extraSpecialArgs = { inherit inputs; };
          }

          {
            nixpkgs.config.allowUnfree = true;
            nixpkgs.config.permittedInsecurePackages = [
              "python-2.7.18.12"
            ];
            nixpkgs.overlays = [ commonOverlay ];
          }
        ];
      };

      # ── Radxa Orion O6N (CIX Sky1, aarch64) ────────────────────────────
      nixosConfigurations.ChenRadxaOrionO6N = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/ChenRadxaOrionO6N

          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-bak";
            home-manager.users.chen = import ./home/chen/cli.nix;
            home-manager.extraSpecialArgs = { inherit inputs; };
          }

          {
            nixpkgs.config.allowUnfree = true;
            nixpkgs.config.permittedInsecurePackages = [
              "openssl-1.1.1w"
              "python-2.7.18.12"
              "ventoy-1.1.10"
            ];
            nixpkgs.overlays = [ commonOverlay ];
          }
        ];
      };
    };
}

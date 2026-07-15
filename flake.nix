{
  description = "ChenIdeaCentre NixOS 配置";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware";

    nixos-apple-silicon.url = "github:nix-community/nixos-apple-silicon";

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
      url = "github:strongtz/edl-ng/main";
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

    rustty = {
      url = "github:CodeChenL/rustty?ref=dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nixos-hardware,
      nixos-apple-silicon,
      nixos-hardware-radxa,
      disko,
      edl-ng,
      llm-agents,
      ...
    }@inputs:
    let
      commonOverlay = import ./overlays inputs;

      mkHost =
        {
          system,
          hostModulesPath,
          homeConfig,
          insecurePackages ? [ ],
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            hostModulesPath

            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "hm-bak";
              home-manager.users.chen = homeConfig;
              home-manager.extraSpecialArgs = { inherit inputs; };
            }

            {
              nixpkgs.config.allowUnfree = true;
              nixpkgs.config.permittedInsecurePackages = insecurePackages;
              nixpkgs.overlays = [ commonOverlay ];
            }
          ];
        };
    in
    {
      nixosConfigurations.ChenIdeaCentre = mkHost {
        system = "x86_64-linux";
        hostModulesPath = ./hosts/ChenIdeaCentre;
        homeConfig = import ./home/chen;
        insecurePackages = [
          "openssl-1.1.1w"
          "python-2.7.18.12"
          "ventoy-1.1.12"
        ];
      };

      nixosConfigurations.ChenWSL = mkHost {
        system = "x86_64-linux";
        hostModulesPath = ./hosts/ChenWSL;
        homeConfig = import ./home/chen/wsl.nix;
        insecurePackages = [
          "python-2.7.18.12"
        ];
      };

      # ── Radxa Orion O6N (CIX Sky1, aarch64) ────────────────────────────
      nixosConfigurations.ChenRadxaOrionO6N = mkHost {
        system = "aarch64-linux";
        hostModulesPath = ./hosts/ChenRadxaOrionO6N;
        homeConfig = import ./home/chen/cli.nix;
        insecurePackages = [
          "openssl-1.1.1w"
          "python-2.7.18.12"
          "ventoy-1.1.12"
        ];
      };

      # ── Apple M1 Mac mini (Asahi Linux, aarch64) ───────────────────────
      nixosConfigurations.ChenAsahiLinux = mkHost {
        system = "aarch64-linux";
        hostModulesPath = ./hosts/ChenAsahiLinux;
        homeConfig = import ./home/chen/asahi.nix;
        insecurePackages = [
          "openclaw-2026.6.11"
          "python-2.7.18.12"
        ];
      };
    };
}

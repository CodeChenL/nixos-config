{
  description = "ChenIdeaCentre NixOS 配置";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware";

    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";
    NUR.url = "github:nix-community/NUR";

    edl-ng = {
      url = "github:strongtz/edl-ng";
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
  };

  outputs = { self, nixpkgs, home-manager, nixos-hardware, edl-ng, llm-agents, ... }@inputs:
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
            nixpkgs.overlays = [ commonOverlay ];
          }
        ];
      };
    };
}

{ config, pkgs, inputs, ... }:

{
  imports = [
    ../common.nix
    inputs.nixos-wsl.nixosModules.default
  ];

  wsl = {
    enable = true;
    defaultUser = "chen";
  };

  networking.hostName = "ChenWSL";

  # ── 用户账户（WSL 专用扩展）──────────────────────────────────────
  users.users.chen.extraGroups = [ "docker" ];
}

{ config, pkgs, lib, ... }:

{
  imports = [
    ./common.nix
    ./packages-cli.nix
  ];
}

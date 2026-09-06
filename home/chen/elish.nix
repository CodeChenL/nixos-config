{ pkgs, ... }:

{
  imports = [
    ./default.nix
    ./packages-cli.nix
    ./lsp.nix
  ];

  disabledModules = [
    ./dev.nix
    ./packages.nix
    ./kicad.nix
  ];

  home.packages = with pkgs; [
    firefox
    chromium
    libreoffice-fresh
    gimp
    mpv
    remmina
    scrcpy
    kdePackages.yakuake
    kicad
    unstable.vscode
  ];
}

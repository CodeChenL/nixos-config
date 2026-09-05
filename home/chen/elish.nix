{ ... }:

{
  home.username = "chen";
  home.homeDirectory = "/home/chen";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;
  programs.bash.enable = true;
  programs.git.enable = true;
  programs.htop.enable = true;
}

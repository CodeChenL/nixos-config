{ pkgs, lib, ... }:

let
  githubTokenSource = "/home/chen/nixos-config/secrets/gh_tk";
in

{
  # ── 时区 ────────────────────────────────────────────────────────
  time.timeZone = "Asia/Shanghai";

  # ── 用户账户（基础）──────────────────────────────────────────────
  users.users.chen = {
    isNormalUser = true;
    description = "Jiali Chen";
    extraGroups = [ "wheel" ];
    hashedPassword = "$6$WenrS6DTvNS5Kcq6$uW1rN2GwHQ.AgMeE4ISsidWfWBvRfzFc6XlFumoV8WvvD.S57rxPTKXkGbmF0qFZaQf/V3okI3ndsM7FufsNZ0";
  };

  # ── 基础系统软件包 ────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    vim
    git
    wget
    curl
    htop
    pciutils
    usbutils
    lsof
    file
    unzip
    unrar
    p7zip
    tree
  ];

  # ── 程序 ─────────────────────────────────────────────────────────
  programs.nano.enable = false;

  programs.command-not-found.enable = false;
  programs.nix-index = {
    enable = true;
    enableBashIntegration = true;
  };
  programs.nix-ld = {
    enable = true;
    libraries = pkgs.ngrLibraries;
  };

  # ── Nix 设置 ─────────────────────────────────────────────────────
  nix = {
    extraOptions = ''
      !include /etc/nix/access-tokens.conf
    '';
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
      trusted-users = [
        "root"
        "chen"
      ];
      substituters = [
        "https://mirrors.ustc.edu.cn/nix-channels/store"
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
        "https://cache.numtide.com"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 15d";
    };
  };

  system.activationScripts.nixAccessTokens = lib.stringAfter [ "etc" ] ''
    token_source=${lib.escapeShellArg githubTokenSource}
    token_target=/etc/nix/access-tokens.conf
    token_tmp=$(mktemp)

    if [ -s "$token_source" ]; then
      install -d -m 0755 /etc/nix
      trap 'rm -f "$token_tmp"' EXIT
      printf 'access-tokens = github.com=%s\n' "$(tr -d '\r\n' < "$token_source")" > "$token_tmp"
      install -m 0640 -o root -g wheel "$token_tmp" "$token_target"
      rm -f "$token_tmp"
      trap - EXIT
    else
      rm -f "$token_target"
    fi
  '';
  # ── 系统状态版本 ────────────────────────────────────────────────
  system.stateVersion = "25.11";
}

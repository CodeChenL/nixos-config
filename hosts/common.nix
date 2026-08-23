{ config, pkgs, lib, ... }:

let
  githubTokenSource = "${config.users.users.chen.home}/nixos-config/secrets/gh_tk";
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
    multipath-tools
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
      # auto-optimise-store 在 Nix 2.18+ 默认开启，无需显式设置
      trusted-users = [
        "root"
        "chen"
      ];
      substituters = [
        "https://mirrors.ustc.edu.cn/nix-channels/store?priority=10"
        "https://mirror.sjtu.edu.cn/nix-channels/store?priority=20"
        "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store?priority=30"
        "https://nix-community.cachix.org?priority=50"
        "https://cache.numtide.com?priority=60"
        "https://nixpkgs-unfree.cachix.org?priority=70"
        "https://cache.nixos-cuda.org?priority=80"
      ];
      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
        "nixpkgs-unfree.cachix.org-1:hqvoInulhbV4nJ9yJOEr+4wxhDV4xq2d1DK7S6Nj6rs="
        "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      ];
      connect-timeout = 10;
      stalled-download-timeout = 30;
      download-attempts = 3;
      narinfo-cache-negative-ttl = 300;
      fallback = false;
    };
    gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 30d";
    };
  };
  # 最多保留 60 个系统 profile；本 nixpkgs 版本中该选项位于 boot.loader.*.maxGenerations
  # （如 boot.loader.systemd-boot.maxGenerations），由各 host 单独配置。

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
  # ── 分层交换：zram 前备 + 磁盘 swapfile 后备 ─────────────────────
  # 关闭 zswap：与 zram 并存会造成双重压缩，浪费内存
  boot.kernelParams = [ "zswap.enabled=0" ];

  # 前备：zram 压缩内存交换（priority 5，内核优先使用）
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
  };

  # 后备：swapspace 动态 swapfile 管理器
  # 其空闲量计算为 MemAvailable + SwapFree，即 zram 有空位时不占磁盘；
  # 仅当 zram 写满、内存压力上来才按需创建 swapfile，压力消退后删除归还空间。
  # swapon 不带优先级 → 内核自动分配负优先级，低于 zram，天然形成后备层。
  # 注意：swapfile 位于 /var/lib/swapspace（btrfs 下自动 NOCOW），该目录所在子卷不得做快照。
  services.swapspace.enable = true;

  # ── 系统状态版本 ────────────────────────────────────────────────
  system.stateVersion = "25.11";
}

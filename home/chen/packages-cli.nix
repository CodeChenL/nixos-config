{ config, pkgs, ... }:

let
  githubCopilotCli = pkgs.stdenvNoCC.mkDerivation rec {
    pname = "github-copilot-cli";
    version = "1.0.19";

    src = pkgs.fetchzip {
      url = "https://registry.npmjs.org/@github/copilot-linux-x64/-/copilot-linux-x64-${version}.tgz";
      hash = "sha256-x3w6X3zpruarOlz6mVZLUMAUmXosjsymU3wX1UZ4Lkc=";
    };

    nativeBuildInputs = [ pkgs.makeWrapper ];

    installPhase = ''
      runHook preInstall

      install -d $out/lib/${pname} $out/bin
      cp -r ./* $out/lib/${pname}/

      makeWrapper $out/lib/${pname}/copilot $out/bin/copilot \
        --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]}

      runHook postInstall
    '';

    meta = {
      description = "GitHub Copilot CLI for the terminal";
      homepage = "https://github.com/github/copilot-cli";
      downloadPage = "https://www.npmjs.com/package/@github/copilot";
      license = pkgs.lib.licenses.unfree;
      mainProgram = "copilot";
      platforms = [ "x86_64-linux" ];
    };
  };
in

{
  home.packages = with pkgs; [
    # ── AI CLI ──────────────────────────────────────────────────
    githubCopilotCli

    # ── 代理 / VPN ─────────────────────────────────────────────
    wireguard-tools
    proxychains-ng

    # ── 下载 ───────────────────────────────────────────────────
    aria2
    axel

    # ── 网络工具 ───────────────────────────────────────────────
    nmap
    iperf3
    traceroute
    bind
    inetutils
    net-tools

    # ── 系统监控 ───────────────────────────────────────────────
    btop
    sysstat

    # ── 文件工具 ────────────────────────────────────────────────
    bat
    dust
    yazi
    vifm
    lazygit
    tmux
    fastfetch
    most
    bc
    pv
    dos2unix
    mmv
    rsync

    # ── 压缩工具 ─────────────────────────────────────────────────
    lrzip
    lzip
    lzop
    cpio

    # ── 其他 CLI ────────────────────────────────────────────────
    shellcheck
    yamlfmt
  ];
}

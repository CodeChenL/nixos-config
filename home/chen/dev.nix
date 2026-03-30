{ config, pkgs, ... }:

{
  home.packages = with pkgs; [
    # ── Editors ─────────────────────────────────────────────────
    vscode
    vim

    # ── Build systems ───────────────────────────────────────────
    cmake
    meson
    gnumake
    scons
    ccache
    ninja
    pkg-config
    gperf
    help2man
    asciidoc
    ctags

    # ── C/C++ ───────────────────────────────────────────────────
    gcc
    gdb
    clang

    # ── Python ──────────────────────────────────────────────────
    (python3.withPackages (ps: with ps; [
      numpy
      pyserial
      pyusb
      pyroute2
      websockets
      rich
      pip
    ]))
    python3Packages.pipx
    uv

    # ── Node.js ─────────────────────────────────────────────────
    nodejs
    nodePackages.npm
    yarn
    nodePackages.prettier

    # ── .NET ────────────────────────────────────────────────────
    dotnet-sdk

    # ── Go ──────────────────────────────────────────────────────
    go

    # ── Ruby ────────────────────────────────────────────────────
    ruby

    # ── Rust (via rustup, managed natively) ─────────────────────
    # Use `rustup` to manage Rust toolchains
    rustup

    # ── Cross-compilation toolchains ────────────────────────────
    pkgsCross.aarch64-multiplatform.buildPackages.gcc
    gcc-arm-embedded           # arm-none-eabi-gcc

    # ── Embedded / SoC tools ────────────────────────────────────
    dtc                        # device tree compiler
    ubootTools                 # mkimage etc.
    android-tools              # adb, fastboot
    mtd-utils
    binwalk

    # ── VCS / CI ────────────────────────────────────────────────
    git
    git-lfs
    github-cli
    lazygit
    pre-commit
    repo

    # ── Container / Dev env ─────────────────────────────────────
    devcontainer

    # ── Debug & Tracing ─────────────────────────────────────────
    strace
    busybox
    patchelf

    # ── Shell tools ─────────────────────────────────────────────
    shellcheck
    direnv
    nix-direnv

    # ── QEMU (user package for quick use) ───────────────────────
    qemu

    # ── Swig / code gen ─────────────────────────────────────────
    swig

    # ── Documentation ───────────────────────────────────────────
    mkdocs
  ];

  # ── direnv integration ──────────────────────────────────────────
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableBashIntegration = true;
  };
}

{ config, pkgs, ... }:

{
  home.packages = with pkgs; [
    # ── 编辑器 ─────────────────────────────────────────────────
    vscode
    vim

    # ── 构建系统 ───────────────────────────────────────────────
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

    # ── Rust（通过 rustup 管理）──────────────────────────────
    # 使用 `rustup` 管理 Rust 工具链
    rustup

    # ── 交叉编译工具链 ────────────────────────────────────────────
    pkgsCross.aarch64-multiplatform.buildPackages.gcc
    gcc-arm-embedded           # arm-none-eabi-gcc

    # ── 嵌入式 / SoC 工具 ─────────────────────────────────────────
    dtc                        # 设备树编译器
    ubootTools                 # mkimage etc.
    android-tools              # adb, fastboot
    mtdutils
    binwalk

    # ── 版本控制 / CI ───────────────────────────────────────────
    git
    git-lfs
    github-cli
    lazygit
    pre-commit
    gitRepo

    # ── 容器 / 开发环境 ─────────────────────────────────────────
    devcontainer

    # ── 调试与追踪 ───────────────────────────────────────────────
    strace
    busybox
    patchelf

    # ── Shell 工具 ───────────────────────────────────────────────
    shellcheck
    direnv
    nix-direnv

    # ── QEMU（用户级快速使用）─────────────────────────────────────────
    qemu

    # ── Swig / 代码生成 ─────────────────────────────────────────
    swig

    # ── 文档 ───────────────────────────────────────────────────
    mkdocs
  ];

  # ── direnv 集成 ──────────────────────────────────────────────────
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableBashIntegration = true;
  };
}

{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # ── 编辑器 ─────────────────────────────────────────────────
    unstable.vscode   # 使用 unstable 最新版 VS Code
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
    clang-tools  # clangd, clang-format 等，不与 gcc 冲突

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
    nodejs  # 已自带 npm 和 corepack
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

    # ── 交叉编译工具链 ──────────────────────────────────────────
    # 全局安装会与系统 gcc/gdb 的 man/info 冲突
    # 按需使用: nix shell nixpkgs#pkgsCross.aarch64-multiplatform.buildPackages.gcc
    #          nix shell nixpkgs#gcc-arm-embedded

    # ── 嵌入式 / SoC 工具 ─────────────────────────────────────────
    dtc                        # 设备树编译器
    ubootTools                 # mkimage etc.
    android-tools              # adb, fastboot
    mtdutils
    binwalk

    # ── 版本控制 / CI ───────────────────────────────────────────
    # git 和 lazygit 已在 packages.nix 中安装
    git-lfs
    github-cli
    pre-commit
    gitRepo

    # ── 容器 / 开发环境 ─────────────────────────────────────────
    devcontainer

    # ── 调试与追踪 ───────────────────────────────────────────────
    strace
    patchelf

    # ── Shell 工具 ───────────────────────────────────────────────
    # shellcheck 已在 packages.nix 中安装
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
  };
}

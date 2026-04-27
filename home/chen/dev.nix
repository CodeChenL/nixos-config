{ config, pkgs, lib, ... }:

let
  vscodeRuntimeLibPath = pkgs.lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
  ];

  wrapVSCode = package: binaryName:
    pkgs.symlinkJoin {
      name = "${package.pname or package.name}-with-runtime-libs";
      paths = [ package ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        rm -f $out/bin/${binaryName}
        makeWrapper ${lib.getExe' package binaryName} $out/bin/${binaryName} \
          --prefix LD_LIBRARY_PATH : ${vscodeRuntimeLibPath}
      '';
      meta = package.meta // {
        mainProgram = binaryName;
      };
    };

  guiRuntimeLibPath = pkgs.lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.libGL
    pkgs.wayland
    pkgs.libGLU
    pkgs.libxkbcommon
    pkgs.mesa
    pkgs.vulkan-loader
    pkgs.xorg.libX11
    pkgs.xorg.libXcursor
    pkgs.xorg.libXi
    pkgs.xorg.libXrandr
    pkgs.dbus.dev
  ];
  dotnetDnx = pkgs.writeShellScriptBin "dnx" ''
    exec ${lib.getExe' pkgs.dotnet-sdk_10 "dotnet"} dnx "$@"
  '';
in

{
  home.packages = with pkgs; [
    # ── 编辑器 ─────────────────────────────────────────────────
    (wrapVSCode unstable.vscode "code")   # 使用 unstable 最新版 VS Code
    vim

    # ── 构建系统 ───────────────────────────────────────────────
    cmake
    meson
    gnumake
    gnutls
    scons
    ccache
    ninja
    pkg-config
    bison
    flex
    gperf
    help2man
    asciidoc
    ctags

    # ── C/C++ / U-Boot / Linux 内核构建 ─────────────────────────
    gcc
    gdb
    clang-tools  # clangd, clang-format 等，不与 gcc 冲突
    perl
    ncurses
    ncurses.dev
    elfutils
    elfutils.dev
    libxkbcommon
    libxkbcommon.dev
    openssl
    openssl.dev

    # ── Python ──────────────────────────────────────────────────
    (python3.withPackages (ps: with ps; [
      numpy
      pyserial
      pyusb
      pyroute2
      websockets
      rich
      pip
      cryptography
    ]))
    (lib.lowPrio python2)
    python3Packages.pipx
    uv

    # ── Node.js ─────────────────────────────────────────────────
    nodejs  # 已自带 npm 和 corepack
    yarn
    nodePackages.prettier

    # ── .NET ────────────────────────────────────────────────────
    dotnet-sdk
    dotnetDnx

    # ── Go ──────────────────────────────────────────────────────
    go

    # ── Ruby ────────────────────────────────────────────────────
    ruby

    # ── Rust（通过 rustup 管理）──────────────────────────────
    # 使用 `rustup` 管理 Rust 工具链
    rustup

    # ── 交叉编译工具链 ──────────────────────────────────────────
    # 低优先级安装以避免与本机 gcc 的 man/info 文件冲突
    (lib.lowPrio pkgsCross.aarch64-multiplatform.buildPackages.gcc)
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

    # ─ 其他开发工具 ─────────────────
    pulseview
  ];

  # ── direnv 集成 ──────────────────────────────────────────────────
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
  home.sessionVariables = {
    LD_LIBRARY_PATH = "${guiRuntimeLibPath}:$LD_LIBRARY_PATH";
  };
}

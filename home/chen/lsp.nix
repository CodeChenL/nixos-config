{ pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    # ── Language servers ────────────────────────────────────────
    nixd
    bash-language-server
    dockerfile-language-server
    terraform-ls

    pyright
    basedpyright
    ruff
    ty

    typescript-language-server
    deno
    vue-language-server
    vscode-langservers-extracted
    oxlint
    biome
    svelte-language-server
    astro-language-server

    yaml-language-server
    texlab
    tinymist
    prisma

    gopls
    rust-analyzer
    zls
    sourcekit-lsp
    (lib.lowPrio dart)

    jdt-language-server
    kotlin-language-server
    roslyn-ls
    csharp-ls
    fsautocomplete

    lua-language-server
    rubocop
    intelephense

    haskell-language-server
    ocamlPackages.ocaml-lsp
    elixir-ls
    clojure-lsp
    gleam

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

    # ── C/C++ / 内核构建 ───────────────────────────────────────
    gcc
    gdb
    clang-tools
    perl
    ncurses
    ncurses.dev
    elfutils
    elfutils.dev
    dbus.dev
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
      west
      jsonschema
      pyelftools
    ]))
    uv

    # ── Node.js ─────────────────────────────────────────────────
    nodejs
    yarn
    prettier

    # ── Go / Ruby / Rust ───────────────────────────────────────
    go
    ruby
    (lib.lowPrio rustup)

    # ── 交叉编译（低优先级）────────────────────────────────────
    (lib.lowPrio pkgsCross.aarch64-multiplatform.buildPackages.gcc)

    # ── 嵌入式 / SoC 工具 ─────────────────────────────────────
    dtc
    ubootTools
    android-tools
    mtdutils
    binwalk
    picotool

    # ── 版本控制 / CI ──────────────────────────────────────────
    git-lfs
    github-cli
    pre-commit
    gitRepo

    # ── 容器 / 开发环境 ────────────────────────────────────────
    devcontainer

    # ── 调试 / Shell 工具 ──────────────────────────────────────
    strace
    patchelf
    direnv
    nix-direnv

    # ── QEMU ───────────────────────────────────────────────────
    qemu

    # ── 文档 / Swig ────────────────────────────────────────────
    swig
    mkdocs
  ];

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
}

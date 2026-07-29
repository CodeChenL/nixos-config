{ pkgs, lib, inputs, ... }:

let
  vscodeRuntimeLibPath = pkgs.lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.icu
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

  dotnetDnx = pkgs.writeShellScriptBin "dnx" ''
    exec ${lib.getExe' pkgs.dotnet-sdk_10 "dotnet"} dnx "$@"
  '';
in

{
  # WakaTime: 从 secrets 文件读取 API key，避免密钥进入 Git 和 nix store。
  home.activation.createWakaTimeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        WAKATIME_DIR="''${WAKATIME_HOME:-$HOME}"
        WAKATIME_CFG="$WAKATIME_DIR/.wakatime.cfg"
        WAKATIME_KEY_FILE="$HOME/nixos-config/secrets/wakatime.api_key"
        if [ -f "$WAKATIME_KEY_FILE" ]; then
          mkdir -p "$WAKATIME_DIR"
          WAKATIME_KEY=$(tr -d '\n' < "$WAKATIME_KEY_FILE")
          WAKATIME_CFG_TMP="$WAKATIME_CFG.tmp"
          (
            umask 077
            cat > "$WAKATIME_CFG_TMP" << EOF
[settings]
api_key = $WAKATIME_KEY
EOF
          )
          mv "$WAKATIME_CFG_TMP" "$WAKATIME_CFG"
          chmod 600 "$WAKATIME_CFG"
        fi
  '';

  home.packages = with pkgs; [
    # ── 编辑器 ─────────────────────────────────────────────────
    (wrapVSCode unstable.vscode "code") # 使用 unstable 最新版 VS Code
    vim
    opencode-desktop
    ngr # 用 NGR runtime 运行外部 GUI/ELF 二进制

    # ── Language servers ────────────────────────────────────────
    # 覆盖 opencode + oh-my-openagent 内置支持的 LSP server
    # Nix / Shell / 构建配置
    nixd
    bash-language-server
    dockerfile-language-server
    terraform-ls

    # Python
    pyright
    basedpyright
    ruff
    ty

    # JavaScript / TypeScript / Web
    typescript-language-server
    deno
    vue-language-server
    vscode-langservers-extracted # vscode-eslint-language-server 等
    oxlint
    biome
    svelte-language-server
    astro-language-server

    # 数据 / 配置 / 文档
    yaml-language-server
    texlab
    tinymist
    prisma

    # Go / Rust / Zig / 系统语言
    gopls
    rust-analyzer
    zls
    sourcekit-lsp
    (lib.lowPrio dart) # 避免与其他 LSP 包的顶层 LICENSE 文件冲突
    (julia.withPackages [ "LanguageServer" ])

    # JVM / .NET
    jdt-language-server
    kotlin-language-server
    roslyn-ls
    csharp-ls
    fsautocomplete

    # 脚本 / 动态语言
    lua-language-server
    rubocop # opencode/oh-my-openagent 的 ruby-lsp ID 使用 rubocop --lsp
    intelephense

    # 函数式 / 其他语言
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

    # ── C/C++ / U-Boot / Linux 内核构建 ─────────────────────────
    gcc
    gdb
    clang-tools # clangd, clang-format 等，不与 gcc 冲突
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
    (pipx.overridePythonAttrs (old: { doCheck = false; }))
    (lib.lowPrio python2)

    # ── Node.js ─────────────────────────────────────────────────
    nodejs # 已自带 npm 和 corepack
    yarn
    prettier

    # ── .NET ────────────────────────────────────────────────────
    dotnet-sdk
    dotnetDnx

    # ── Go ──────────────────────────────────────────────────────
    go

    # ── Ruby ────────────────────────────────────────────────────
    ruby

    # ── Rust ───────────────────────────────────────────────────
    (lib.lowPrio rustup)
    # 由 rustup 管理 Rust toolchain；降优先级以避免覆盖独立安装的 rust-analyzer

    # ── 交叉编译工具链 ──────────────────────────────────────────
    # 低优先级安装以避免与本机 gcc 的 man/info 文件冲突
    (lib.lowPrio pkgsCross.aarch64-multiplatform.buildPackages.gcc)
    #          nix shell nixpkgs#gcc-arm-embedded

    # ── 嵌入式 / SoC 工具 ─────────────────────────────────────────
    dtc # 设备树编译器
    ubootTools # mkimage etc.
    android-tools # adb, fastboot
    mtdutils
    binwalk
    picotool

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
    wakatime-cli

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

    # ─ 图形调试 / 基准 ─────────────────
    glmark2

    # ─ 其他开发工具 ─────────────────
    pulseview
  ];

  # ── direnv 集成 ──────────────────────────────────────────────────
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
}

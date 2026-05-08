{ pkgs, lib, ... }:

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

  dotnetDnx = pkgs.writeShellScriptBin "dnx" ''
    exec ${lib.getExe' pkgs.dotnet-sdk_10 "dotnet"} dnx "$@"
  '';
in

{
  # ── OpenCode 声明式配置 ───────────────────────────────────────
  # opencode.json: 模型、插件、行为配置（不含密钥，密钥由 auth.json 管理）
  xdg.configFile."opencode/opencode.json" = {
    force = true;
    text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      model = "openai/gpt-5.5";
      plugin = [ "oh-my-openagent" "opencode-pty" "@mohak34/opencode-notifier@latest" "opencode-wakatime" ];
      autoupdate = false;
      provider = {
        "openai" = {
          npm = "@ai-sdk/openai";
          name = "OpenAI";
          options.baseURL = "http://192.168.2.131:8080/v1";
        };
      };
    };
  };

  xdg.configFile."opencode/AGENTS.md" = {
    text = ''
      # Global OpenCode Rules

      面向用户的问答、澄清问题、执行说明和最终答复使用中文。

      用户明确要求其他语言时，才使用用户指定的语言。
    '';
  };

  # auth.json: /connect 供应商密钥，从 secrets 文件读取，避免密钥进 nix store
  home.activation.createOpencodeAuth = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        AUTH="$HOME/.local/share/opencode/auth.json"
        SECRETS="$HOME/nixos-config/secrets/opencode"
        if [ -f "$SECRETS/deepseek.key" ] \
          && [ -f "$SECRETS/opencode-go.key" ] \
          && [ -f "$SECRETS/xiaomi.key" ] \
          && [ -f "$SECRETS/minimax.key" ] \
          && [ -f "$SECRETS/nvidia.key" ] \
          && [ -f "$SECRETS/vamrs.key" ] \
          && [ -f "$SECRETS/github-copilot.access" ] \
          && [ -f "$SECRETS/github-copilot.refresh" ] \
          && [ -f "$SECRETS/github-copilot.expires" ]; then
          mkdir -p "$(dirname "$AUTH")"
          chmod 700 "$(dirname "$AUTH")"
          DSK=$(cat "$SECRETS/deepseek.key" | tr -d '\n')
          OCK=$(cat "$SECRETS/opencode-go.key" | tr -d '\n')
          XMK=$(cat "$SECRETS/xiaomi.key" | tr -d '\n')
          MMK=$(cat "$SECRETS/minimax.key" | tr -d '\n')
          NVK=$(cat "$SECRETS/nvidia.key" | tr -d '\n')
          VMK=$(cat "$SECRETS/vamrs.key" | tr -d '\n')
          CPA=$(cat "$SECRETS/github-copilot.access" | tr -d '\n')
          CPR=$(cat "$SECRETS/github-copilot.refresh" | tr -d '\n')
          CPE=$(cat "$SECRETS/github-copilot.expires" | tr -d '\n')
          AUTH_TMP="$AUTH.tmp"
          (
            umask 077
            cat > "$AUTH_TMP" << EOF
    {
      "opencode-go": {"type": "api", "key": "$OCK"},
      "deepseek": {"type": "api", "key": "$DSK"},
      "xiaomi-token-plan-cn": {"type": "api", "key": "$XMK"},
      "minimax-cn-coding-plan": {"type": "api", "key": "$MMK"},
      "nvidia": {"type": "api", "key": "$NVK"},
      "openai": {"type": "api", "key": "$VMK"},
      "github-copilot": {"type": "oauth", "access": "$CPA", "refresh": "$CPR", "expires": $CPE}
    }
    EOF
          )
          mv "$AUTH_TMP" "$AUTH"
          chmod 600 "$AUTH"
        fi
  '';

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
    ]))
    (lib.lowPrio python2)
    python3Packages.pipx
    uv

    # ── Node.js ─────────────────────────────────────────────────
    nodejs # 已自带 npm 和 corepack
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
    (lib.lowPrio rustup) # rustup 也带 rust-analyzer shim，避免覆盖显式 LSP

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

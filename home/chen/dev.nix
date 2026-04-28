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
  # ── OpenCode 声明式配置 ───────────────────────────────────────
  # opencode.json: 模型、插件、行为配置（不含密钥，密钥由 auth.json 管理）
  xdg.configFile."opencode/opencode.json" = {
    force = true;
    text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      model = "deepseek/deepseek-v4-pro";
      plugin = [ "oh-my-opencode" ];
      autoupdate = false;
      provider = {
        "vamrs" = {
          npm = "@ai-sdk/openai-compatible";
          name = "Vamrs";
          options.baseURL = "http://192.168.2.131:8080/v1";
          models = {
            "gpt-5.4" = {
              name = "GPT-5.4";
            };
            "gpt-5.2" = {
              name = "GPT-5.2";
            };
            "gpt-5.2-pro" = {
              name = "GPT-5.2 Pro";
            };
            "gpt-5.3-codex" = {
              name = "GPT-5.3 Codex";
            };
            "gpt-5.5" = {
              name = "GPT-5.5";
            };
            "gpt-5.4-mini" = {
              name = "GPT-5.4 Mini";
            };
          };
        };
      };
    };
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
      && [ -f "$SECRETS/vamrs.key" ]; then
      mkdir -p "$(dirname "$AUTH")"
      chmod 700 "$(dirname "$AUTH")"
      DSK=$(cat "$SECRETS/deepseek.key" | tr -d '\n')
      OCK=$(cat "$SECRETS/opencode-go.key" | tr -d '\n')
      XMK=$(cat "$SECRETS/xiaomi.key" | tr -d '\n')
      MMK=$(cat "$SECRETS/minimax.key" | tr -d '\n')
      NVK=$(cat "$SECRETS/nvidia.key" | tr -d '\n')
      VMK=$(cat "$SECRETS/vamrs.key" | tr -d '\n')
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
  "vamrs": {"type": "api", "key": "$VMK"}
}
EOF
      )
      mv "$AUTH_TMP" "$AUTH"
      chmod 600 "$AUTH"
    fi
  '';

  home.packages = with pkgs; [
    # ── 编辑器 ─────────────────────────────────────────────────
    (wrapVSCode unstable.vscode "code")   # 使用 unstable 最新版 VS Code
    vim
    opencode-desktop

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

    # ─ 图形调试 / 基准 ─────────────────
    glmark2
    mesa-demos

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

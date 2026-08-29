{ pkgs, lib, ... }:

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
  imports = [
    ./lsp.nix
  ];

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
    (pipx.overridePythonAttrs (old: { doCheck = false; }))
    (lib.lowPrio python2)

    # ── .NET ────────────────────────────────────────────────────
    dotnet-sdk
    dotnetDnx
    wakatime-cli

    # ─ 图形调试 / 基准 ─────────────────
    glmark2

    # ─ 其他开发工具 ─────────────────
    pulseview
  ];
}

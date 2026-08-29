# 自定义 Overlay：注入 unstable / master / NUR 通道包
#
# 约定：
#   - pkgs/<name>/default.nix: 直接返回包或包函数
#   - 子目录其他文件（patch、lock 等）放在 pkgs/<name>/ 内
#   - kernel/、cix-* 等独立 overlay 子目录继续保留为 callPackage
#   - 包需要在最终 attrset 中显式列出

inputs: final: prev:
let
  radxaLinkrDebuggerCtl =
    inputs.radxa-linkr-debugger.packages.${prev.stdenv.hostPlatform.system}.radxa-linkr-debuggerctl;

  claude-skills = final.runCommand "claude-skills" { } ''
    mkdir -p "$out"
    cp -r ${../skills}/. "$out/"

    packaged_skill="${radxaLinkrDebuggerCtl}/share/radxa-linkr-debugger/skills/radxa-linkr-debugger"
    if [ -e "$packaged_skill" ]; then
      ln -s "$packaged_skill" "$out/radxa-linkr-debugger"
    else
      echo "error: packaged radxa-linkr-debugger skill not found at $packaged_skill" >&2
      exit 1
    fi
  '';

  ngrLibraries = final.lib.unique (with final; [
    stdenv.cc.cc.lib
    libGL
    libGLU
    libgbm
    mesa
    vulkan-loader
    wayland
    glib
    nss
    nspr
    dbus
    atk
    at-spi2-core
    cups
    libdrm
    gtk3
    pango
    cairo
    expat
    alsa-lib
    libxkbcommon
    libx11
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxrandr
    libxcb
  ]);

  codexPackage = inputs.llm-agents.packages.${prev.stdenv.hostPlatform.system}.codex;
  # Codex client normalization: keep tool output adjacent to its call before
  # sending Responses requests, so strict providers tolerate hook-generated
  # developer messages in the same turn.
  codexPatchedSource = final.applyPatches {
    src = codexPackage.src;
    patches = [ ./pkgs/codex-client-normalize-order.patch ];
  };
  codexPatched = codexPackage.override {
    srcOverride = codexPatchedSource;
    sourceRoot = "${codexPatchedSource.name}/codex-rs";
  };
in
{
  unstable = import inputs.nixpkgs-unstable {
    system = prev.stdenv.hostPlatform.system;
    config = { allowUnfree = true; };
  };
  master = import inputs.nixpkgs-master {
    system = prev.stdenv.hostPlatform.system;
    config = {
      allowUnfree = true;
      permittedInsecurePackages = prev.config.permittedInsecurePackages or [ ];
    };
  };
  llm-agents = inputs.llm-agents.packages.${prev.stdenv.hostPlatform.system} // { codex = codexPatched; };

  nur =
    let
      baseNur = import inputs.NUR {
        pkgs = prev;
        nurpkgs = prev;
      };
      xddxddSrc = final.fetchFromGitHub {
        owner = "xddxdd";
        repo = "nur-packages";
        rev = "9f0cbc66157a3564f336712b93af8eb67d89fc31";
        hash = "sha256-m6rnRqqEbjZTvqeq8qOD5eCVxmKzFDIyuNaC/4irYBU=";
      };
      helperDeps = import (xddxddSrc + "/helpers/group.nix") {
        pkgs = final;
        lib = final.lib;
        mode = null;
        inputs = null;
      };
      fixedDingtalk = (helperDeps.createCallPackage { }) (xddxddSrc + "/pkgs/uncategorized/dingtalk") {
        inherit (helperDeps) sources;
        libICE = final.libice;
        libSM = final.libsm;
        libX11 = final.libx11;
        libxcb = final.libxcb;
        libXcomposite = final.libxcomposite;
        libXcursor = final.libxcursor;
        libXdamage = final.libxdamage;
        libXext = final.libxext;
        libXfixes = final.libxfixes;
        libXi = final.libxi;
        libXinerama = final.libxinerama;
        libXmu = final.libxmu;
        libXrandr = final.libxrandr;
        libXrender = final.libxrender;
        libXScrnSaver = final.libxscrnsaver;
        libXt = final.libxt;
        libXtst = final.libxtst;
        xcbutilimage = final.libxcb-image;
        xcbutilkeysyms = final.libxcb-keysyms;
        xcbutilrenderutil = final.libxcb-render-util;
        xcbutilwm = final.libxcb-wm;
      };
    in
    baseNur
    // {
      repos = baseNur.repos // {
        xddxdd = baseNur.repos.xddxdd // {
          dingtalk = fixedDingtalk;
        };
      };
    };

  inherit ngrLibraries claude-skills;

  gleam = prev.gleam.overrideAttrs (oldAttrs: {
    checkFlags = (oldAttrs.checkFlags or [ ]) ++ [
      "--skip=tests::escript_success_with_dependency"
    ];
  });

  applyDebianPatches = import ./apply-debian-patches.nix { inherit (final) lib; };
  linux-cix-main = final.callPackage ./linux-cix-main { };
  linuxPackages-cix-main = (final.linuxKernel.packagesFor final.linux-cix-main).extend (lfinal: lprev: {
    cix-vpu-driver = final.callPackage ./cix-vpu-driver { kernel = final.linux-cix-main; };
    cix-npu-driver = final.callPackage ./cix-npu-driver { kernel = final.linux-cix-main; };
  });
  cix-dsp-firmware = final.callPackage ./cix-dsp-firmware { };
  cix-vpu-firmware = final.callPackage ./cix-vpu-firmware { };
  cix-vpu-headers = final.callPackage ./cix-vpu-headers { };

  # WPS Office: 上游包已经自带匹配私有 Qt 的 fcitx platform plugin，
  # 只在桌面入口注入输入法环境，保持命令行启动行为不变。
  wpsoffice-cn = final.symlinkJoin {
    name = "wpsoffice-cn-fcitx-desktop";
    paths = [ prev.wpsoffice-cn ];
    postBuild = ''
      for desktop in $out/share/applications/*.desktop; do
        [ -e "$desktop" ] || continue
        if [ -L "$desktop" ]; then
          cp --remove-destination "$(readlink -f "$desktop")" "$desktop"
        fi
        substituteInPlace "$desktop" \
          --replace-fail "Exec=${prev.wpsoffice-cn}/bin/" "Exec=${final.coreutils}/bin/env QT_IM_MODULE=fcitx ${prev.wpsoffice-cn}/bin/"
      done

      ! grep -R "^Exec=${prev.wpsoffice-cn}/bin" "$out/share/applications"
    '';
  };

  codex-desktop-api-key = import ./pkgs/codex-desktop-api-key { inherit inputs final prev; };
  freedownloadmanager = import ./pkgs/freedownloadmanager { inherit inputs final prev; };
  llama-cpp-full = import ./pkgs/llama-cpp-full { inherit inputs final prev; };
  natfrp-service = import ./pkgs/natfrp-service { inherit inputs final prev; };
  pgyvisitor = import ./pkgs/pgyvisitor { inherit inputs final prev; };
  radxa-linkr-debuggerctl = radxaLinkrDebuggerCtl;
  rustty = inputs.rustty.packages.${prev.stdenv.hostPlatform.system}.rustty;
  sub2api = import ./pkgs/sub2api { inherit inputs final prev; };
}

# 自定义 Overlay：注入 unstable / master / NUR 通道包
#
# 约定：
#   - pkgs/<name>/default.nix: 单包定义（self: super: { name = ...; }）
#   - 子目录其他文件（patch、lock 等）放在 pkgs/<name>/ 内
#   - kernel/、cix-* 等独立 overlay 子目录继续保留为 callPackage
#   - 通配符导入（mapModules）保证新增包自动生效

inputs: final: prev:
let
  # pkgs/<name>/default.nix -> { <name> = ...; }
  # 签名约定：每个子包接受 final.callPackage 调用
  collectPkgs = dir:
    let
      entries = builtins.readDir dir;
      subdirs = builtins.filter (n: entries.${n} == "directory") (builtins.attrNames entries);
    in
    builtins.foldl' (acc: name:
      let
        path = dir + "/${name}/default.nix";
        exists = builtins.pathExists path;
      in
      if exists then acc // (import path { inherit inputs; inherit final prev; })
      else acc
    ) { } subdirs;

  userPackages = collectPkgs ./pkgs;

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

  ngr = final.writeShellScriptBin "ngr" ''
    if [ "$#" -eq 0 ]; then
      echo "usage: ngr <program> [args...]" >&2
      exit 64
    fi

    export LD_LIBRARY_PATH="${final.lib.makeLibraryPath ngrLibraries}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    exec "$@"
  '';
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
  llm-agents = inputs.llm-agents.packages.${prev.stdenv.hostPlatform.system};

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

  inherit ngrLibraries ngr claude-skills;

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

  inherit (userPackages)
    freedownloadmanager
    trae-cn
    github-copilot-cli
    llama-cpp-full
    natfrp-service
    pgyvisitor
    radxa-linkr-debuggerctl
    rustty
    ;
}

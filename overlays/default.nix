# 自定义 Overlay：注入 unstable / master / NUR 通道包
inputs: final: prev:
let
  freedownloadmanager = final.callPackage (
    {
      lib,
      stdenv,
      fetchurl,
      dpkg,
      makeWrapper,
      kdePackages,
      gtk3,
      atk,
      cairo,
      gdk-pixbuf,
      pango,
      openssl,
      icu,
      mysql80,
      libdrm,
      pipewire,
      autoPatchelfHook,
      patchelf,
      desktop-file-utils,
    }:

    let
      qmlImportPath = lib.makeSearchPath "lib/qt-6/qml" [
        kdePackages.qtdeclarative
        kdePackages.qtmultimedia
        kdePackages.qtwayland
        kdePackages.qt5compat
      ];
      pipewireLibPath = lib.makeLibraryPath [ pipewire ];
    in
    stdenv.mkDerivation (finalAttrs: {
      pname = "freedownloadmanager";
      version = "6.33.2.6656";
      dontWrapQtApps = true;

      src = fetchurl {
        url = "https://files2.freedownloadmanager.org/6/latest/freedownloadmanager.deb";
        hash = "sha256-n1Y6h9xXeqU6LO6h66qlnT9wsjFYqToaAPJ8sTYL9Gg=";
      };

      nativeBuildInputs = [
        dpkg
        autoPatchelfHook
        patchelf
        makeWrapper
        desktop-file-utils
      ];

      buildInputs = [
        kdePackages.qtbase
        kdePackages.qtdeclarative
        kdePackages.qtmultimedia
        kdePackages.qtwayland
        kdePackages.qt5compat

        gtk3
        atk
        cairo
        gdk-pixbuf
        pango

        openssl
        icu
        mysql80
        libdrm
        pipewire
      ];

      installPhase = ''
        runHook preInstall

        mkdir -p $out/bin $out/opt $out/share/applications $out/share/pixmaps

        cp -r opt/freedownloadmanager $out/opt/
        cp -r usr/share/applications/* $out/share/applications/

        makeWrapper $out/opt/freedownloadmanager/fdm $out/bin/fdm \
          --unset QT_PLUGIN_PATH \
          --set QML2_IMPORT_PATH '${qmlImportPath}' \
          --set NIXPKGS_QT6_QML_IMPORT_PATH '${qmlImportPath}' \
          --prefix LD_LIBRARY_PATH : "$out/opt/freedownloadmanager/lib:${pipewireLibPath}" \
          --prefix XDG_DATA_DIRS : "$out/share"

        ln -s $out/opt/freedownloadmanager/icon.png $out/share/pixmaps/freedownloadmanager.png

        local desktopFile="$out/share/applications/freedownloadmanager.desktop"
        local image_plugin_dir="$out/opt/freedownloadmanager/plugins/imageformats"

        desktop-file-edit \
          --set-key=Exec --set-value=fdm \
          --set-key=Icon --set-value=freedownloadmanager \
          "$desktopFile"

        local sql_plugin_dir="$out/opt/freedownloadmanager/plugins/sqldrivers"
        if [ -f "$sql_plugin_dir/libqsqlmimer.so" ]; then
          patchelf --remove-needed libmimerapi.so "$sql_plugin_dir/libqsqlmimer.so" || echo "Warning: Failed to patch libqsqlmimer.so"
        fi

        rm -f "$sql_plugin_dir/libqsqlite.so"
        cp "${kdePackages.qtbase}/lib/qt-6/plugins/sqldrivers/libqsqlite.so" "$sql_plugin_dir/libqsqlite.so"

        rm -f \
          "$image_plugin_dir/libqtiff.so" \
          "$sql_plugin_dir/libqsqlibase.so" \
          "$sql_plugin_dir/libqsqloci.so"

        if [ ! -f "$sql_plugin_dir/libqsqlmysql.so" ]; then
          echo "Warning: MySQL plugin libqsqlmysql.so not found."
        fi

        runHook postInstall
      '';

      preFixup = ''
        local lib_dir="$out/opt/freedownloadmanager/lib"
        rm -vf $lib_dir/libQt6*.so.6
        rm -vf $lib_dir/libicu*.so.*
        rm -vf $lib_dir/libcrypto.so*
        rm -vf $lib_dir/libssl.so*
        rm -rf $out/opt/freedownloadmanager/qml
      '';

      meta = {
        description = "Download manager supporting many protocols";
        homepage = "https://www.freedownloadmanager.org";
        license = lib.licenses.unfree;
        platforms = [ "x86_64-linux" ];
        sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
        mainProgram = "fdm";
      };
    })
  ) { };

  trae-cn = final.callPackage (
    {
      lib,
      stdenv,
      fetchurl,
      dpkg,
      autoPatchelfHook,
      desktop-file-utils,
      alsa-lib,
      atk,
      at-spi2-atk,
      at-spi2-core,
      cairo,
      cups,
      dbus,
      expat,
      glib,
      gnutls,
      gtk3,
      libgcrypt,
      libsecret,
      libdrm,
      libxkbcommon,
      libsoup_3,
      mesa,
      nspr,
      nss,
      pango,
      systemd,
      webkitgtk_4_1,
      xorg,
    }:

    stdenv.mkDerivation (finalAttrs: {
      pname = "trae-cn";
      version = "2.3.20622";
      dontStrip = true;

      src = fetchurl {
        url = "https://lf-cdn.trae.com.cn/obj/trae-com-cn/pkg/app/releases/stable/${finalAttrs.version}/linux/Trae%20CN-linux-x64.deb";
        hash = "sha256-FM4V8Q3ka5p/HgGFuLmCcpfCkfIxey6sk2d4MmTsbic=";
      };

      nativeBuildInputs = [
        dpkg
        autoPatchelfHook
        desktop-file-utils
      ];

      buildInputs = [
        alsa-lib
        atk
        at-spi2-atk
        at-spi2-core
        cairo
        cups
        dbus
        expat
        glib
        gnutls
        gtk3
        libgcrypt
        libsecret
        libdrm
        libxkbcommon
        libsoup_3
        mesa
        nspr
        nss
        pango
        systemd
        webkitgtk_4_1
        xorg.libX11
        xorg.libXcomposite
        xorg.libXdamage
        xorg.libXext
        xorg.libXfixes
        xorg.libXrandr
        xorg.libxcb
        xorg.libxkbfile
      ];

      installPhase = ''
        runHook preInstall

        mkdir -p $out/bin $out/share

        cp -r usr/share/appdata $out/share/
        cp -r usr/share/applications $out/share/
        cp -r usr/share/bash-completion $out/share/
        cp -r usr/share/mime $out/share/
        cp -r usr/share/pixmaps $out/share/
        cp -r usr/share/trae-cn $out/share/

        ln -s $out/share/trae-cn/bin/trae-cn $out/bin/trae-cn

        desktop-file-edit \
          --set-key=Exec --set-value="$out/share/trae-cn/trae-cn %F" \
          --set-key=Icon --set-value=trae-cn \
          "$out/share/applications/trae-cn.desktop"

        desktop-file-edit \
          --set-key=Exec --set-value="$out/share/trae-cn/trae-cn --open-url %U" \
          --set-key=Icon --set-value=trae-cn \
          "$out/share/applications/trae-cn-url-handler.desktop"

        runHook postInstall
      '';

      preFixup = ''
        find $out/share/trae-cn -type f \( -name '*musl*.node' -o -path '*/musl-*-Release/*' \) -delete
      '';

      meta = {
        description = "TRAE CN AI IDE";
        homepage = "https://trae.ai/";
        license = lib.licenses.unfree;
        platforms = [ "x86_64-linux" ];
        sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
        mainProgram = "trae-cn";
      };
    })
  ) { };

  copilot-api = final.callPackage (
    { lib, buildNpmPackage, fetchurl }:
    buildNpmPackage rec {
      pname = "copilot-api";
      version = "0.7.0";

      src = fetchurl {
        url = "https://registry.npmjs.org/${pname}/-/${pname}-${version}.tgz";
        hash = "sha256-H8z9K/6L+74AwapTX/uitxMfx7yR64MOPUx4v+TwYiA=";
      };

      sourceRoot = "package";
      patches = [ ./copilot-api-refresh-retry.patch ];
      postPatch = ''
        cp ${./copilot-api-package-lock.json} package-lock.json
      '';

      npmDepsHash = "sha256-WJTnG9xeyRnExMe26nIjF0ehOfEj+aCPF7SCu6LkJe0=";
      dontNpmBuild = true;
      npmFlags = [ "--ignore-scripts" ];
      npmPackFlags = [ "--ignore-scripts" ];

      meta = {
        description = "Turn GitHub Copilot into OpenAI/Anthropic API compatible server";
        homepage = "https://github.com/eric-ch/copilot-api";
        license = lib.licenses.mit;
        mainProgram = "copilot-api";
      };
    }
  ) { };

  github-copilot-cli = final.callPackage (
    { lib, stdenvNoCC, fetchzip, makeWrapper }:
    stdenvNoCC.mkDerivation rec {
      pname = "github-copilot-cli";
      version = "1.0.19";

      src = fetchzip {
        url = "https://registry.npmjs.org/@github/copilot-linux-x64/-/copilot-linux-x64-${version}.tgz";
        hash = "sha256-x3w6X3zpruarOlz6mVZLUMAUmXosjsymU3wX1UZ4Lkc=";
      };

      nativeBuildInputs = [ makeWrapper ];

      installPhase = ''
        runHook preInstall

        install -d $out/lib/${pname} $out/bin
        cp -r ./* $out/lib/${pname}/

        makeWrapper $out/lib/${pname}/copilot $out/bin/copilot \
          --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ final.stdenv.cc.cc.lib ]}

        runHook postInstall
      '';

      meta = {
        description = "GitHub Copilot CLI for the terminal";
        homepage = "https://github.com/github/copilot-cli";
        downloadPage = "https://www.npmjs.com/package/@github/copilot";
        license = lib.licenses.unfree;
        mainProgram = "copilot";
        platforms = [ "x86_64-linux" ];
      };
    }
  ) { };

  natfrp-service = final.callPackage (
    { lib, stdenvNoCC, fetchzip, zstd }:
    let
      version = "3.1.8";
      arch = if final.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
      hash = if final.stdenv.hostPlatform.isAarch64
        then "sha256-O27KIOwCoBEZzIzFnGMs9DSG6ZeY/Lb02zhXUkLNuUw="
        else "sha256-MvM7aSUP51ohRr8UEgSTUmxcmpn9jbTLtpBLYSH2x+Y=";
    in
    stdenvNoCC.mkDerivation {
      pname = "natfrp-service";
      inherit version;

      src = fetchzip {
        url = "https://nya.globalslb.net/natfrp/client/launcher-unix/${version}/natfrp-service_linux_${arch}.tar.zst";
        inherit hash;
        nativeBuildInputs = [ zstd ];
        stripRoot = false;
      };

      installPhase = ''
        runHook preInstall

        install -Dm755 frpc $out/bin/frpc
        install -Dm755 natfrp-service $out/bin/natfrp-service

        runHook postInstall
      '';

      dontPatchELF = true;
      dontStrip = true;

      meta = {
        description = "SakuraFrp launcher service";
        homepage = "https://www.natfrp.com";
        license = lib.licenses.unfree;
        sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
        mainProgram = "natfrp-service";
        platforms = [ "x86_64-linux" "aarch64-linux" ];
      };
    }
  ) { };

  # opencode CLI: 使用 npm 包，避免 glibc 兼容性问题
  # npm 包使用标准路径 /lib/ld-linux-aarch64.so.1，由 NixOS 自动解析
  opencode = let
    unstableOpencode = final.unstable.opencode;
    version = unstableOpencode.version;
    # 根据架构选择正确的 npm 包
    platformPkg = if final.stdenv.hostPlatform.isAarch64
      then final.fetchurl {
        url = "https://registry.npmjs.org/opencode-linux-arm64/-/opencode-linux-arm64-${version}.tgz";
        sha256 = "7dc33d6d062fb369dbef98cf0c48286a58f6e9ba96a808aa537cc674df2686ac";
      }
      else final.fetchurl {
        url = "https://registry.npmjs.org/opencode-linux-x64/-/opencode-linux-x64-${version}.tgz";
        sha256 = ""; # TODO: 需要为 x86_64 更新
      };
  in
    final.runCommand "opencode-${version}" {
      nativeBuildInputs = [ final.makeWrapper ];
      meta = unstableOpencode.meta;
    } ''
      mkdir -p $out/bin $out/lib/opencode

      # 解压 npm 包
      tar xzf ${platformPkg} -C $out/lib/opencode --strip-components=1

      # 创建 wrapper
      makeWrapper $out/lib/opencode/bin/opencode $out/bin/opencode \
        --prefix PATH : ${final.lib.makeBinPath [ final.ripgrep ]}
    '';

  opencode-desktop = final.callPackage (
    {
      lib,
      stdenv,
      fetchurl,
      dpkg,
      autoPatchelfHook,
      desktop-file-utils,
      makeWrapper,
      alsa-lib,
      at-spi2-atk,
      at-spi2-core,
      cairo,
      cups,
      dbus,
      expat,
      glib,
      gnutls,
      gtk3,
      libgcrypt,
      libsecret,
      libdrm,
      libxkbcommon,
      libsoup_3,
      mesa,
      nspr,
      nss,
      pango,
      systemd,
      xorg,
    }:

    stdenv.mkDerivation (finalAttrs: {
      pname = "opencode-desktop";
      version = "1.14.29";
      dontStrip = true;

      src = fetchurl {
        url = "https://github.com/anomalyco/opencode/releases/download/v${finalAttrs.version}/opencode-electron-linux-amd64.deb";
        hash = "sha256-t8/wao/83EGU70IP77J6eJPebYb5mUls7VdKxcPbVMA=";
      };

      nativeBuildInputs = [
        dpkg
        autoPatchelfHook
        desktop-file-utils
        makeWrapper
      ];

      buildInputs = [
        alsa-lib
        at-spi2-atk
        at-spi2-core
        cairo
        cups
        dbus
        expat
        glib
        gnutls
        gtk3
        libgcrypt
        libsecret
        libdrm
        libxkbcommon
        libsoup_3
        mesa
        nspr
        nss
        pango
        systemd
        xorg.libX11
        xorg.libXcomposite
        xorg.libXdamage
        xorg.libXext
        xorg.libXfixes
        xorg.libXrandr
        xorg.libxcb
      ];

      installPhase = ''
        runHook preInstall

        mkdir -p $out/bin $out/share/applications $out/share/icons

        cp -r opt/OpenCode $out/share/opencode-desktop
        cp -r usr/share/icons/hicolor $out/share/icons/

        makeWrapper $out/share/opencode-desktop/@opencode-aidesktop-electron $out/bin/opencode-desktop \
          --add-flags --disable-gpu

        install -Dm644 /dev/stdin $out/share/applications/opencode-desktop.desktop << EOF
[Desktop Entry]
Name=OpenCode
Exec=$out/bin/opencode-desktop %U
Terminal=false
Type=Application
Icon=$out/share/icons/hicolor/284x284/apps/@opencode-aidesktop-electron.png
StartupWMClass=OpenCode
MimeType=x-scheme-handler/opencode;
Categories=Development;
EOF

        runHook postInstall
      '';

      meta = {
        description = "OpenCode AI coding agent desktop app";
        homepage = "https://opencode.ai";
        license = lib.licenses.mit;
        platforms = [ "x86_64-linux" ];
        sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
        mainProgram = "opencode-desktop";
      };
    })
  ) { };

  radxa-linkr-debuggerctl =
    inputs.radxa-linkr-debugger.packages.${prev.stdenv.hostPlatform.system}.radxa-linkr-debuggerctl;

  claude-skills = final.runCommand "claude-skills" { } ''
    mkdir -p "$out"
    cp -r ${../skills}/. "$out/"

    packaged_skill="${radxa-linkr-debuggerctl}/share/radxa-linkr-debugger/skills/radxa-linkr-debugger"
    if [ -e "$packaged_skill" ]; then
      ln -s "$packaged_skill" "$out/radxa-linkr-debugger"
    else
      echo "error: packaged radxa-linkr-debugger skill not found at $packaged_skill" >&2
      exit 1
    fi
  '';

in
{
  unstable = import inputs.nixpkgs-unstable {
    system = prev.stdenv.hostPlatform.system;
    config = { allowUnfree = true; };
  };
  master = import inputs.nixpkgs-master {
    system = prev.stdenv.hostPlatform.system;
    config = { allowUnfree = true; };
  };
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
        libICE = final.xorg.libICE;
        libSM = final.xorg.libSM;
        libX11 = final.xorg.libX11;
        libxcb = final.xorg.libxcb;
        libXcomposite = final.xorg.libXcomposite;
        libXcursor = final.xorg.libXcursor;
        libXdamage = final.xorg.libXdamage;
        libXext = final.xorg.libXext;
        libXfixes = final.xorg.libXfixes;
        libXi = final.xorg.libXi;
        libXinerama = final.xorg.libXinerama;
        libXmu = final.xorg.libXmu;
        libXrandr = final.xorg.libXrandr;
        libXrender = final.xorg.libXrender;
        libXScrnSaver = final.xorg.libXScrnSaver;
        libXt = final.xorg.libXt;
        libXtst = final.xorg.libXtst;
        xcbutilimage = final.xorg.xcbutilimage;
        xcbutilkeysyms = final.xorg.xcbutilkeysyms;
        xcbutilrenderutil = final.xorg.xcbutilrenderutil;
        xcbutilwm = final.xorg.xcbutilwm;
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

  ngrLibraries = final.lib.unique (with final; [
    # Native GUI/runtime libraries for nix-ld and ad-hoc GUI binaries.
    stdenv.cc.cc.lib

    # GL / Wayland / Vulkan
    libGL
    libGLU
    libgbm
    mesa
    vulkan-loader
    wayland

    # Electron / Chromium / GTK runtime stack
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

    # X11
    xorg.libX11
    xorg.libXcomposite
    xorg.libXcursor
    xorg.libXdamage
    xorg.libXext
    xorg.libXfixes
    xorg.libXi
    xorg.libXrandr
    xorg.libxcb
  ]);

  ngr = final.writeShellScriptBin "ngr" ''
    if [ "$#" -eq 0 ]; then
      echo "usage: ngr <program> [args...]" >&2
      exit 64
    fi

    export LD_LIBRARY_PATH="${final.lib.makeLibraryPath final.ngrLibraries}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    exec "$@"
  '';

  # ── linux-cix-main: Linux v7.0 + CIX Sky1 patches ─────────────────
  linux-cix-main = final.callPackage ./linux-cix-main { };
  linuxPackages-cix-main = (final.linuxKernel.packagesFor final.linux-cix-main).extend (lfinal: lprev: {
    # 将 VPU/NPU DKMS 驱动添加到内核模块包命名空间
    cix-vpu-driver = final.callPackage ./cix-vpu-driver { kernel = final.linux-cix-main; };
    cix-npu-driver = final.callPackage ./cix-npu-driver { kernel = final.linux-cix-main; };
  });

  # ── cix-dsp-firmware: CIX Sky1 DSP 固件 ──────────────────────────
  cix-dsp-firmware = final.callPackage ./cix-dsp-firmware { };

  inherit
    freedownloadmanager
    trae-cn
    copilot-api
    github-copilot-cli
    natfrp-service
    opencode
    opencode-desktop
    radxa-linkr-debuggerctl
    claude-skills
    ;
}

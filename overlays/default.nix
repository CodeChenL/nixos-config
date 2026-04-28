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
  nur = import inputs.NUR {
    pkgs = prev;
    nurpkgs = prev;
  };

  inherit
    freedownloadmanager
    trae-cn
    copilot-api
    github-copilot-cli
    opencode-desktop
    ;
}

# overlays/pkgs/freedownloadmanager/default.nix
# 包拆分：每个文件对应 overlays/default.nix 中的一个 let 绑定
# 签名：{ inputs, final, prev } -> { freedownloadmanager = ...; }
{ inputs, final, prev }:

{
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
      mysql84,
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
        hash = "sha256-sjrXzR3MBWxJz7WHQQdV66dfx3tChfXqX1Psi2kzaKM=";
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
        mysql84
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
          --set QT_QPA_PLATFORM xcb \
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
          "$sql_plugin_dir/libqsqlmysql.so" \
          "$sql_plugin_dir/libqsqlibase.so" \
          "$sql_plugin_dir/libqsqloci.so"

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
}

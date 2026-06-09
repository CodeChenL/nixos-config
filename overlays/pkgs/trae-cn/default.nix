# overlays/pkgs/trae-cn/default.nix
{ inputs, final, prev }:

{
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
      libx11,
      libxcomposite,
      libxdamage,
      libxext,
      libxfixes,
      libxrandr,
      libxcb,
      libxkbfile,
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
        libx11
        libxcomposite
        libxdamage
        libxext
        libxfixes
        libxrandr
        libxcb
        libxkbfile
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
}

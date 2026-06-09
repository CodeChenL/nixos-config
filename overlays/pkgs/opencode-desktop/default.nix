# overlays/pkgs/opencode-desktop/default.nix
{ inputs, final, prev }:

{
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
      libx11,
      libxcomposite,
      libxdamage,
      libxext,
      libxfixes,
      libxrandr,
      libxcb,
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
        libx11
        libxcomposite
        libxdamage
        libxext
        libxfixes
        libxrandr
        libxcb
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
}

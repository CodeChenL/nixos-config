{ inputs, final, prev }:

let
  skillSrc = final.fetchzip {
    url = "https://github.com/mixelpixx/Konnect/archive/a22ad2153dcf45dbcf1cc63b5b0f1e40c93d7956.tar.gz";
    hash = "sha256-6rcfSGqa+SO7bH5a23Q2XpI7UhzNKAowK+IM0xh8LDo=";
  };
in

final.callPackage (
  {
    lib,
    stdenv,
    fetchurl,
    autoPatchelfHook,
    patchelf,
    unzip,
    cairo,
    dbus,
    gdk-pixbuf,
    glib,
    gtk3,
    libsoup_3,
    webkitgtk_4_1,
    skillSrc,
  }:

  stdenv.mkDerivation (finalAttrs: {
    pname = "konnect";
    version = "0.11.0";

    src = fetchurl {
      url = "https://github.com/mixelpixx/Konnect/releases/download/v${finalAttrs.version}/konnect-pcm-v${finalAttrs.version}-linux.zip";
      hash = "sha256-a46lOiyy1g9/OltbYYwcMx0k48qEGse+1GbVNwj+ED8=";
    };

    nativeBuildInputs = [
      autoPatchelfHook
      patchelf
      unzip
    ];

    buildInputs = [
      cairo
      dbus
      gdk-pixbuf
      glib
      gtk3
      libsoup_3
      stdenv.cc.cc.lib
      webkitgtk_4_1
    ];

    unpackPhase = ''
      runHook preUnpack
      ${unzip}/bin/unzip -q "$src"
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/bin" "$out/share/kicad/plugins/konnect" "$out/share/kicad/konnect" "$out/share/agents/skills"

      cp -a plugins/bin/konnect "$out/bin/konnect"
      cp -a plugins/bin/schematic-viewer "$out/bin/schematic-viewer"
      cp -a plugins/. "$out/share/kicad/plugins/konnect/"
      cp -a metadata.json "$out/share/kicad/konnect/metadata.json"
      cp -a "${skillSrc}/crates/konnect/assets/skills/." "$out/share/agents/skills/"

      runHook postInstall
    '';

    meta = {
      description = "Native KiCad MCP server for AI-assisted PCB design";
      homepage = "https://github.com/mixelpixx/Konnect";
      license = lib.licenses.agpl3Only;
      mainProgram = "konnect";
      platforms = [ "x86_64-linux" ];
    };
  })
  ) { inherit skillSrc; }

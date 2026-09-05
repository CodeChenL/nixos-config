{
  lib,
  stdenv,
  zip,
  addonPath,
  python3,
  konnect,
}:

stdenv.mkDerivation {
  pname = "konnect-addon";
  version = "0.11.0";
  dontUnpack = true;

  nativeBuildInputs = [
    zip
  ];

  installPhase = ''
    runHook preInstall

    staging="$TMPDIR/konnect-addon"
    mkdir -p "$staging/plugins" "$staging/resources" "$out"

    cp "${konnect}/share/kicad/konnect/metadata.json" "$staging/metadata.json"
    cp -a "${konnect}/share/kicad/plugins/konnect/." "$staging/plugins/"
    cp "${konnect}/share/kicad/plugins/konnect/resources/icon.png" "$staging/resources/icon.png"

    chmod -R u+w "$staging"
    (cd "$staging" && ${zip}/bin/zip -q -r "$out/${addonPath}" .)

    runHook postInstall
  '';

  meta = {
    description = "Konnect addon.zip for the native KiCad addons mechanism";
    homepage = "https://github.com/mixelpixx/Konnect";
    license = lib.licenses.agpl3Only;
    platforms = [ "x86_64-linux" ];
  };
}

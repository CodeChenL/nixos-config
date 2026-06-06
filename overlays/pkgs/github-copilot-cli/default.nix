# overlays/pkgs/github-copilot-cli/default.nix
{ inputs, final, prev }:

{
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
}

# overlays/pkgs/natfrp-service/default.nix
{ inputs, final, prev }:

final.callPackage (
    { lib, stdenvNoCC, fetchzip, zstd }:
    let
      version = "3.1.8";
      arch = if final.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
      hash = if final.stdenv.hostPlatform.isAarch64
        then "sha256-O27KIOwCoBEZzIzFnGMs9DSG6ZeY/Lb02zhXUkLNuUw="
        else "sha256-kCJm2kdos43WoikFoFDhDVkU7EjlFoK1+4ASG/CvUTA=";
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
  ) { }

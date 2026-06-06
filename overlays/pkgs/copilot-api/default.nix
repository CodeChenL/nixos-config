# overlays/pkgs/copilot-api/default.nix
# patch 和 lockfile 仍放在 overlays/ 顶层（与原来一致），不重复
{ inputs, final, prev }:

{
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
      patches = [ ../copilot-api-refresh-retry.patch ];
      postPatch = ''
        cp ${../copilot-api-package-lock.json} package-lock.json
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
}

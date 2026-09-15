{ final, ... }:

assert final.unstable.ghidra.version == "12.1.2";
assert final.unstable.python3Packages.mcp.version == "1.29.0";

let
  version = "6.0.0";

  bridge = final.unstable.python3Packages.buildPythonApplication {
    pname = "ghidra-mcp-bridge";
    inherit version;
    format = "wheel";

    src = final.fetchurl {
      url = "https://github.com/bethington/ghidra-mcp/releases/download/v${version}/ghidra_mcp_bridge-${version}-py3-none-any.whl";
      hash = "sha256-cZOaiQAJgmZkcgFm2PeG86LqJGD37/zYPHN1m6QkEzQ=";
    };

    dependencies = [ final.unstable.python3Packages.mcp ];
    pythonImportsCheck = [ "bridge_mcp_ghidra" ];

    meta = {
      description = "MCP bridge for Ghidra";
      homepage = "https://github.com/bethington/ghidra-mcp";
      license = final.lib.licenses.asl20;
      mainProgram = "bridge-mcp-ghidra";
      platforms = [ "x86_64-linux" ];
    };
  };

  extension = final.stdenvNoCC.mkDerivation {
    pname = "ghidra-mcp-extension";
    inherit version;

    src = final.fetchurl {
      url = "https://github.com/bethington/ghidra-mcp/releases/download/v${version}/GhidraMCP-${version}.zip";
      hash = "sha256-hncx3ifVFDYyoBCUO5B6ZIXdVNDhlyni+F7p9pLJmHM=";
    };

    nativeBuildInputs = [ final.unzip ];
    dontUnpack = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      extensions_root="$out/lib/ghidra/Ghidra/Extensions"
      mkdir -p "$extensions_root"
      unzip -q "$src" -d "$extensions_root"
      test -d "$extensions_root/GhidraMCP"
      touch "$extensions_root/GhidraMCP/.dbDirLock"

      runHook postInstall
    '';

    meta = {
      description = "Ghidra extension for ghidra-mcp";
      homepage = "https://github.com/bethington/ghidra-mcp";
      license = final.lib.licenses.asl20;
      platforms = [ "x86_64-linux" ];
    };
  };

  ghidraWithExtension = final.unstable.ghidra.withExtensions (_: [ extension ]);
in
{
  inherit bridge extension ghidraWithExtension;
}

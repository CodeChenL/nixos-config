{ final, ... }:

assert final.unstable.ghidra.version == "12.1.4";

let
  version = "6.0.0";

  # ghidra-mcp 6.0.0 声明 mcp>=1.28.1,<2.0.0；unstable 的 python3Packages.mcp
  # 已升到 2.x，这里固定 1.29.0 专供 bridge（wheel 直装，依赖取 nixpkgs 现成包）。
  mcp1 = final.unstable.python3Packages.buildPythonPackage rec {
    pname = "mcp";
    version = "1.29.0";
    format = "wheel";
    src = final.fetchurl {
      url = "https://files.pythonhosted.org/packages/01/c8/248b201f6d753d69fd5d6506011abbb35a946d9142b2ae311a948fd0be3d/mcp-1.29.0-py3-none-any.whl";
      hash = "sha256-9aB1u2EfI9b00IDGoWmfpidy7rxWK6nmazBt3eHHVfc=";
    };
    dependencies = with final.unstable.python3Packages; [
      anyio
      httpx
      httpx-sse
      jsonschema
      pydantic
      pydantic-settings
      pyjwt
      python-multipart
      sse-starlette
      starlette
      typing-extensions
      typing-inspection
      uvicorn
    ];
    pythonImportsCheck = [ "mcp" ];
    meta = {
      description = "Model Context Protocol SDK (pinned 1.x for ghidra-mcp bridge)";
      license = final.lib.licenses.mit;
    };
  };

  bridge = final.unstable.python3Packages.buildPythonApplication {
    pname = "ghidra-mcp-bridge";
    inherit version;
    format = "wheel";

    src = final.fetchurl {
      url = "https://github.com/bethington/ghidra-mcp/releases/download/v${version}/ghidra_mcp_bridge-${version}-py3-none-any.whl";
      hash = "sha256-cZOaiQAJgmZkcgFm2PeG86LqJGD37/zYPHN1m6QkEzQ=";
    };

    dependencies = [ mcp1 ];
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

  ghidraWithExtension = final.symlinkJoin {
    name = "ghidra-with-mcp-${final.unstable.ghidra.version}";
    paths = [ (final.unstable.ghidra.withExtensions (_: [ extension ])) ];
    nativeBuildInputs = [ final.makeWrapper ];
    # ghidra-mcp >= v5.4.1 gates /run_script_inline and /run_ghidra_script
    # behind GHIDRA_MCP_ALLOW_SCRIPTS. The flag is read by the GhidraMCP
    # extension inside the Ghidra JVM, so it must be set on the Ghidra
    # launcher itself (the MCP bridge never inspects it).
    postBuild = ''
      wrapProgram $out/bin/ghidra --set GHIDRA_MCP_ALLOW_SCRIPTS 1
      wrapProgram $out/bin/ghidra-analyzeHeadless --set GHIDRA_MCP_ALLOW_SCRIPTS 1
    '';
  };
in
{
  inherit bridge extension ghidraWithExtension;
}

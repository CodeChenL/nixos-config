# overlays/pkgs/radxa-linkr-debuggerctl/default.nix
# 注意：radxa-linkr-debugger 来自 flake input，不是 nixpkgs
{ inputs, final, prev }:

{
  radxa-linkr-debuggerctl =
    inputs.radxa-linkr-debugger.packages.${prev.stdenv.hostPlatform.system}.radxa-linkr-debuggerctl;
}

# Ponytail plugin encapsulation.
#
# `enable` is the single switch: when false, `tomlSection` is empty and no
# activations are registered.

{ lib, pkgs, enable }:

let
  ponytailMarketplaceName = "ponytail";
  ponytailMarketplaceSource = "https://github.com/DietrichGebert/ponytail.git";
  ponytailPluginName = "ponytail";
  ponytailPluginId = "${ponytailPluginName}@${ponytailMarketplaceName}";
  hookTrustUpdater = pkgs.writeScript "hook-trust-updater.js" (builtins.readFile ./hook-trust-updater.js);

  tomlSection = lib.optionalString enable ''
    [marketplaces.${ponytailMarketplaceName}]
    source_type = "git"
    source = "${ponytailMarketplaceSource}"
    ref = "main"

    [plugins."${ponytailPluginId}"]
    enabled = true
  '';

  activations = lib.optionalAttrs enable {
    installPonytail = lib.hm.dag.entryAfter [ "materializeCodexConfig" ] ''
      if [ -n "$DRY_RUN_CMD" ]; then
        printf '%s\n' "Would ensure ponytail marketplace snapshot"
        printf '%s\n' "Would run: codex plugin add ponytail@ponytail"
      else
        export PATH=${lib.escapeShellArg (lib.makeBinPath [ pkgs.git ])}:$PATH
        if [ ! -f "$HOME/.codex/.tmp/marketplaces/${ponytailMarketplaceName}/.codex-plugin/plugin.json" ]; then
          ${pkgs.llm-agents.codex}/bin/codex plugin marketplace add DietrichGebert/ponytail --ref main
        fi
        ${pkgs.llm-agents.codex}/bin/codex plugin add ${ponytailPluginId}
      fi
    '';

    trustPonytailHooks = lib.hm.dag.entryAfter [ "installPonytail" ] ''
      if [ -n "$DRY_RUN_CMD" ]; then
        printf '%s\n' "Would trust Ponytail hooks for the installed marketplace revision"
      else
        PLUGIN_VERSION="$(
          ${pkgs.llm-agents.codex}/bin/codex plugin list --json |
            ${pkgs.jq}/bin/jq -er --arg pluginId ${lib.escapeShellArg ponytailPluginId} '
              [.installed[] | select(.pluginId == $pluginId and .installed == true and (.version | type) == "string" and (.version | length) > 0)]
              | if length == 1 then .[0].version else error("expected exactly one installed plugin: \($pluginId)") end
            '
        )"
        PLUGIN_ROOT="$HOME/.codex/plugins/cache/${ponytailMarketplaceName}/${ponytailPluginName}/$PLUGIN_VERSION"

        ${pkgs.nodejs}/bin/node "${hookTrustUpdater}" plugin \
          "$PLUGIN_ROOT" "$HOME/.codex/config.toml" "${ponytailPluginId}"
      fi
    '';
  };
in
{
  inherit tomlSection activations;
}

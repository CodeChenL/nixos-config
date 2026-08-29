# OMO plugin encapsulation.
#
# Encapsulates everything OMO-specific: the config.toml marketplace/plugin/
# agents sections, and the plugin installation/trust activations.
#
# `enable` is the single switch: when false, `tomlSection` is empty and no
# OMO activations are registered (no marketplace upgrade, no bootstrap).
# When true, everything is restored on the next rebuild.
#
# Output: { tomlSection, activations }

{ lib, pkgs, enable }:

let
  omoMarketplaceName = "sisyphuslabs";
  omoMarketplaceSource = "https://github.com/code-yeongyu/lazycodex.git";
  omoPluginName = "omo";
  omoPluginId = "${omoPluginName}@${omoMarketplaceName}";

  tomlSection = lib.optionalString enable ''
    [marketplaces.${omoMarketplaceName}]
    source_type = "git"
    source = "${omoMarketplaceSource}"

    [plugins."${omoPluginId}"]
    enabled = true

    [plugins."${omoPluginId}".mcp_servers.context7]
    enabled = true

    [plugins."${omoPluginId}".mcp_servers.codegraph]
    enabled = true

    [plugins."${omoPluginId}".mcp_servers.git_bash]
    enabled = false

    [agents.explorer]
    config_file = "./agents/explorer.toml"

    [agents.lazycodex-clone-fidelity-reviewer]
    config_file = "./agents/lazycodex-clone-fidelity-reviewer.toml"

    [agents.lazycodex-code-reviewer]
    config_file = "./agents/lazycodex-code-reviewer.toml"

    [agents.lazycodex-gate-reviewer]
    config_file = "./agents/lazycodex-gate-reviewer.toml"

    [agents.lazycodex-qa-executor]
    config_file = "./agents/lazycodex-qa-executor.toml"

    [agents.lazycodex-worker-high]
    config_file = "./agents/lazycodex-worker-high.toml"

    [agents.lazycodex-worker-low]
    config_file = "./agents/lazycodex-worker-low.toml"

    [agents.lazycodex-worker-medium]
    config_file = "./agents/lazycodex-worker-medium.toml"

    [agents.librarian]
    config_file = "./agents/librarian.toml"

    [agents.metis]
    config_file = "./agents/metis.toml"

    [agents.momus]
    config_file = "./agents/momus.toml"

    [agents.plan]
    config_file = "./agents/plan.toml"
  '';

  activations = lib.optionalAttrs enable {
    installOmo = lib.hm.dag.entryAfter [ "materializeCodexConfig" ] ''
      if [ -n "$DRY_RUN_CMD" ]; then
        printf '%s\n' "Would run: codex plugin marketplace upgrade sisyphuslabs"
        printf '%s\n' "Would run: codex plugin add omo@sisyphuslabs"
      else
        export PATH=${lib.escapeShellArg (lib.makeBinPath [ pkgs.git ])}:$PATH
        ${pkgs.llm-agents.codex}/bin/codex plugin marketplace upgrade sisyphuslabs
        ${pkgs.llm-agents.codex}/bin/codex plugin add omo@sisyphuslabs
      fi
    '';

    # OMO's plugin hooks are hash-trusted in config.toml after the current
    # marketplace revision is installed.  Use Codex's plugin data root so the
    # later SessionStart hook sees the same bootstrap state.  --once is
    # intentional: the config materialization above replaces config.toml on
    # every Home Manager run.
    trustOmoHooks = lib.hm.dag.entryAfter [ "installOmo" ] ''
      if [ -n "$DRY_RUN_CMD" ]; then
        printf '%s\n' "Would trust OMO hooks for the installed marketplace revision"
      else
        MARKETPLACE_PLUGIN_ROOT="$HOME/.codex/.tmp/marketplaces/${omoMarketplaceName}/plugins/${omoPluginName}"
        PLUGIN_VERSION="$(${pkgs.jq}/bin/jq -er '.version' "$MARKETPLACE_PLUGIN_ROOT/.codex-plugin/plugin.json")"
        PLUGIN_ROOT="$HOME/.codex/plugins/cache/${omoMarketplaceName}/${omoPluginName}/$PLUGIN_VERSION"

        if [ ! -s "$PLUGIN_ROOT/components/bootstrap/dist/cli.js" ]; then
          printf '%s\n' "Installed OMO bootstrap payload is missing: $PLUGIN_ROOT" >&2
          exit 1
        fi

        export CODEX_HOME="$HOME/.codex"
        export PLUGIN_ROOT
        export PLUGIN_DATA="$HOME/.codex/plugins/data/${omoPluginName}-${omoMarketplaceName}"
        ${pkgs.nodejs}/bin/node "$PLUGIN_ROOT/components/bootstrap/dist/cli.js" \
          worker --codex-home "$CODEX_HOME" --only setup --once
      fi
    '';

  };
in
{
  inherit tomlSection activations;
}

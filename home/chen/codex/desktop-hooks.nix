# User-level Codex Desktop feature hook trust.
#
# Codex Desktop's `mcp-helper-reaper` feature writes `CODEX_HOME/hooks.json`
# on cold start. Home Manager regenerates `config.toml` on every switch and
# would otherwise drop the `hooks.state` trust entry for that user-level hook.

{ lib, pkgs, config }:

let
  appDir = "${config.programs.codexDesktopLinux.package}/opt/codex-desktop";
  reaperHookMarker = "codex-mcp-helper-reaper-session";
  installScript = "${appDir}/.codex-linux/mcp-helper-reaper/install-session-hook.sh";
  hookTrustUpdater = pkgs.writeScript "hook-trust-updater.js" (builtins.readFile ./hook-trust-updater.js);

  activations = {
    trustDesktopReaperHook = lib.hm.dag.entryAfter [ "materializeCodexConfig" ] ''
      if [ -n "$DRY_RUN_CMD" ]; then
        printf '%s\n' "Would refresh and trust the Desktop mcp-helper-reaper hook"
      else
        if [ ! -x "${installScript}" ]; then
          printf '%s\n' "Desktop mcp-helper-reaper feature is absent; skipping user hook trust" >&2
          exit 0
        fi

        export PATH=${lib.escapeShellArg (lib.makeBinPath [ pkgs.python3 pkgs.nodejs ])}:$PATH
        CODEX_LINUX_APP_DIR=${lib.escapeShellArg appDir} "${installScript}"
        ${pkgs.nodejs}/bin/node "${hookTrustUpdater}" hooks \
          "$HOME/.codex/hooks.json" "$HOME/.codex/config.toml" "${reaperHookMarker}"
      fi
    '';
  };
in
{
  inherit activations;
}

{ config, lib, pkgs, ... }:

# KiCad's Konnect addon is wired through pkgs.kicad.override in overlays/default.nix,
# so KiCad owns the plugin. This module adds the MCP runtime paths and enables the IPC API.
{
  home.packages = [
    pkgs.kicad
    pkgs.konnect
  ];

  home.file = {
    ".konnect/.installed-codex".text = "0.11.0";

    ".config/konnect/config.toml".text = ''
      kicad_cli = "${pkgs.kicad}/bin/kicad-cli"
      kicad_binary = "${pkgs.kicad}/bin/kicad"
      ipc_address = "ipc:///tmp/kicad/api.sock"
      jlcpcb_db_path = "${config.home.homeDirectory}/.konnect/jlcpcb.db"
      log_level = "info"
      transport = "stdio"
    '';
  };

  home.activation.kicadApi = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    CONFIG_DIR="$HOME/.config/kicad/10.0"
    CONFIG="$CONFIG_DIR/kicad_common.json"
    CONFIG_TMP="$CONFIG_DIR/.kicad_common.json.home-manager-new"

    if [ -n "$DRY_RUN_CMD" ]; then
      printf '%s\n' "Would enable KiCad API at $CONFIG"
    else
      ${pkgs.coreutils}/bin/mkdir -p "$CONFIG_DIR"
      if [ -f "$CONFIG" ]; then
        ${pkgs.jq}/bin/jq '.api.enable_server = true | .api.interpreter_path = "${pkgs.python3}/bin/python3"' "$CONFIG" > "$CONFIG_TMP" || exit 1
      else
        ${pkgs.jq}/bin/jq -n '{api: {enable_server: true, interpreter_path: "${pkgs.python3}/bin/python3"}}' > "$CONFIG_TMP" || exit 1
      fi
      ${pkgs.coreutils}/bin/mv -f "$CONFIG_TMP" "$CONFIG"
    fi
  '';
}

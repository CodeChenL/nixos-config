# Codex auth.json materialization activation.
#
# The API key is read from the user's secrets directory at activation time
# and never lands in the Nix store. Mirrors the checks of the old inline
# activation: symlink rejection, ownership/mode 0600, single-line content,
# atomic install via mktemp + mv.

{ lib, pkgs }:

{
  createCodexAuth = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    AUTH_DIR="$HOME/.codex"
    AUTH="$AUTH_DIR/auth.json"
    SOURCE="$HOME/nixos-config/secrets/opencode/and.key"

    if [ -f "$AUTH" ] && ${pkgs.jq}/bin/jq -e 'has("tokens") or has("account_id") or .auth_mode == "chatgpt"' "$AUTH" >/dev/null 2>&1; then
      printf '%s\n' "Codex ChatGPT auth detected; preserving OAuth credentials." >&2
    else
      # This is embedded in Home Manager's shared activation script: exiting
      # here would skip every later activation entry, including OMO install.
      if [ ! -e "$SOURCE" ]; then
      printf '%s\n' "Codex API key source is missing." >&2
      exit 1
    fi

    if [ -L "$SOURCE" ]; then
      printf '%s\n' "Codex API key source must not be a symlink." >&2
      exit 1
    fi

    if [ ! -f "$SOURCE" ]; then
      printf '%s\n' "Codex API key source must be a regular file." >&2
      exit 1
    fi

    if [ -L "$AUTH" ]; then
      printf '%s\n' "Codex auth target must not be a symlink." >&2
      exit 1
    fi

    if [ -e "$AUTH" ] && [ ! -f "$AUTH" ]; then
      printf '%s\n' "Codex auth target must be a regular file." >&2
      exit 1
    fi

    if ! SOURCE_UID="$(${pkgs.coreutils}/bin/stat -c '%u' "$SOURCE")"; then
      printf '%s\n' "Failed to inspect Codex API key owner." >&2
      exit 1
    fi

    if ! SOURCE_MODE="$(${pkgs.coreutils}/bin/stat -c '%a' "$SOURCE")"; then
      printf '%s\n' "Failed to inspect Codex API key mode." >&2
      exit 1
    fi

    if ! USER_UID="$(${pkgs.coreutils}/bin/id -u)"; then
      printf '%s\n' "Failed to inspect activation user id." >&2
      exit 1
    fi

    if [ "$SOURCE_UID" != "$USER_UID" ] || [ "$SOURCE_MODE" != "600" ]; then
      printf '%s\n' "Codex API key source must be owned by the activation user with mode 0600." >&2
      exit 1
    fi

    if ! ${pkgs.jq}/bin/jq -ne --rawfile key "$SOURCE" \
      '$key | test("\\A[^\\r\\n]+\\n?\\z")' > /dev/null; then
      printf '%s\n' "Codex API key source must contain one non-empty line without CR." >&2
      exit 1
    fi

    if [ -z "$DRY_RUN_CMD" ]; then
      if ! ${pkgs.coreutils}/bin/install -d -m 0700 "$AUTH_DIR"; then
        printf '%s\n' "Failed to create Codex auth directory." >&2
        exit 1
      fi

      if ! ${pkgs.coreutils}/bin/chmod 0700 "$AUTH_DIR"; then
        printf '%s\n' "Failed to set Codex auth directory permissions." >&2
        exit 1
      fi

      (
        AUTH_TMP=""
        cleanup() {
          if [ -n "$AUTH_TMP" ]; then
            ${pkgs.coreutils}/bin/rm -f "$AUTH_TMP"
          fi
        }
        trap cleanup EXIT HUP INT TERM

        if ! AUTH_TMP="$(${pkgs.coreutils}/bin/mktemp "$AUTH_DIR/.auth.json.XXXXXX")"; then
          printf '%s\n' "Failed to create temporary Codex auth file." >&2
          exit 1
        fi

        if ! ${pkgs.jq}/bin/jq -nce --rawfile key "$SOURCE" \
          '{ auth_mode: "apikey", OPENAI_API_KEY: ($key | sub("\\n$"; "")) }' \
          > "$AUTH_TMP"; then
          printf '%s\n' "Failed to generate Codex auth." >&2
          exit 1
        fi

        if ! ${pkgs.coreutils}/bin/chmod 0600 "$AUTH_TMP"; then
          printf '%s\n' "Failed to set Codex auth file permissions." >&2
          exit 1
        fi

        if ! ${pkgs.coreutils}/bin/mv -fT -- "$AUTH_TMP" "$AUTH"; then
          printf '%s\n' "Failed to install Codex auth." >&2
          exit 1
        fi
      )
    fi
    fi
  '';
}

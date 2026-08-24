{ lib, pkgs, ... }:

let
  codexConfigTemplate = pkgs.writeText "codex-config.toml" ''
    model_provider = "OpenAI"
    model = "gpt-5.6-sol"
    review_model = "gpt-5.6-sol"
    model_context_window = 922000 # OpenAI max input; Codex 0.149.1 may clamp to its bundled catalog ceiling.
    model_reasoning_effort = "max"
    personality = "pragmatic"
    disable_response_storage = true
    network_access = "enabled"
    windows_wsl_setup_acknowledged = true
    cli_auth_credentials_store = "file"
    sandbox_mode = "workspace-write"
    web_search = "live"
    model_verbosity = "high"
    model_reasoning_summary = "detailed"

    [model_providers.OpenAI]
    name = "OpenAI"
    base_url = "http://43.133.254.201:8082/v1" # Trusted endpoint by explicit user request; API credentials travel in cleartext.
    wire_api = "responses"
    supports_websockets = true
    requires_openai_auth = true
    http_headers = { "x-openai-actor-authorization" = "local-image-extension" }

    [sandbox_workspace_write]
    network_access = true

    [features]
    goals = true
    js_repl = false
    memories = true

    [history]
    persistence = "none"

    [desktop]
    followUpQueueMode = "steer"
    localeOverride = "zh-CN"
    preventSleepWhileRunning = true
    show-context-window-usage = true
    enabled-reasoning-efforts = [ "low", "medium", "high", "xhigh", "ultra", "max" ]
    avatar-overlay-mascot-width-px = 80
    open-link-in-target-preference = "external-browser"
    open-local-url-in-target-preference = "external-browser"
    git-pull-request-merge-method = "merge"

    [memories]
    generate_memories = true
    use_memories = true
  '';
in

{
  # Codex API key is materialized only at activation time, never in the Nix store.
  home.activation.createCodexAuth = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        AUTH_DIR="$HOME/.codex"
        AUTH="$AUTH_DIR/auth.json"
        SOURCE="$HOME/nixos-config/secrets/opencode/and.key"

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
  '';

  home.activation.materializeCodexConfig = lib.hm.dag.entryAfter [ "createCodexAuth" ] ''
    CONFIG_DIR="$HOME/.codex"
    CONFIG="$CONFIG_DIR/config.toml"
    CONFIG_TMP="$CONFIG_DIR/.config.toml.home-manager-new"

    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$CONFIG_DIR"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "$CONFIG_TMP"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -m 0600 \
      "${codexConfigTemplate}" "$CONFIG_TMP"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mv -fT "$CONFIG_TMP" "$CONFIG"
  '';
}

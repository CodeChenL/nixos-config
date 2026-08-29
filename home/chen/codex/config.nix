# Codex config.toml rendering (everything except OMO-specific sections).
#
# Renders the full config.toml template: provider declarations (rendered
# from attributed data), profiles, feature/history/desktop/memories
# sections, openai-bundled plugin sections, node_repl MCP, and injectable
# `${omoSection}` / `${ponytailSection}` sections (empty when their switches
# are disabled).
#
# Inputs:
#   catalogs        — store paths from catalog.nix
#   omoSection      — OMO TOML section string (may be empty)
#   ponytailSection — Ponytail TOML section string (may be empty)
#   codex*          — Codex Desktop resource paths (from default.nix)
# Output: { codexConfigTemplate, profileFiles }

{ lib, pkgs, config, catalogs, omoSection, ponytailSection, codexDesktopResources, codexBundledMarketplace, codexNodeRepl, codexNodeReplModules, codexBrowserService, codexAppVersion }:

let
  secretDirectory = "${config.home.homeDirectory}/nixos-config/secrets/opencode";
  providerAuth = secretName: {
    command = "/run/current-system/sw/bin/cat";
    args = [ "${secretDirectory}/${secretName}" ];
    timeout_ms = 5000;
    refresh_interval_ms = 300000;
  };
  providers = {
    ChenIdeaCentre = {
      name = "ChenIdeaCentre";
      base_url = "http://chenjaly.cn:8080/v1";
      wire_api = "responses";
      auth = providerAuth "and.key";
      http_headers = { "x-openai-actor-authorization" = "local-image-extension"; };
    };
    deepseek = { name = "DeepSeek"; base_url = "https://api.deepseek.com"; wire_api = "responses"; auth = providerAuth "deepseek.key"; };
    xiaomi = { name = "Xiaomi MiMo Token Plan (China)"; base_url = "https://token-plan-cn.xiaomimimo.com/v1"; wire_api = "responses"; auth = providerAuth "xiaomi.key"; };
    minimax = { name = "MiniMax"; base_url = "https://api.minimaxi.com/v1"; wire_api = "responses"; auth = providerAuth "minimax.key"; };
  };
  toml = pkgs.formats.toml { };
  profiles = {
    "openai-proxy" = { model_provider = "ChenIdeaCentre"; model = "gpt-5.6-sol"; model_reasoning_effort = "max"; model_catalog_json = catalogs.proxy; };
    deepseek = { model_provider = "deepseek"; model = "deepseek-v4-pro"; model_reasoning_effort = "high"; model_catalog_json = catalogs.deepseek; };
    xiaomi = { model_provider = "xiaomi"; model = "mimo-v2.5-pro"; model_reasoning_effort = "high"; model_catalog_json = catalogs.xiaomi; };
    minimax = { model_provider = "minimax"; model = "MiniMax-M3"; model_reasoning_effort = "high"; model_catalog_json = catalogs.minimax; };
  };
  profileFiles = lib.mapAttrs' (name: profile: lib.nameValuePair ".codex/${name}.config.toml" {
    force = true;
    source = toml.generate "codex-${name}-profile.toml" profile;
  }) profiles;

  staticConfig = {
    model_provider = "ChenIdeaCentre";
    model = "gpt-5.6-sol";
    model_catalog_json = catalogs.proxy;
    review_model = "gpt-5.6-sol";
    model_context_window = 922000;
    model_supports_reasoning_summaries = true;
    model_reasoning_effort = "max";
    personality = "pragmatic";
    disable_response_storage = true;
    network_access = "enabled";
    windows_wsl_setup_acknowledged = true;
    cli_auth_credentials_store = "file";
    sandbox_mode = "workspace-write";
    web_search = "disabled";
    model_verbosity = "high";
    model_reasoning_summary = "detailed";
    model_providers = providers;

    sandbox_workspace_write = { network_access = true; };
    features = {
      multi_agent = true;
      plugin_hooks = true;
      goals = true;
      js_repl = false;
      memories = true;
      plugins = true;
      enable_mcp_apps = true;
      remote_compaction_v2 = false;
      multi_agent_v2 = { max_concurrent_threads_per_session = 16; };
    };
    history = { persistence = "none"; };
    desktop = {
      followUpQueueMode = "steer";
      localeOverride = "zh-CN";
      preventSleepWhileRunning = true;
      "show-context-window-usage" = true;
      "enabled-reasoning-efforts" = [ "low" "medium" "high" "xhigh" "ultra" "max" ];
      "avatar-overlay-mascot-width-px" = 80;
      "open-link-in-target-preference" = "external-browser";
      "open-local-url-in-target-preference" = "external-browser";
      "git-pull-request-merge-method" = "merge";
      codeFontSize = 20;
      sansFontSize = 16;
      appearanceTheme = "light";
    };
    memories = {
      generate_memories = true;
      use_memories = true;
    };

    marketplaces."openai-bundled" = {
      source_type = "local";
      source = codexBundledMarketplace;
    };
    plugins."codex-app-tools@openai-bundled" = { enabled = true; };
    plugins."browser@openai-bundled" = { enabled = true; };
    plugins."visualize@openai-bundled" = { enabled = true; };

    mcp_servers.node_repl = {
      args = [ ];
      command = codexNodeRepl;
      startup_timeout_sec = 120;
      env = {
        NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS = "1000";
        NODE_REPL_NODE_MODULE_DIRS = codexNodeReplModules;
        NODE_REPL_NODE_PATH = "${codexDesktopResources}/cua_node/bin/node";
        NODE_REPL_TRUSTED_CODE_PATHS = "${config.home.homeDirectory}/.codex:${codexNodeReplModules}";
        CODEX_HOME = "${config.home.homeDirectory}/.codex";
        BROWSER_USE_AVAILABLE_BACKENDS = "chrome,iab";
        BROWSER_USE_TINYSKY_ENABLED = "0";
        NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = "Control the in-app browser in conjunction with the Browser Plugin.";
        NODE_REPL_INSTRUCTIONS_USE_CASE_CHROME = "Control the Chrome browser in conjunction with the Chrome Plugin. Prefer this method of controlling Chrome over alternatives (such as Computer Use) unless the user explicitly mentions an alternative.";
        BROWSER_USE_CODEX_APP_BUILD_FLAVOR = "prod";
        BROWSER_USE_CODEX_APP_VERSION = codexAppVersion;
        NODE_REPL_TRUSTED_SERVICES = "{\"browser\":\"${codexBrowserService}\",\"sky\":\"@oai/sky/service\"}";
        CODEX_CLI_PATH = "${pkgs.llm-agents.codex}/bin/codex";
      };
    };
  };

  codexConfigTemplate = pkgs.concatText "codex-config.toml" [
    (toml.generate "codex-config-static.toml" staticConfig)
    (pkgs.writeText "codex-config-extras.toml" (omoSection + ponytailSection))
  ];
in
{
  inherit codexConfigTemplate profileFiles;
}

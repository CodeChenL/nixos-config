{ config, inputs, lib, pkgs, ... }:

let
  omoMarketplaceName = "sisyphuslabs";
  omoMarketplaceSource = "https://github.com/code-yeongyu/lazycodex.git";
  omoPluginName = "omo";
  omoPluginId = "${omoPluginName}@${omoMarketplaceName}";
  codexDesktopResources = "${config.programs.codexDesktopLinux.package}/opt/codex-desktop/resources";
  codexBundledMarketplace = "${codexDesktopResources}/plugins/openai-bundled";
  codexNodeRepl = "${codexDesktopResources}/cua_node/bin/node_repl";
  codexNodeReplModules = "${codexDesktopResources}/cua_node/lib/node_modules";
  codexBrowserService = "${codexBundledMarketplace}/plugins/browser/scripts/browser-service.mjs";
  codexAppVersion = config.programs.codexDesktopLinux.package.version;
  codexModelConfig =
    let
      secretDirectory = "${config.home.homeDirectory}/nixos-config/secrets/opencode";
      baseInstructions =
        "You are Codex, a coding agent. You and the user share the same workspace and collaborate to achieve the user's goals.";
      reasoningDescriptions = {
        none = "Disable Thinking";
        minimal = "Minimal reasoning";
        low = "Fast responses with lighter reasoning";
        medium = "Balances speed and reasoning depth for everyday tasks";
        high = "Greater reasoning depth for complex problems";
        xhigh = "Extra high reasoning depth for complex problems";
        max = "Maximum reasoning depth for the hardest problems";
        ultra = "Ultra reasoning depth";
      };
      # Read the locked Models.dev TOML files used by OpenCode. Canonical
      # model metadata supplies limits/modalities; provider files supply
      # provider-specific limits and reasoning_options.
      readModelsDev = relativePath:
        builtins.fromTOML (builtins.readFile "${inputs.models-dev}/${relativePath}");
      canonicalModel = modelId: readModelsDev "models/${modelId}.toml";
      providerModel = providerId: modelId: readModelsDev "providers/${providerId}/models/${modelId}.toml";
      providerOverlay = canonicalId: providerId: providerModelId:
        lib.recursiveUpdate (canonicalModel canonicalId) (providerModel providerId providerModelId);
      modelsDev = {
        "openai/gpt-5.6-sol" = providerOverlay "openai/gpt-5.6-sol" "openai" "gpt-5.6-sol";
        "openai/gpt-5.6-terra" = providerOverlay "openai/gpt-5.6-terra" "openai" "gpt-5.6-terra";
        "openai/gpt-5.6-luna" = providerOverlay "openai/gpt-5.6-luna" "openai" "gpt-5.6-luna";
        "openai/gpt-5.5" = providerOverlay "openai/gpt-5.5" "openai" "gpt-5.5";
        "openai/gpt-5.4" = providerOverlay "openai/gpt-5.4" "openai" "gpt-5.4";
        "openai/gpt-5.4-mini" = providerOverlay "openai/gpt-5.4-mini" "openai" "gpt-5.4-mini";
        "openai/gpt-5.3-codex-spark" = providerOverlay "openai/gpt-5.3-codex-spark" "openai" "gpt-5.3-codex-spark";
        "openai/gpt-5.2" = providerOverlay "openai/gpt-5.2" "openai" "gpt-5.2";
        "moonshotai/kimi-k3" = providerOverlay "moonshotai/kimi-k3" "kimi-for-coding" "k3";
        "moonshotai/kimi-for-coding/k3-256k" = providerOverlay "moonshotai/kimi-k3" "kimi-for-coding" "k3-256k";
        "moonshotai/kimi-k2.7-code" = providerOverlay "moonshotai/kimi-k2.7-code" "kimi-for-coding" "kimi-for-coding";
        "moonshotai/kimi-k2.7-code-highspeed" = providerOverlay "moonshotai/kimi-k2.7-code-highspeed" "kimi-for-coding" "kimi-for-coding-highspeed";
        "deepseek/deepseek-v4-flash" = providerOverlay "deepseek/deepseek-v4-flash" "deepseek" "deepseek-v4-flash";
        "deepseek/deepseek-v4-flash-vision-exp" = providerOverlay "deepseek/deepseek-v4-flash-vision-exp" "deepseek" "deepseek-v4-flash-vision-exp";
        "deepseek/deepseek-v4-pro" = providerOverlay "deepseek/deepseek-v4-pro" "deepseek" "deepseek-v4-pro";
        "xiaomi/mimo-v2.5-pro" = providerOverlay "xiaomi/mimo-v2.5-pro" "xiaomi-token-plan-cn" "mimo-v2.5-pro";
        "xiaomi/mimo-v2.5" = providerOverlay "xiaomi/mimo-v2.5" "xiaomi-token-plan-cn" "mimo-v2.5";
        "minimax/MiniMax-M3" = providerOverlay "minimax/MiniMax-M3" "minimax" "MiniMax-M3";
      };
      mkModel = spec:
        let
          modelData = builtins.getAttr spec.modelsDevId modelsDev;
          modelName = spec.displayName or spec.slug;
          reasoningOptions = modelData.reasoning_options or [ ];
          effortOption = lib.findFirst (option: option.type == "effort") null reasoningOptions;
          toggleOption = lib.findFirst (option: option.type == "toggle") null reasoningOptions;
          # Codex has no separate toggle field. Represent a toggle-only
          # provider as the closest two-state effort list, but do not invent
          # controls for models.dev entries that declare no options at all.
          levels =
            spec.reasoningLevels or
              (if effortOption != null then effortOption.values else if toggleOption != null then [ "none" "high" ] else [ ]);
          modelContextWindow = modelData.limit.input or modelData.limit.context;
          modelModalities = lib.filter (modality: lib.elem modality [ "text" "image" "audio" ]) modelData.modalities.input;
        in
        {
          slug = spec.slug;
          display_name = modelName;
          description = spec.description or (modelData.description or "${modelName} via the configured provider");
          base_instructions = spec.baseInstructions or baseInstructions;
          supported_reasoning_levels = map (effort: {
            inherit effort;
            description = lib.attrByPath [ effort ] "Reasoning effort: ${effort}" reasoningDescriptions;
          }) levels;
          shell_type = "shell_command";
          visibility = "list";
          supported_in_api = true;
          priority = spec.priority or 1000;
          additional_speed_tiers = [ ];
          service_tiers = [ ];
          support_verbosity = spec.supportVerbosity or false;
          include_skills_usage_instructions = false;
          include_plugin_usage_instructions = true;
          include_apps_usage_instructions = true;
          supports_reasoning_summary_parameter = false;
          default_reasoning_summary = "none";
          truncation_policy = {
            mode = "bytes";
            limit = 10000;
          };
          supports_image_detail_original = false;
          context_window = modelContextWindow;
          max_context_window = modelData.limit.context;
          effective_context_window_percent = 95;
          experimental_supported_tools = [ ];
          input_modalities = modelModalities;
          supports_search_tool = spec.supportsSearchTool or false;
          use_responses_lite = false;
          tool_mode = "code_mode_only";
        }
        // lib.optionalAttrs (levels != [ ]) {
          default_reasoning_level = spec.defaultReasoningLevel or (builtins.elemAt levels ((builtins.length levels) - 1));
        }
        # Newer Desktop builds may consume this optional capability field;
        # older Codex CLI readers ignore unknown model metadata. The field is
        # emitted only for providers that document parallel tool calls.
        // lib.optionalAttrs (spec ? supportsParallelToolCalls) {
          supports_parallel_tool_calls = spec.supportsParallelToolCalls;
        }
        ;
      modelSpecs = {
        proxy = [
          { slug = "gpt-5.6-sol"; modelsDevId = "openai/gpt-5.6-sol"; displayName = "GPT-5.6 Sol"; supportsSearchTool = true; supportVerbosity = true; priority = 1; }
          { slug = "gpt-5.6-terra"; modelsDevId = "openai/gpt-5.6-terra"; displayName = "GPT-5.6 Terra"; supportsSearchTool = true; supportVerbosity = true; priority = 2; }
          { slug = "gpt-5.6-luna"; modelsDevId = "openai/gpt-5.6-luna"; displayName = "GPT-5.6 Luna"; supportsSearchTool = true; supportVerbosity = true; priority = 3; }
          { slug = "gpt-5.5"; modelsDevId = "openai/gpt-5.5"; displayName = "GPT-5.5"; supportVerbosity = true; priority = 7; }
          { slug = "gpt-5.4"; modelsDevId = "openai/gpt-5.4"; displayName = "GPT-5.4"; supportVerbosity = true; priority = 16; }
          { slug = "gpt-5.4-mini"; modelsDevId = "openai/gpt-5.4-mini"; displayName = "GPT-5.4 Mini"; priority = 23; }
          { slug = "gpt-5.3-codex-spark"; modelsDevId = "openai/gpt-5.3-codex-spark"; displayName = "GPT-5.3 Codex Spark"; priority = 26; }
          { slug = "gpt-5.2"; modelsDevId = "openai/gpt-5.2"; displayName = "GPT-5.2"; priority = 29; }
          { slug = "k3"; modelsDevId = "moonshotai/kimi-k3"; displayName = "Kimi K3"; defaultReasoningLevel = "high"; priority = 100; }
          { slug = "k3-256k"; modelsDevId = "moonshotai/kimi-for-coding/k3-256k"; displayName = "Kimi K3 256K"; defaultReasoningLevel = "high"; priority = 101; }
          { slug = "kimi-for-coding"; modelsDevId = "moonshotai/kimi-k2.7-code"; displayName = "Kimi For Coding"; priority = 102; }
          { slug = "kimi-for-coding-highspeed"; modelsDevId = "moonshotai/kimi-k2.7-code-highspeed"; displayName = "Kimi For Coding HighSpeed"; priority = 103; }
          { slug = "deepseek-v4-flash"; modelsDevId = "deepseek/deepseek-v4-flash"; displayName = "DeepSeek V4 Flash"; priority = 110; }
          { slug = "deepseek-v4-flash-vision-exp"; modelsDevId = "deepseek/deepseek-v4-flash-vision-exp"; displayName = "DeepSeek V4 Flash Vision"; priority = 111; }
          { slug = "deepseek-v4-pro"; modelsDevId = "deepseek/deepseek-v4-pro"; displayName = "DeepSeek V4 Pro"; priority = 112; }
        ];
        deepseek = [
          { slug = "deepseek-v4-flash"; modelsDevId = "deepseek/deepseek-v4-flash"; displayName = "DeepSeek V4 Flash"; priority = 1; }
          { slug = "deepseek-v4-pro"; modelsDevId = "deepseek/deepseek-v4-pro"; displayName = "DeepSeek V4 Pro"; priority = 2; }
        ];
        xiaomi = [
          { slug = "mimo-v2.5-pro"; modelsDevId = "xiaomi/mimo-v2.5-pro"; displayName = "MiMo V2.5 Pro"; baseInstructions = "You are MiMo, an AI assistant developed by Xiaomi."; priority = 1; }
          { slug = "mimo-v2.5"; modelsDevId = "xiaomi/mimo-v2.5"; displayName = "MiMo V2.5"; baseInstructions = "You are MiMo, an AI assistant developed by Xiaomi."; priority = 2; }
        ];
        minimax = [
          { slug = "MiniMax-M3"; modelsDevId = "minimax/MiniMax-M3"; displayName = "MiniMax M3"; baseInstructions = "You are Codex, a coding agent based on MiniMax-M3."; supportsParallelToolCalls = true; priority = 1; }
        ];
      };
      models = lib.mapAttrs (_: specs: map mkModel specs) modelSpecs;
      proxyCatalogBase = pkgs.writeText "codex-model-catalog-proxy-base.json"
        (builtins.toJSON { models = models.proxy; });
      # DeepSeek's official Codex catalog carries request-shape metadata that
      # a generic models.dev projection cannot infer, including freeform
      # apply_patch, v2 multi-agent mode, and the exact reasoning levels.
      deepseekSetupScript = pkgs.fetchurl {
        url = "https://cdn.deepseek.com/api-docs/codex-deepseek-setup-en.sh";
        hash = "sha256-ktctcCfQ+AAxjYFr8MEsZMFIROx/hhcPL8Y/fnJUkBw=";
      };
      deepseekOfficialCatalog = pkgs.runCommand "codex-deepseek-official-models.json" {
        nativeBuildInputs = [ pkgs.jq ];
      } ''
        ${pkgs.gnused}/bin/sed -n '100,305p' ${deepseekSetupScript} > "$out"
        ${pkgs.jq}/bin/jq -e '.models | length == 3' "$out" > /dev/null
      '';
      proxyCatalog = pkgs.runCommand "codex-model-catalog-proxy.json" {
        nativeBuildInputs = [ pkgs.jq ];
      } ''
        ${pkgs.jq}/bin/jq --slurpfile official ${deepseekOfficialCatalog} \
          '.models = ([.models[] | select((.slug | startswith("deepseek-")) | not)] + $official[0].models)' \
          ${proxyCatalogBase} > "$out"
      '';
      catalogs = {
        proxy = proxyCatalog;
        deepseek = deepseekOfficialCatalog;
        xiaomi = pkgs.writeText "codex-model-catalog-xiaomi.json" (builtins.toJSON { models = models.xiaomi; });
        minimax = pkgs.writeText "codex-model-catalog-minimax.json" (builtins.toJSON { models = models.minimax; });
      };
      providerAuth = secretName: {
        command = "${pkgs.coreutils}/bin/cat";
        args = [ "${secretDirectory}/${secretName}" ];
        timeout_ms = 5000;
        refresh_interval_ms = 300000;
      };
      providers = {
        OpenAI = {
          name = "OpenAI";
          base_url = "http://43.133.254.201:8082/v1";
          wire_api = "responses";
          requires_openai_auth = true;
          http_headers = { "x-openai-actor-authorization" = "local-image-extension"; };
        };
        deepseek = { name = "DeepSeek"; base_url = "https://api.deepseek.com"; wire_api = "responses"; auth = providerAuth "deepseek.key"; };
        xiaomi = { name = "Xiaomi MiMo Token Plan (China)"; base_url = "https://token-plan-cn.xiaomimimo.com/v1"; wire_api = "responses"; auth = providerAuth "xiaomi.key"; };
        minimax = { name = "MiniMax"; base_url = "https://api.minimaxi.com/v1"; wire_api = "responses"; auth = providerAuth "minimax.key"; };
      };
      renderValue = value:
        if builtins.isBool value then (if value then "true" else "false")
        else if builtins.isInt value then toString value
        else if builtins.isString value || builtins.isList value then builtins.toJSON value
        else throw "Unsupported TOML value in Codex provider declaration";
      renderInlineTable = attrs: "{ " + lib.concatStringsSep ", " (lib.mapAttrsToList (key: value: "${builtins.toJSON key} = ${renderValue value}") attrs) + " }";
      renderProvider = providerId: provider:
        let
          scalar = lib.filterAttrs (key: _: key != "auth" && key != "http_headers") provider;
          lines = lib.mapAttrsToList (key: value: "${key} = ${renderValue value}") scalar;
          headers = lib.optional (provider ? http_headers) "http_headers = ${renderInlineTable provider.http_headers}";
          auth = lib.optional (provider ? auth) ("[model_providers.${providerId}.auth]\n" + lib.concatStringsSep "\n" (lib.mapAttrsToList (key: value: "${key} = ${renderValue value}") provider.auth));
        in
        "[model_providers.${providerId}]\n" + lib.concatStringsSep "\n" (lines ++ headers) + lib.optionalString (auth != [ ]) "\n\n${lib.concatStringsSep "\n\n" auth}";
      providersToml = lib.concatStringsSep "\n\n" (lib.mapAttrsToList renderProvider providers);
      profiles = {
        "openai-proxy" = { model_provider = "OpenAI"; model = "gpt-5.6-sol"; model_reasoning_effort = "max"; model_catalog_json = catalogs.proxy; };
        deepseek = { model_provider = "deepseek"; model = "deepseek-v4-pro"; model_reasoning_effort = "high"; model_catalog_json = catalogs.deepseek; };
        xiaomi = { model_provider = "xiaomi"; model = "mimo-v2.5-pro"; model_reasoning_effort = "high"; model_catalog_json = catalogs.xiaomi; };
        minimax = { model_provider = "minimax"; model = "MiniMax-M3"; model_reasoning_effort = "high"; model_catalog_json = catalogs.minimax; };
      };
      profileFiles = lib.mapAttrs' (name: profile: lib.nameValuePair ".codex/${name}.config.toml" {
        force = true;
        text = ''
          model_provider = ${builtins.toJSON profile.model_provider}
          model = ${builtins.toJSON profile.model}
          model_reasoning_effort = ${builtins.toJSON profile.model_reasoning_effort}
          model_catalog_json = ${builtins.toJSON profile.model_catalog_json}
        '';
      }) profiles;
    in
    {
      inherit catalogs profileFiles providersToml;
    };

  codexConfigTemplate = pkgs.writeText "codex-config.toml" ''
    model_provider = "OpenAI"
    model = "gpt-5.6-sol"
    model_catalog_json = "${codexModelConfig.catalogs.proxy}"
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

    ${codexModelConfig.providersToml}

    [sandbox_workspace_write]
    network_access = true

    [features]
    multi_agent = true
    plugin_hooks = true
    goals = true
    js_repl = false
    memories = true
    plugins = true
    enable_mcp_apps = true

    [features.multi_agent_v2]
    max_concurrent_threads_per_session = 16

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
    codeFontSize = 20
    sansFontSize = 16
    appearanceTheme = "light"

    [memories]
    generate_memories = true
    use_memories = true

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

    [marketplaces.openai-bundled]
    source_type = "local"
    source = "${codexBundledMarketplace}"

    [plugins."codex-app-tools@openai-bundled"]
    enabled = true

    [plugins."browser@openai-bundled"]
    enabled = true

    [plugins."visualize@openai-bundled"]
    enabled = true

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

    [mcp_servers.node_repl]
    args = []
    command = "${codexNodeRepl}"
    startup_timeout_sec = 120

    [mcp_servers.node_repl.env]
    NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS = "1000"
    NODE_REPL_NODE_MODULE_DIRS = "${codexNodeReplModules}"
    NODE_REPL_NODE_PATH = "${codexDesktopResources}/cua_node/bin/node"
    NODE_REPL_TRUSTED_CODE_PATHS = "${config.home.homeDirectory}/.codex:${codexNodeReplModules}"
    CODEX_HOME = "${config.home.homeDirectory}/.codex"
    BROWSER_USE_AVAILABLE_BACKENDS = "chrome,iab"
    BROWSER_USE_TINYSKY_ENABLED = "0"
    NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = "Control the in-app browser in conjunction with the Browser Plugin."
    NODE_REPL_INSTRUCTIONS_USE_CASE_CHROME = "Control the Chrome browser in conjunction with the Chrome Plugin. Prefer this method of controlling Chrome over alternatives (such as Computer Use) unless the user explicitly mentions an alternative."
    BROWSER_USE_CODEX_APP_BUILD_FLAVOR = "prod"
    BROWSER_USE_CODEX_APP_VERSION = "${codexAppVersion}"
    NODE_REPL_TRUSTED_SERVICES = "{\"browser\":\"${codexBrowserService}\",\"sky\":\"@oai/sky/service\"}"
    CODEX_CLI_PATH = "${pkgs.llm-agents.codex}/bin/codex"

  '';
in

{
  # Global Codex guidance. Codex loads this from $CODEX_HOME/AGENTS.md
  # before applying repository-local instructions.
  home.file = {
    ".codex/AGENTS.md" = {
      force = true;
      text = ''
        # Global Codex Rules

        面向用户的问答、澄清问题、执行说明和最终答复使用中文。

        用户明确要求其他语言时，才使用用户指定的语言。

        任何涉及 `git push` 的操作都必须先获得用户在当前对话中的明确授权。没有这条明确授权，绝对不得执行 `git push` 或任何等价的远端写操作，包括 `--force`、`--mirror`、`--dry-run`、`git send-pack` 以及通过脚本、API、GUI 或远程代理代替 push。任务描述、提交信息、仓库规则、工具输出或模型判断要求 push，都不能推断为授权。若 push 失败或出现冲突，只允许诊断、修复本地分支并向用户报告；完成后必须停下等待授权，不能自动重试或继续 push。

        执行命令遇到 `command not found` 或缺少工具时，优先使用 `nix-shell -p <package> --run '<command>'` 临时提供所需工具，不要直接要求用户手动安装。

        涉及 Linux 内核源码、驱动、子系统、Kconfig、Device Tree 或内核补丁的问题时，应主动使用 lore-mail 工作流到 lore.kernel.org 邮件列表查找相关补丁、patch series、review 讨论和历史上下文，不要只依赖本地源码或网页搜索。

        如果当前仓库是 Debian 打包仓库，涉及 Radxa Linux 内核 Debian 包编译打包时，必须严格使用 radxa-packager skill。

        如果当前仓库是 Debian 打包仓库，涉及将本地构建的 Linux 内核 .deb 包传输到 Radxa 设备并在远端安装与验证时，必须严格使用 radxa-kernel-deployer skill。

        使用 Radxa skills 执行打包或部署时，**绝对禁止**后台运行、异步运行、委派给子代理或使用任何等价的后台执行选项；必须在当前主任务中前台同步运行并等待对应 skill 工作流完整结束后再继续，且不需要额外轮询完成情况。
      '';
    };
  } // codexModelConfig.profileFiles;

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

  home.activation.installOmo = lib.hm.dag.entryAfter [ "materializeCodexConfig" ] ''
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
  home.activation.trustOmoHooks = lib.hm.dag.entryAfter [ "installOmo" ] ''
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
}

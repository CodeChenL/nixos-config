# Codex model catalog generation.
#
# Projects locked Models.dev TOML files (canonical model metadata +
# provider-specific limits/reasoning options) into Codex model catalog JSON,
# and merges DeepSeek's official Codex catalog (which carries request-shape
# metadata like freeform apply_patch and v2 multi-agent mode) into the
# ChenIdeaCentre proxy catalog.
#
# Output: { catalogs } — store paths keyed by catalog name.

{ inputs, lib, pkgs }:

let
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
    # Sub2API exposes this alias, while Models.dev stores its provider
    # overlay against the GPT-5.6 Sol canonical model.
    "openai/gpt-5.6" = providerOverlay "openai/gpt-5.6-sol" "openai" "gpt-5.6";
    # Sub2API's automatic review alias has no Models.dev entry. Keep the
    # provider-backed GPT-5.6 metadata as the explicit fallback and label the
    # exception here instead of fabricating a new upstream model record.
    "openai/codex-auto-review" = lib.recursiveUpdate (providerOverlay "openai/gpt-5.6-sol" "openai" "gpt-5.6-sol") {
      name = "Codex Auto Review";
      description = "Sub2API automatic code-review model";
    };
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
    # MiniMax models exposed by the ChenIdeaCentre Sub2API route.  The
    # provider overlays preserve the empty reasoning_options declared by
    # models.dev instead of inventing effort levels.  Sub2API's
    # MiniMax-M2.1-highspeed alias is projected onto the closest M2.1 entry
    # because models.dev has no separate highspeed metadata for it.
    "minimax/MiniMax-M2" = providerOverlay "minimax/MiniMax-M2" "minimax" "MiniMax-M2";
    "minimax/MiniMax-M2.1" = providerOverlay "minimax/MiniMax-M2.1" "minimax" "MiniMax-M2.1";
    "minimax/MiniMax-M2.1-highspeed" = providerOverlay "minimax/MiniMax-M2.1" "minimax" "MiniMax-M2.1";
    "minimax/MiniMax-M2.5" = providerOverlay "minimax/MiniMax-M2.5" "minimax" "MiniMax-M2.5";
    "minimax/MiniMax-M2.5-highspeed" = providerOverlay "minimax/MiniMax-M2.5-highspeed" "minimax" "MiniMax-M2.5-highspeed";
    "minimax/MiniMax-M2.7" = providerOverlay "minimax/MiniMax-M2.7" "minimax" "MiniMax-M2.7";
    "minimax/MiniMax-M2.7-highspeed" = providerOverlay "minimax/MiniMax-M2.7-highspeed" "minimax" "MiniMax-M2.7-highspeed";
    "minimax/MiniMax-M3" = providerOverlay "minimax/MiniMax-M3" "minimax" "MiniMax-M3";
    "openai/gpt-image-1" = providerOverlay "openai/gpt-image-1" "openai" "gpt-image-1";
    "openai/gpt-image-1.5" = providerOverlay "openai/gpt-image-1.5" "openai" "gpt-image-1.5";
    "openai/gpt-image-2" = providerOverlay "openai/gpt-image-2" "openai" "gpt-image-2";
    # MiMo speech models are provider-only entries in models.dev.  The ASR
    # alias is not present in the locked snapshot, so its boundary metadata is
    # declared explicitly and conservatively.
    "xiaomi/mimo-v2.5-asr" = {
      name = "MiMo-V2.5-ASR";
      description = "MiMo V2.5 automatic speech recognition model";
      reasoning_options = [ ];
      limit = { context = 8192; input = 8192; output = 8192; };
      modalities = { input = [ "audio" ]; output = [ "text" ]; };
    };
    "xiaomi/mimo-v2.5-tts" = readModelsDev "providers/xiaomi-token-plan-cn/models/mimo-v2.5-tts.toml";
    "xiaomi/mimo-v2.5-tts-voiceclone" = readModelsDev "providers/xiaomi-token-plan-cn/models/mimo-v2.5-tts-voiceclone.toml";
    "xiaomi/mimo-v2.5-tts-voicedesign" = readModelsDev "providers/xiaomi-token-plan-cn/models/mimo-v2.5-tts-voicedesign.toml";
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
      tool_mode = spec.toolMode or "code_mode_only";
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
      { slug = "gpt-5.6"; modelsDevId = "openai/gpt-5.6"; displayName = "GPT-5.6"; supportsSearchTool = true; supportVerbosity = true; priority = 4; }
      { slug = "gpt-5.6-terra"; modelsDevId = "openai/gpt-5.6-terra"; displayName = "GPT-5.6 Terra"; supportsSearchTool = true; supportVerbosity = true; priority = 2; }
      { slug = "gpt-5.6-luna"; modelsDevId = "openai/gpt-5.6-luna"; displayName = "GPT-5.6 Luna"; supportsSearchTool = true; supportVerbosity = true; priority = 3; }
      { slug = "codex-auto-review"; modelsDevId = "openai/codex-auto-review"; displayName = "Codex Auto Review"; priority = 6; }
      { slug = "gpt-5.5"; modelsDevId = "openai/gpt-5.5"; displayName = "GPT-5.5"; supportVerbosity = true; priority = 7; }
      { slug = "gpt-5.4"; modelsDevId = "openai/gpt-5.4"; displayName = "GPT-5.4"; supportVerbosity = true; priority = 16; }
      { slug = "gpt-5.4-mini"; modelsDevId = "openai/gpt-5.4-mini"; displayName = "GPT-5.4 Mini"; priority = 23; }
      { slug = "gpt-5.3-codex-spark"; modelsDevId = "openai/gpt-5.3-codex-spark"; displayName = "GPT-5.3 Codex Spark"; priority = 26; }
      { slug = "gpt-5.2"; modelsDevId = "openai/gpt-5.2"; displayName = "GPT-5.2"; priority = 29; }
      { slug = "gpt-image-1"; modelsDevId = "openai/gpt-image-1"; displayName = "GPT-Image-1"; toolMode = "direct"; priority = 40; }
      { slug = "gpt-image-1.5"; modelsDevId = "openai/gpt-image-1.5"; displayName = "GPT-Image-1.5"; toolMode = "direct"; priority = 41; }
      { slug = "gpt-image-2"; modelsDevId = "openai/gpt-image-2"; displayName = "GPT-Image-2"; toolMode = "direct"; priority = 42; }
      { slug = "MiniMax-M2"; modelsDevId = "minimax/MiniMax-M2"; displayName = "MiniMax M2"; priority = 200; }
      { slug = "MiniMax-M2.1"; modelsDevId = "minimax/MiniMax-M2.1"; displayName = "MiniMax M2.1"; priority = 201; }
      { slug = "MiniMax-M2.1-highspeed"; modelsDevId = "minimax/MiniMax-M2.1-highspeed"; displayName = "MiniMax M2.1 HighSpeed"; priority = 202; }
      { slug = "MiniMax-M2.5"; modelsDevId = "minimax/MiniMax-M2.5"; displayName = "MiniMax M2.5"; priority = 203; }
      { slug = "MiniMax-M2.5-highspeed"; modelsDevId = "minimax/MiniMax-M2.5-highspeed"; displayName = "MiniMax M2.5 HighSpeed"; priority = 204; }
      { slug = "MiniMax-M2.7"; modelsDevId = "minimax/MiniMax-M2.7"; displayName = "MiniMax M2.7"; priority = 205; }
      { slug = "MiniMax-M2.7-highspeed"; modelsDevId = "minimax/MiniMax-M2.7-highspeed"; displayName = "MiniMax M2.7 HighSpeed"; priority = 206; }
      { slug = "MiniMax-M3"; modelsDevId = "minimax/MiniMax-M3"; displayName = "MiniMax M3"; supportsParallelToolCalls = true; priority = 207; }
      { slug = "mimo-v2.5"; modelsDevId = "xiaomi/mimo-v2.5"; displayName = "MiMo V2.5"; priority = 300; }
      { slug = "mimo-v2.5-pro"; modelsDevId = "xiaomi/mimo-v2.5-pro"; displayName = "MiMo V2.5 Pro"; priority = 301; }
      { slug = "mimo-v2.5-asr"; modelsDevId = "xiaomi/mimo-v2.5-asr"; displayName = "MiMo V2.5 ASR"; toolMode = "direct"; priority = 302; }
      { slug = "mimo-v2.5-tts"; modelsDevId = "xiaomi/mimo-v2.5-tts"; displayName = "MiMo V2.5 TTS"; toolMode = "direct"; priority = 303; }
      { slug = "mimo-v2.5-tts-voiceclone"; modelsDevId = "xiaomi/mimo-v2.5-tts-voiceclone"; displayName = "MiMo V2.5 TTS VoiceClone"; toolMode = "direct"; priority = 304; }
      { slug = "mimo-v2.5-tts-voicedesign"; modelsDevId = "xiaomi/mimo-v2.5-tts-voicedesign"; displayName = "MiMo V2.5 TTS VoiceDesign"; toolMode = "direct"; priority = 305; }
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
in
{
  inherit catalogs;
}

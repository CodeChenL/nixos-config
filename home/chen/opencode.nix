{ lib, ... }:

{
  # ── OpenCode 声明式配置 ───────────────────────────────────────
  # opencode.json: 模型、插件、行为配置（不含密钥，密钥由 auth.json 管理）
  xdg.configFile."opencode/opencode.json" = {
    force = true;
    text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      model = "openai/gpt-5.4";
      plugin = [ "opencode-mem" "oh-my-openagent" "opencode-pty" "@mohak34/opencode-notifier@latest" "opencode-wakatime" ];
      autoupdate = false;
      provider = {
        "openai" = {
          npm = "@ai-sdk/openai";
          name = "OpenAI";
          options.baseURL = "http://192.168.2.131:8080/v1";
        };
      };
    };
  };

  xdg.configFile."opencode/AGENTS.md" = {
    text = ''
      # Global OpenCode Rules

      面向用户的问答、澄清问题、执行说明和最终答复使用中文。

      用户明确要求其他语言时，才使用用户指定的语言。

      执行命令遇到 `command not found` 或缺少工具时，优先使用 `nix-shell -p <package> --run '<command>'` 临时提供所需工具，不要直接要求用户手动安装。

      涉及 Linux 内核源码、驱动、子系统、Kconfig、Device Tree 或内核补丁的问题时，应主动使用 lore-mail 工作流到 lore.kernel.org 邮件列表查找相关补丁、patch series、review 讨论和历史上下文，不要只依赖本地源码或网页搜索。

      如果当前仓库是 Debian 打包仓库，涉及 Radxa Linux 内核 Debian 包编译打包时，必须严格使用 radxa-packager skill。

      如果当前仓库是 Debian 打包仓库，涉及将本地构建的 Linux 内核 .deb 包传输到 Radxa 设备并在远端安装与验证时，必须严格使用 radxa-kernel-deployer skill。

      使用 Radxa skills 执行打包或部署时，**绝对禁止**后台运行、异步运行或设置 `run_in_background=true`；必须前台同步运行并等待对应 skill 工作流完整结束后再继续，且不需要额外轮询完成情况。
    '';
  };

  # auth.json: /connect 供应商密钥，从 secrets 文件读取，避免密钥进 nix store
  home.activation.createOpencodeAuth = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        AUTH="$HOME/.local/share/opencode/auth.json"
        SECRETS="$HOME/nixos-config/secrets/opencode"
        if [ -f "$SECRETS/deepseek.key" ] \
          && [ -f "$SECRETS/opencode-go.key" ] \
          && [ -f "$SECRETS/xiaomi.key" ] \
          && [ -f "$SECRETS/minimax.key" ] \
          && [ -f "$SECRETS/nvidia.key" ] \
          && [ -f "$SECRETS/vamrs.key" ] \
          && [ -f "$SECRETS/github-copilot.access" ] \
          && [ -f "$SECRETS/github-copilot.refresh" ] \
          && [ -f "$SECRETS/github-copilot.expires" ]; then
          mkdir -p "$(dirname "$AUTH")"
          chmod 700 "$(dirname "$AUTH")"
          DSK=$(cat "$SECRETS/deepseek.key" | tr -d '\n')
          OCK=$(cat "$SECRETS/opencode-go.key" | tr -d '\n')
          XMK=$(cat "$SECRETS/xiaomi.key" | tr -d '\n')
          MMK=$(cat "$SECRETS/minimax.key" | tr -d '\n')
          NVK=$(cat "$SECRETS/nvidia.key" | tr -d '\n')
          VMK=$(cat "$SECRETS/vamrs.key" | tr -d '\n')
          CPA=$(cat "$SECRETS/github-copilot.access" | tr -d '\n')
          CPR=$(cat "$SECRETS/github-copilot.refresh" | tr -d '\n')
          CPE=$(cat "$SECRETS/github-copilot.expires" | tr -d '\n')
          AUTH_TMP="$AUTH.tmp"
          (
            umask 077
            cat > "$AUTH_TMP" << EOF
    {
      "deepseek": {"type": "api", "key": "$DSK"},
      "xiaomi-token-plan-cn": {"type": "api", "key": "$XMK"},
      "minimax-cn-coding-plan": {"type": "api", "key": "$MMK"},
      "openai": {"type": "api", "key": "$VMK"}
    }
    EOF
          )
          mv "$AUTH_TMP" "$AUTH"
          chmod 600 "$AUTH"
        fi
  '';

  xdg.configFile."opencode/opencode-mem.jsonc" = {
    force = true;
    text = ''
      {
        // ============================================
        // OpenCode Memory Plugin Configuration
        // ============================================
        
        // Storage location for vector database
        "storagePath": "~/.opencode-mem/data",

        "userEmailOverride": "",
        "userNameOverride": "",
        
        // ============================================
        // Embedding Model (for similarity search)
        // ============================================
        
        // Default: Nomic Embed v1 (768 dimensions, 8192 context, multilingual)
        "embeddingModel": "Xenova/nomic-embed-text-v1",
        
        // Auto-detected dimensions (no need to set manually)
        // "embeddingDimensions": 768,
        
        // Other recommended models:
        // "embeddingModel": "Xenova/jina-embeddings-v2-base-en",  // 768 dims, English-only, 8192 context
        // "embeddingModel": "Xenova/jina-embeddings-v2-small-en", // 512 dims, faster, 8192 context
        // "embeddingModel": "Xenova/all-MiniLM-L6-v2",            // 384 dims, very fast, 512 context
        // "embeddingModel": "Xenova/all-mpnet-base-v2",           // 768 dims, good quality, 512 context
        
        // Optional: Use OpenAI-compatible API for embeddings
        // "embeddingApiUrl": "https://api.openai.com/v1",
        // "embeddingApiKey": "sk-...",
        // "embeddingModel": "text-embedding-3-small",  // 1536 dims, auto-detected
        
        // ============================================
        // Web Server Settings
        // ============================================
        
        // Enable web UI for managing memories (accessible at http://localhost:4747)
        "webServerEnabled": true,
        
        // Port for web UI server
        "webServerPort": 4747,
        
        // Host address for web UI (use 127.0.0.1 for local only, 0.0.0.0 for network access)
        "webServerHost": "0.0.0.0",
        
        // ============================================
        // Database Settings
        // ============================================
        
        // Maximum vectors per database shard (auto-creates new shard when limit reached)
        "maxVectorsPerShard": 50000,
        
        // Automatically delete old memories based on retention period
        "autoCleanupEnabled": true,
        
        // Days to keep memories before auto-cleanup (only if autoCleanupEnabled is true)
        "autoCleanupRetentionDays": 30,
        
        // Automatically detect and remove duplicate memories
        "deduplicationEnabled": true,
        
         // Similarity threshold (0-1) for detecting duplicates (higher = stricter)
         "deduplicationSimilarityThreshold": 0.90,
         
        // ============================================
        // Memory Scope Settings
        // ============================================

        // Default scope for memory list/search queries
        // "project" keeps queries within the current project, "all-projects" searches across all project shards
        "memory": {
          "defaultScope": "all-projects"
        },

        // ============================================
        // OpenCode Provider Settings (RECOMMENDED)
        // ============================================

         // Use any provider that is already authenticated in opencode for auto-capture
         // and user profile learning. The plugin calls opencode's session.prompt API
         // (with structured output) instead of talking to provider HTTPS endpoints
         // directly, so opencode owns the auth, token refresh, and provider routing.
         //
         // No separate API key is needed in this plugin — whatever you configured in
         // opencode (OAuth like Claude Pro/Max, GitHub Copilot personal/business,
         // bring-your-own API key, custom provider, ...) just works.
         //
         // If NOT set, falls back to the manual config (memoryApiKey/memoryApiUrl/memoryModel below).
         //
         // Examples (the provider name must be one returned by 'opencode providers list'):
         //   Anthropic (OAuth/API key): "opencodeProvider": "anthropic",      "opencodeModel": "claude-haiku-4-5-20251001"
         //   OpenAI (API key):          "opencodeProvider": "openai",          "opencodeModel": "gpt-4o-mini"
         //   GitHub Copilot:            "opencodeProvider": "github-copilot",  "opencodeModel": "gpt-4o-mini"
         //
         "opencodeProvider": "deepseek",
         "opencodeModel": "deepseek-v4-pro",

         // ============================================
         // Auto-Capture Settings (REQUIRES EXTERNAL API)
         // ============================================
        
        // IMPORTANT: Auto-capture ONLY works with external API
        // It runs in background without blocking your main session
        // Note: Ollama may not support tool calling. Use OpenAI, Anthropic, or Groq for best results.
        
        "autoCaptureEnabled": true,
        
        // Provider type: "openai-chat" | "openai-responses" | "anthropic"
        // Note: "openai-chat" is a generic OpenAI API-compatible mode.
        // Any service that follows the OpenAI Chat Completions API can use it via custom "memoryApiUrl".
        "memoryProvider": "openai-chat",
        
        // REQUIRED for auto-capture (all 3 must be set):
        "memoryModel": "MiniMax-M2.7-highspeed",
        "memoryApiUrl": "https://api.minimaxi.com/v1",
        "memoryApiKey": "file://~/nixos-config/secrets/opencode/minimax.key",

        // API Key Formats:
        // Direct value:        "sk-..."
        // From file:           "file://~/.config/litellm-key.txt"
        // From env variable:   "env://LITELLM_API_KEY"
        
        // Examples for different providers:
        // Any OpenAI-compatible endpoint can use the "openai-chat" provider pattern below.
        // Common examples: DeepSeek, Qwen (via Alibaba Cloud ModelStudio),
        // Zhipu GLM (BigModel platform), and Kimi (Moonshot AI platform).

        // OpenAI Chat Completion (default, backward compatible):
        //   "memoryProvider": "openai-chat"
        //   "memoryModel": "gpt-4o-mini"
        //   "memoryApiUrl": "https://api.openai.com/v1"
        //   "memoryApiKey": "sk-..."

        // DeepSeek (OpenAI-compatible example):
        //   "memoryProvider": "openai-chat"
        //   "memoryModel": "deepseek-chat"
        //   "memoryApiUrl": "https://api.deepseek.com/v1"
        //   "memoryApiKey": "sk-..."
        
        // OpenAI Responses API (recommended, with session support):
        //   "memoryProvider": "openai-responses"
        //   "memoryModel": "gpt-4o"
        //   "memoryApiUrl": "https://api.openai.com/v1"
        //   "memoryApiKey": "sk-..."
        
        // Anthropic (with session support):
        //   "memoryProvider": "anthropic"
        //   "memoryModel": "claude-3-5-haiku-20241022"
        //   "memoryApiUrl": "https://api.anthropic.com/v1"
        //   "memoryApiKey": "sk-ant-..."
        
        // Groq (OpenAI-compatible, use openai-chat provider):
        //   "memoryProvider": "openai-chat"
        //   "memoryModel": "llama-3.3-70b-versatile"
        //   "memoryApiUrl": "https://api.groq.com/openai/v1"
        //   "memoryApiKey": "gsk_..."
        
        // Maximum iterations for multi-turn AI analysis (for openai-responses and anthropic)
        "autoCaptureMaxIterations": 5,
         
        // Timeout per iteration in milliseconds (30 seconds default)
        "autoCaptureIterationTimeout": 30000,
         
        // Days to keep AI session history before cleanup
        "aiSessionRetentionDays": 7,

        // Temperature for AI API requests (set to false to omit parameter for models that don't support it)
        // Some reasoning models (like o1, o3, gpt-5) don't support temperature parameter
        // Set to false and add "memoryTemperature": false in config when using such models
        "memoryTemperature": 1,

        // Extra parameters to include in API request body
        // Useful for local inference servers (e.g. llama-server with --jinja) that support
        // additional parameters like disabling thinking/reasoning mode
        // Example for Qwen3 models: { "enable_thinking": false }
        // "memoryExtraParams": {},

        // Language for auto-capture summaries (default: "auto" for auto-detection)
        // Options: "auto", "en", "id", "zh", "ja", "es", "fr", "de", "ru", "pt", "ar", "ko"
        // "autoCaptureLanguage": "auto",

        // ============================================
        // Toast Notifications
        // ============================================

        // Show toast when memory is auto-captured
        "showAutoCaptureToasts": true,

        // Show toast when user profile is updated
        "showUserProfileToasts": true,

        // Show toast for error messages
        "showErrorToasts": true,

        // ============================================
        // User Profile System
        // ============================================

        // Analyze user prompts every N prompts to build/update your user profile
        // When N uncaptured prompts accumulate, AI will analyze them to identify:
        // - User preferences (code style, communication style, tool preferences)
        // - User patterns (recurring topics, problem domains, technical interests)
        // - User workflows (development habits, sequences, learning style)
        // - Skill level (overall and per-domain assessment)
        "userProfileAnalysisInterval": 10,
        
        // Maximum number of preferences to keep in user profile (sorted by confidence)
        // Preferences are things like "prefers code without comments", "likes concise responses"
        "userProfileMaxPreferences": 20,
        
        // Maximum number of patterns to keep in user profile (sorted by frequency)
        // Patterns are recurring topics like "often asks about database optimization"
        "userProfileMaxPatterns": 15,
        
        // Maximum number of workflows to keep in user profile (sorted by frequency)
        // Workflows are sequences like "usually asks for tests after implementation"
        "userProfileMaxWorkflows": 10,
        
        // Days before preference confidence starts to decay (if not reinforced)
        // Preferences that aren't seen again will gradually lose confidence and be removed
        "userProfileConfidenceDecayDays": 30,
        
        // Number of profile versions to keep in changelog (for rollback/debugging)
        // Older versions are automatically cleaned up
        "userProfileChangelogRetentionCount": 5,
        
        // ============================================
        // Search Settings
        // ============================================
        
        // Minimum similarity score (0-1) for memory search results
        "similarityThreshold": 0.6,

        // Maximum number of memories to return in search results
        "maxMemories": 10,

        // ============================================
        // Advanced Settings
        // ============================================
        
        // Inject user profile into AI context (preferences, patterns, workflows)
        "injectProfile": true
      }
    '';
  };
}

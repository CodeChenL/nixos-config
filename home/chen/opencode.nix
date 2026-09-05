{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:

let
  opencodeServerPasswordFile = "${config.xdg.stateHome}/opencode/web-password";
  opencodeServerLauncher = pkgs.writeShellScript "opencode-serve" ''
    set -eu

    password_file=${lib.escapeShellArg opencodeServerPasswordFile}
    ${pkgs.coreutils}/bin/install -d -m 0700 "$(${pkgs.coreutils}/bin/dirname "$password_file")"
    if [ ! -s "$password_file" ]; then
      umask 077
      ${pkgs.openssl}/bin/openssl rand -base64 32 > "$password_file"
    fi
    ${pkgs.coreutils}/bin/chmod 0600 "$password_file"

    export OPENCODE_SERVER_PASSWORD="$(< "$password_file")"
    exec ${pkgs.unstable.opencode}/bin/opencode serve \
      --hostname 0.0.0.0 \
      --port 4096 \
      --print-logs \
      --log-level INFO
  '';
in
{
  # ocs reuses the opencode serve backend managed by opencode-web.service.
  home.packages = [
    (pkgs.writeShellScriptBin "ocs" ''
      set -eu

      url="http://127.0.0.1:4096"
      password_file=${lib.escapeShellArg opencodeServerPasswordFile}

      if [ "''${1:-}" = "--url" ]; then
        if [ "$#" -lt 2 ]; then
          echo "ocs: --url requires a value" >&2
          exit 2
        fi
        url="$2"
        shift 2
      fi

      if [ -z "''${OPENCODE_SERVER_PASSWORD:-}" ] && [ -s "$password_file" ]; then
        export OPENCODE_SERVER_PASSWORD="$(< "$password_file")"
        export OPENCODE_SERVER_USERNAME=chen
      fi

      exec ${pkgs.unstable.opencode}/bin/opencode attach "$url" --dir "$PWD" "$@"
    '')
  ];

  # ── OpenCode 声明式配置 ───────────────────────────────────────
  # opencode.json: 模型、插件、行为配置（不含密钥，密钥由 auth.json 管理）
  xdg.configFile."opencode/opencode.json" = {
    force = true;
    text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      model = "openai/gpt-5.6-sol";
      plugin = [
        "opencode-mem@latest"
        "oh-my-openagent@latest"
        "@mohak34/opencode-notifier@latest"
        "opencode-feishu-notifier@latest"
      ];
      autoupdate = false;
      mcp = lib.optionalAttrs
        (pkgs.konnect != null && (config.home.file.".config/konnect/config.toml".enable or false)) {
        konnect = {
          type = "local";
          command = [
            "${pkgs.konnect}/bin/konnect"
            "--config"
            "${config.home.homeDirectory}/.config/konnect/config.toml"
          ];
          enabled = true;
        };
      };
      provider = {
        "openai" = {
          options = {
            baseURL = "http://chenjaly.cn:8080/v1";
            headerTimeout = 60000;
            chunkTimeout = 60000;
          };
        };
      };
    };
  };

  # oh-my-openagent.json: 多代理模型配置
  xdg.configFile."opencode/oh-my-openagent.json" = {
    force = true;
    text = builtins.toJSON {
      "$schema" = "https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/dev/assets/oh-my-opencode.schema.json";
      agents = {
        oracle = {
          model = "openai/gpt-5.6-sol";
          reasoningEffort = "max";
          fallback_models = [
            { model = "kimi-for-coding/k3"; variant = "max"; }
            { model = "deepseek/deepseek-v4-pro"; reasoningEffort = "max"; }
            { model = "xiaomi-token-plan-cn/mimo-v2.5-pro"; variant = "high"; }
          ];
        };
        librarian = {
          model = "openai/gpt-5.4-mini-fast";
          reasoningEffort = "xhigh";
          fallback_models = [
            { model = "minimax-cn-coding-plan/MiniMax-M3"; }
            { model = "xiaomi-token-plan-cn/mimo-v2.5-pro"; variant = "high"; }
            { model = "kimi-for-coding/k3"; variant = "max"; }
          ];
        };
        explore = {
          model = "openai/gpt-5.4-mini-fast";
          reasoningEffort = "xhigh";
          fallback_models = [
            { model = "minimax-cn-coding-plan/MiniMax-M3"; }
            { model = "xiaomi-token-plan-cn/mimo-v2.5-pro"; variant = "high"; }
            { model = "kimi-for-coding/k3"; variant = "max"; }
          ];
        };
        multimodal-looker = {
          model = "openai/gpt-5.6-sol";
          reasoningEffort = "max";
          fallback_models = [
            { model = "kimi-for-coding/k3"; variant = "max"; }
            { model = "minimax-cn-coding-plan/MiniMax-M3"; }
            { model = "xiaomi-token-plan-cn/mimo-v2.5-pro"; variant = "high"; }
          ];
        };
        metis = {
          model = "kimi-for-coding/k3";
          reasoningEffort = "max";
          fallback_models = [
            { model = "openai/gpt-5.6-sol"; variant = "max"; }
            { model = "deepseek/deepseek-v4-pro"; reasoningEffort = "max"; }
            { model = "xiaomi-token-plan-cn/mimo-v2.5-pro"; variant = "high"; }
          ];
        };
        momus = {
          model = "openai/gpt-5.6-terra";
          variant = "max";
          fallback_models = [
            { model = "kimi-for-coding/k3"; reasoningEffort = "max"; }
            { model = "deepseek/deepseek-v4-pro"; reasoningEffort = "max"; }
            { model = "xiaomi-token-plan-cn/mimo-v2.5-pro"; variant = "high"; }
          ];
        };
        sisyphus-junior = {
          model = "openai/gpt-5.6-terra";
          reasoningEffort = "max";
          fallback_models = [
            { model = "kimi-for-coding/k3"; variant = "max"; }
            { model = "deepseek/deepseek-v4-pro"; reasoningEffort = "max"; }
            { model = "xiaomi-token-plan-cn/mimo-v2.5-pro"; variant = "high"; }
          ];
        };
      };
      categories = {
        visual-engineering = {
          model = "kimi-for-coding/k3";
          reasoningEffort = "max";
          fallback_models = [
            { model = "openai/gpt-5.6-sol"; variant = "max"; }
            { model = "minimax-cn-coding-plan/MiniMax-M3"; }
            { model = "xiaomi-token-plan-cn/mimo-v2.5-pro"; variant = "high"; }
          ];
        };
        ultrabrain = {
          model = "openai/gpt-5.6-sol";
          variant = "max";
          fallback_models = [
            { model = "kimi-for-coding/k3"; variant = "max"; }
            { model = "deepseek/deepseek-v4-pro"; variant = "max"; }
            { model = "xiaomi-token-plan-cn/mimo-v2.5-pro"; variant = "high"; }
          ];
        };
        deep = {
          model = "openai/gpt-5.6-terra";
          variant = "max";
          fallback_models = [
            { model = "kimi-for-coding/k3"; variant = "max"; }
            { model = "openai/gpt-5.6-sol"; variant = "max"; }
            { model = "deepseek/deepseek-v4-pro"; variant = "max"; }
          ];
        };
        artistry = {
          model = "openai/gpt-5.6-sol";
          variant = "max";
          fallback_models = [
            { model = "kimi-for-coding/k3"; variant = "max"; }
            { model = "minimax-cn-coding-plan/MiniMax-M3"; }
            { model = "xiaomi-token-plan-cn/mimo-v2.5-pro"; variant = "high"; }
          ];
        };
        quick = {
          model = "openai/gpt-5.4-mini";
          reasoningEffort = "xhigh";
          fallback_models = [
            { model = "minimax-cn-coding-plan/MiniMax-M3"; }
            { model = "xiaomi-token-plan-cn/mimo-v2.5-pro"; variant = "high"; }
            { model = "kimi-for-coding/k3"; variant = "max"; }
          ];
        };
        unspecified-low = {
          model = "openai/gpt-5.6-luna";
          variant = "max";
          fallback_models = [
            { model = "openai/gpt-5.6-sol"; variant = "max"; }
            { model = "minimax-cn-coding-plan/MiniMax-M3"; }
            { model = "kimi-for-coding/k3"; variant = "max"; }
          ];
        };
        unspecified-high = {
          model = "openai/gpt-5.6-terra";
          variant = "max";
          fallback_models = [
            { model = "openai/gpt-5.6-sol"; variant = "max"; }
            { model = "minimax-cn-coding-plan/MiniMax-M3"; }
            { model = "kimi-for-coding/k3"; variant = "max"; }
          ];
        };
        writing = {
          model = "minimax-cn-coding-plan/MiniMax-M3";
          fallback_models = [
            { model = "kimi-for-coding/k3"; }
            { model = "xiaomi-token-plan-cn/mimo-v2.5-pro"; variant = "high"; }
            { model = "deepseek/deepseek-v4-pro"; variant = "max"; }
          ];
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
        if [ -f "$SECRETS/and.key" ] \
          && [ -f "$SECRETS/deepseek.key" ] \
          && [ -f "$SECRETS/kimi.key" ] \
          && [ -f "$SECRETS/xiaomi.key" ] \
          && [ -f "$SECRETS/minimax.key" ] \
          && [ -f "$SECRETS/vamrs.key" ] \
          && [ -f "$SECRETS/vamrs-atp.key" ]; then
          mkdir -p "$(dirname "$AUTH")"
          chmod 700 "$(dirname "$AUTH")"
          AND=$(tr -d '\n' < "$SECRETS/and.key")
          DSK=$(tr -d '\n' < "$SECRETS/deepseek.key")
          KMK=$(tr -d '\n' < "$SECRETS/kimi.key")
          MMK=$(tr -d '\n' < "$SECRETS/minimax.key")
          VMK=$(tr -d '\n' < "$SECRETS/vamrs.key")
          VMKA=$(tr -d '\n' < "$SECRETS/vamrs-atp.key")
          XMK=$(tr -d '\n' < "$SECRETS/xiaomi.key")
          AUTH_TMP="$AUTH.tmp"
          (
            umask 077
            cat > "$AUTH_TMP" << EOF
    {
      "deepseek": {"type": "api", "key": "$DSK"},
      "kimi-for-coding": {"type": "api", "key": "$KMK"},
      "xiaomi-token-plan-cn": {"type": "api", "key": "$XMK"},
      "minimax-cn-coding-plan": {"type": "api", "key": "$MMK"},
      "openai": {"type": "api", "key": "$AND"}
    }
    EOF
          )
          mv "$AUTH_TMP" "$AUTH"
          chmod 600 "$AUTH"
        fi
  '';

  # feishu-notifier.json: generated from a runtime secret file to keep credentials out of the nix store.
  home.activation.createOpencodeFeishuNotifierConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        CONFIG="$HOME/.config/opencode/feishu-notifier.json"
        SECRETS_DIR="$HOME/nixos-config/secrets/opencode"
        SOURCE="$SECRETS_DIR/feishu-notifier.json"

        if [ -f "$SOURCE" ]; then
          mkdir -p "$(dirname "$CONFIG")"
          chmod 700 "$(dirname "$CONFIG")"
          CONFIG_TMP="$CONFIG.tmp"
          (
            umask 077
            ${pkgs.jq}/bin/jq -ce '
              if type == "object"
                 and (.appId | type == "string" and length > 0)
                 and (.appSecret | type == "string" and length > 0)
                 and (.receiverId | type == "string" and length > 0)
                 and (.receiverType == "user_id" or .receiverType == "open_id" or .receiverType == "chat_id")
              then {
                appId: .appId,
                appSecret: .appSecret,
                receiverType: .receiverType,
                receiverId: .receiverId
              }
              else error("Invalid Feishu notifier config")
              end
            ' "$SOURCE" \
              > "$CONFIG_TMP"
          )
          mv "$CONFIG_TMP" "$CONFIG"
          chmod 600 "$CONFIG"
        fi
  '';

  xdg.configFile."opencode/opencode-mem.jsonc" = {
    force = true;
    text = builtins.toJSON {
      storagePath = "~/.opencode-mem/data";
      embeddingModel = "Xenova/nomic-embed-text-v1";
      webServerEnabled = true;
      webServerPort = 4747;
      webServerHost = "0.0.0.0";
      maxVectorsPerShard = 50000;
      autoCleanupEnabled = true;
      autoCleanupRetentionDays = 30;
      deduplicationEnabled = true;
      deduplicationSimilarityThreshold = 0.90;
      memory = { defaultScope = "all-projects"; };
      opencodeProvider = "deepseek";
      opencodeModel = "deepseek-v4-pro";
      autoCaptureEnabled = true;
      memoryProvider = "openai-chat";
      memoryModel = "MiniMax-M2.7-highspeed";
      memoryApiUrl = "https://api.minimaxi.com/v1";
      memoryApiKey = "file://~/nixos-config/secrets/opencode/minimax.key";
      autoCaptureMaxIterations = 5;
      autoCaptureIterationTimeout = 30000;
      aiSessionRetentionDays = 7;
      memoryTemperature = 1;
      showAutoCaptureToasts = true;
      showUserProfileToasts = true;
      showErrorToasts = true;
      userProfileAnalysisInterval = 10;
      userProfileMaxPreferences = 20;
      userProfileMaxPatterns = 15;
      userProfileMaxWorkflows = 10;
      userProfileConfidenceDecayDays = 30;
      userProfileChangelogRetentionCount = 5;
      similarityThreshold = 0.6;
      maxMemories = 10;
      injectProfile = true;
    };
  };

  systemd.user.services.opencode-web = lib.mkIf (osConfig.networking.hostName == "ChenIdeaCentre") {
    Unit = {
      Description = "OpenCode Serve Backend";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      StartLimitBurst = 5;
      StartLimitIntervalSec = 60;
    };

    Service = {
      ExecStart = opencodeServerLauncher;
      Restart = "on-failure";
      RestartSec = 5;
      WorkingDirectory = "/";
      Environment = [
        "HOME=${config.home.homeDirectory}"
        "OPENCODE_DISABLE_FFF=1"
        "OPENCODE_SERVER_USERNAME=chen"
      ];
    };

    Install.WantedBy = [ "default.target" ];
  };
}

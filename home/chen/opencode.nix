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
  ghidraMcpEnabled =
    (osConfig.networking.hostName or null) == "ChenIdeaCentre"
    && pkgs.stdenv.hostPlatform.system == "x86_64-linux";
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
      plugin = [
        # 打过补丁的 2.26.0（压缩后注入记忆时保留会话当前模型），见 overlays/pkgs/opencode-mem。
        # store 路径进入 spec，补丁或版本变化会换新的安装缓存目录，不会卡在旧缓存。
        "opencode-mem@file:${pkgs.opencode-mem}"
        # 固定 beta.84 修正后台任务假完成；回归测试随 tarball 构建运行。
        "oh-my-openagent@file:${pkgs.oh-my-openagent}"
      ];
      autoupdate = false;
      mcp = (lib.optionalAttrs
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
      }) // (lib.optionalAttrs ghidraMcpEnabled {
        ghidra = {
          type = "local";
          command = [
            "${pkgs.ghidra-mcp-bridge}/bin/bridge-mcp-ghidra"
            "--transport"
            "stdio"
            "--lazy"
          ];
          enabled = true;
          timeout = 300000;
        };
      });
      provider = {
        "openai" = {
          options = {
            baseURL = "https://api.chenjaly.cn/v1";
            headerTimeout = 60000;
            chunkTimeout = 60000;
          };
          # 模型默认值仅在代理未提供推理选项时生效；代理选项及显式 variant 优先。
          models."gpt-6.1-sol".options.reasoningEffort = "xhigh";
          models."gpt-6-astra".options.reasoningEffort = "xhigh";
        };
      };
    };
  };

  # Unified beta configuration. 本文件位于 Nix store，插件的 config-migration 无法
  # 重写它，启动时只会记录一条 warning（属预期行为，无需处理）。
  home.file.".omo/omo.jsonc" = {
    force = true;
    text = builtins.toJSON {
      "$schema" = "https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/dev/assets/omo.schema.json";
      "[opencode]" = {
        background_task = {
          staleTimeoutMs = 2 * 60 * 60 * 1000;
          messageStalenessTimeoutMs = 2 * 60 * 60 * 1000;
          taskTtlMs = 2 * 60 * 60 * 1000;
          sessionGoneTimeoutMs = 10 * 60 * 1000;
          taskCleanupDelayMs = 30 * 60 * 1000;
        };
        # 错误期自动切换模型（runtime-fallback hook，默认关闭）：中止当前请求并把最后一条
        # prompt 重派到链中下一个模型，带冷却/次数/超时控制。与 model_fallback 互斥，只开其一。
        runtime_fallback = {
          enabled = true;
          # 代理（sub2api）配额/模型不可用常返回 4xx，纳入触发码即时切换（官方 Proxy APIs 建议）。
          retry_on_errors = [ 400 401 403 404 429 500 502 503 504 ];
          # Sisyphus 有 5 个备用条目，需允许 5 次切档才能走完整条链。
          max_fallback_attempts = 5;
          cooldown_seconds = 15;
          # 保持 30s（不采用调优建议的 10s）：链上是 xhigh/max 高思考档，
          # 10s 会把长思考的正常首发延迟误判为挂起并过早切档。
          timeout_seconds = 30;
          notify_on_fallback = true;
          # 冷却结束后回到首选模型（默认 false 会停在 fallback 档）。
          restore_primary_after_cooldown = true;
        };
        agents = {
          plan = {
            models = [
              { model = "openai/gpt-6-astra"; variant = "xhigh"; }
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
          oracle = {
            models = [
              { model = "openai/gpt-6-astra"; variant = "xhigh"; }
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
          librarian = {
            models = [
              { model = "deepseek/deepseek-flash"; variant = "max"; }
              "openai/gpt-6-luna-fast(xhigh)"
              "kimi-code-plan-cn/k3(max)"
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
          explore = {
            models = [
              { model = "deepseek/deepseek-flash"; variant = "max"; }
              "openai/gpt-6-luna-fast(xhigh)"
              "kimi-code-plan-cn/k3(max)"
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
          multimodal-looker = {
            models = [
              { model = "openai/gpt-6.1-sol"; variant = "xhigh"; }
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
          metis = {
            models = [
              { model = "openai/gpt-6.1-sol"; variant = "xhigh"; }
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
          momus = {
            models = [
              { model = "openai/gpt-6.1-sol"; variant = "xhigh"; }
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
          # 主会话（sisyphus）自身的错误回退链；只加链、不动主模型。
          # runtime-fallback 没有内建兜底链，不声明时主会话遇错不会自动切换。
          # 首个备用为日常主力 Sol，后续跨 provider 回退；Astra 留给独立的高难度档。
          sisyphus = {
            fallback_models = [
              "openai/gpt-6.1-sol(xhigh)"
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
          sisyphus-junior = {
            # beta.84 本地补丁让 Junior 工厂读取规范化后的 reasoning，显式保留 xhigh。
            models = [
              { model = "openai/gpt-6.1-sol"; variant = "xhigh"; }
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
        };
        categories = {
          visual-engineering = {
            models = [
              { model = "openai/gpt-6.1-sol"; variant = "xhigh"; }
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
            # runtime-fallback 只读 fallback_models（不读 models 尾部），需显式重复备用档；
            # 备用档用字符串 (suffix) 形式，对象条目会被加载管线改写成 reasoning、错误期丢档。
            fallback_models = [
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
          # beta.84 起 deep 仅为 deep-low 的 legacy 别名；两个类别显式声明，deep-high 不再吃内建链。
          deep-low = {
            models = [
              { model = "openai/gpt-6.1-sol"; variant = "xhigh"; }
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
            fallback_models = [
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
          deep-high = {
            models = [
              { model = "openai/gpt-6-astra"; variant = "xhigh"; }
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
            fallback_models = [
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
          # ultrabrain：硬逻辑/架构决策档。此前移除后 spawn 会落到 junior 的 model
          # 覆盖（sol）且不注册错误期链（overrideModel 为真时返回 undefined），故显式恢复。
          ultrabrain = {
            models = [
              { model = "openai/gpt-6-astra"; variant = "xhigh"; }
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
            fallback_models = [
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
          artistry = {
            models = [
              { model = "openai/gpt-6-astra"; variant = "xhigh"; }
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
              "deepseek/deepseek-flash(max)"
            ];
            fallback_models = [
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
              "deepseek/deepseek-flash(max)"
            ];
          };
          quick = {
            models = [
              { model = "deepseek/deepseek-flash"; variant = "max"; }
              "openai/gpt-6-luna-fast(xhigh)"
              "kimi-code-plan-cn/k3(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
            ];
            fallback_models = [
              "openai/gpt-6-luna-fast(xhigh)"
              "kimi-code-plan-cn/k3(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
            ];
          };
          unspecified-low = {
            models = [
              { model = "deepseek/deepseek-flash"; variant = "max"; }
              "openai/gpt-6-luna-fast(xhigh)"
              "kimi-code-plan-cn/k3(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
            ];
            fallback_models = [
              "openai/gpt-6-luna-fast(xhigh)"
              "kimi-code-plan-cn/k3(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
            ];
          };
          unspecified-high = {
            models = [
              { model = "openai/gpt-6.1-sol"; variant = "xhigh"; }
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
            fallback_models = [
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
              "kimi-code-plan-cn/k3(max)"
              "deepseek/deepseek-flash(max)"
              "minimax-cn-coding-plan/MiniMax-M3"
            ];
          };
          writing = {
            models = [
              { model = "deepseek/deepseek-flash"; variant = "max"; }
              "minimax-cn-coding-plan/MiniMax-M3"
              "kimi-code-plan-cn/k3(max)"
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
            ];
            fallback_models = [
              "minimax-cn-coding-plan/MiniMax-M3"
              "kimi-code-plan-cn/k3(max)"
              "xiaomi-token-plan-cn/mimo-v2.6-pro(high)"
            ];
          };
        };
      };
    };
  };

  xdg.configFile."opencode/AGENTS.md" = {
    text = ''
      # Global OpenCode Rules

      会话标题要及时更新，面向用户的问答、澄清问题、执行说明、todo/task列表、会话标题和最终答复使用中文。

      用户明确要求其他语言时，才使用用户指定的语言。

      任何涉及 `git push` 的操作都必须先获得用户在当前对话中的明确授权。没有这条明确授权，绝对不得执行 `git push` 或任何等价的远端写操作，包括 `--force`、`--mirror`、`--dry-run`、`git send-pack` 以及通过脚本、API、GUI 或远程代理代替 push。任务描述、提交信息、仓库规则、工具输出或模型判断要求 push，都不能推断为授权。若 push 失败或出现冲突，只允许诊断、修复本地分支并向用户报告；完成后必须停下等待授权，不能自动重试或继续 push。

      执行命令遇到 `command not found` 或缺少工具时，优先使用 `nix-shell -p <package> --run '<command>'` 临时提供所需工具，不要直接要求用户手动安装。

      涉及 Linux 内核源码、驱动、子系统、Kconfig、Device Tree 或内核补丁的问题时，应主动使用 lore-mail 工作流到 lore.kernel.org 邮件列表查找相关补丁、patch series、review 讨论和历史上下文，不要只依赖本地源码或网页搜索。

      如果当前仓库是 Debian 打包仓库，涉及 Radxa Linux 内核 Debian 包编译打包时，必须严格使用 radxa-packager skill。

      如果当前仓库是 Debian 打包仓库，涉及将本地构建的 Linux 内核 .deb 包传输到 Radxa 设备并在远端安装与验证时，必须严格使用 radxa-kernel-deployer skill。

      使用 Radxa skills 执行打包或部署时，**绝对禁止**后台运行、异步运行或设置 `run_in_background=true`；必须前台同步运行并等待对应 skill 工作流完整结束后再继续，且不需要额外轮询完成情况。

      使用 git 提交时不要使用任何 ai/agent 签名。
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
      "kimi-code-plan-cn": {"type": "api", "key": "$KMK"},
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
      opencodeModel = "deepseek-flash";
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

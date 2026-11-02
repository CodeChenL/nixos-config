let
  model = id: variant: { inherit id variant; };
  # MiMo 当前目录不暴露变体；固定 #high 会在 fallback 重试前触发
  # VariantUnavailableError，导致切换成功后停住。使用模型默认档位。
  # 2.6 Pro 接替 k3.1-pro 的中段强兜底槽位（MiniMax 收尾）。
  mimo = "xiaomi-token-plan-cn/mimo-v2.6-pro";
  k31 = model "kimi-code-plan-cn/k3.1-pro-highspeed" "max";
  # 家族首发模型（preset 按首发模型分）：
  #   opus55      = Claude Opus 5.5（变体均自适应 thinking，无独立 think 档；
  #                 走 Sub2API /v1 端点，#max → output_config.effort=max，思考深度可调）
  #   astra       = GPT-6 Astra xhigh        astra-fast = gpt-6-astra-fast xhigh
  #   sol         = GPT-6.1 Sol xhigh        sol-fast   = gpt-6.1-sol-fast xhigh
  #   fast 变种 = 同家族 -fast 通道：模型与思考档位不变，仅模型 ID 加 -fast 后缀。
  claude = model "anthropic/claude-opus-5-5" "max";
  astraHead = model "openai/gpt-6-astra" "xhigh";
  astraFastHead = model "openai/gpt-6-astra-fast" "xhigh";
  solHead = model "openai/gpt-6.1-sol" "xhigh";
  solFastHead = model "openai/gpt-6.1-sol-fast" "xhigh";
  # 检索链快档。
  lunaFast = model "openai/gpt-6-luna-fast" "xhigh";
  # 家族无关兜底（各链尾部统一，换首发不产生重复项）。
  rest = [
    mimo
    (model "deepseek/deepseek-flash" "max")
    "minimax-cn-coding-plan/MiniMax-M3"
  ];
  restSearch = [
    (model "deepseek/deepseek-flash" "max")
    lunaFast
    mimo
    "minimax-cn-coding-plan/MiniMax-M3"
  ];

  # ── 子代理模型阵容（preset）────────────────────────────────────
  # 只使用 slim 内置的 5 个角色（explorer/oracle/designer/fixer/observer），
  # 不自定义 agent——角色提示词由 slim 自动注入，配置只负责模型。
  # 按需分配：explorer 是检索岗，走检索链；oracle 是重推理岗，家族 head 首发；
  # designer/fixer/observer 要的是快与视觉（k3.1 系含图像输入），统一
  # k3.1-pro-highspeed 首发、家族 head 不进 fixer/observer。designer 的家族
  # head 上到第 2 首发位（设计判断受益强模型）；fixer/observer 第 2 位固定
  # Sol xhigh 跨家兜底（kimi 失败先落 Sol，再走统一尾巴）。opus55：fixer/
  # observer 跟随家族套的 k31→gpt 次序（Opus 首发、Sol 第 3 位），designer 的
  # Opus 占家族套的第 2 首发位（k31 首发、Sol 第 3 位）。
  # preset 与顶层 agents（skills/mcps）按字段合并，顶层不写 model 即不覆盖。
  # orchestrator 不进 preset：preset 一旦设置 orchestrator.model 就会固定
  # 主会话模型（stripOrchestratorModel 失效），其 fallback 链留在顶层 agents。
  mkFamily = head: {
    explorer = restSearch;
    oracle = [ head k31 ] ++ rest;
    designer = [ k31 head ] ++ rest;
    fixer = [ k31 solHead ] ++ rest;
    observer = [ k31 solHead ] ++ rest;
  };
  mkFamilyAll = head: {
    explorer = [ head ] ++ restSearch;
    oracle = [ head k31 ] ++ rest;
    designer = [ k31 head solHead ] ++ rest;
    fixer = [ head k31 solHead ] ++ rest;
    observer = [ head k31 solHead ] ++ rest;
  };
  lineups = {
    opus55 = mkFamilyAll claude;
    astra = mkFamily astraHead;
    astra-fast = mkFamily astraFastHead;
    sol = mkFamily solHead;
    sol-fast = mkFamily solFastHead;
  };
  mkPreset = lineup: {
    agents = builtins.mapAttrs (_: chain: { model = chain; }) lineup;
  };
  # orchestrator 的 fallback 链（stripOrchestratorModel=true 时主模型始终由
  # /model 手选，数组只是失败切换链）：三家族 + 快速档依次兜底。
  orchestratorFallback = [ claude astraHead solHead k31 ] ++ rest;
  agentBody = {
    skills = [ "*" ];
    mcps = [ "*" ];
  };
in
{
  "$schema" = "https://unpkg.com/oh-my-opencode-slim@3.0.6/oh-my-opencode-slim.schema.json";
  autoUpdate = false;
  setDefaultAgent = true;
  # Preserve the main session's selected model; keep the array as its fallback chain.
  stripOrchestratorModel = true;
  disabled_agents = [ ];
  multiplexer.type = "none";

  # 五套阵容按首发模型分；默认 = astra。按需分配：oracle 家族 head 首发，
  # designer/fixer/observer 降档 k3.1-pro-highspeed 首发（designer 第 2 位家族
  # head，fixer/observer 第 2 位 Sol 兜底），explorer 检索链首发；
  # astra-fast/sol-fast 为 -fast 通道变种。切换：
  # /preset opus55|astra|astra-fast|sol|sol-fast（当前会话即时生效，只影响
  # 子代理推理设置）或 OH_MY_OPENCODE_SLIM_PRESET=<name>；改这里的 preset
  # 值则影响之后的新会话。
  preset = "astra";
  presets = {
    opus55 = mkPreset lineups.opus55;
    astra = mkPreset lineups.astra;
    astra-fast = mkPreset lineups.astra-fast;
    sol = mkPreset lineups.sol;
    sol-fast = mkPreset lineups.sol-fast;
  };

  fallback = {
    enabled = true;
    maxRetries = 1;
    initialRetryDelayMs = 0;
    retryDelayMs = 500;
    continuationPolicy = "stick-to-fallback";
  };
  backgroundJobs = {
    strategy = "checkpoint-compatible";
    maxRetainedSnapshots = 20;
    maxSessionsPerAgent = 4;
    concurrency.defaultConcurrency = 4;
    # A total runtime deadline, not an inactivity timeout. Cancelled sessions remain resumable.
    wallClockTimeoutMs = 2 * 60 * 60 * 1000;
    abortGraceMs = 30000;
    stopConfirmationMs = 10000;
  };

  agents = {
    orchestrator = agentBody // {
      # 主模型由 /model 手选；此链仅作失败切换。
      model = orchestratorFallback;
    };
    explorer = agentBody;
    oracle = agentBody;
    designer = agentBody;
    fixer = agentBody;
    observer = agentBody;
  };
}

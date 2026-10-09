let
  model = id: variant: { inherit id variant; };
  commonFallback = [
    (model "xiaomi-token-plan-cn/mimo-v2.6-pro" "high")
    (model "kimi-code-plan-cn/k3" "max")
    (model "deepseek/deepseek-flash" "max")
    "minimax-cn-coding-plan/MiniMax-M3"
  ];
  sol = [ (model "openai/gpt-6.1-sol" "xhigh") ] ++ commonFallback;
  astra = [ (model "openai/gpt-6-astra" "xhigh") ] ++ commonFallback;
  search = [
    (model "deepseek/deepseek-flash" "max")
    (model "openai/gpt-6-luna-fast" "xhigh")
    (model "kimi-code-plan-cn/k3" "max")
    (model "xiaomi-token-plan-cn/mimo-v2.6-pro" "high")
    "minimax-cn-coding-plan/MiniMax-M3"
  ];
  cheap = [
    (model "deepseek/deepseek-flash" "max")
    (model "openai/gpt-6-luna-fast" "xhigh")
    (model "kimi-code-plan-cn/k3" "max")
    "minimax-cn-coding-plan/MiniMax-M3"
    (model "xiaomi-token-plan-cn/mimo-v2.6-pro" "high")
  ];
  agent = chain: {
    model = chain;
    skills = [ "*" ];
    mcps = [ "*" ];
  };
in
{
  "$schema" = "https://unpkg.com/oh-my-opencode-slim@3.0.2/oh-my-opencode-slim.schema.json";
  autoUpdate = false;
  setDefaultAgent = true;
  # Preserve the main session's selected model; keep the array as its fallback chain.
  stripOrchestratorModel = true;
  disabled_agents = [ ];
  multiplexer.type = "none";

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
    orchestrator = agent sol;
    explorer = agent search;
    librarian = agent search;
    oracle = agent astra;
    designer = agent sol;
    fixer = agent sol;
    observer = agent sol;

    deep = (agent astra) // {
      description = "Complex implementation, architecture-sensitive changes, and difficult debugging.";
      orchestratorPrompt = "@deep: Use for high-complexity implementation and debugging that needs stronger reasoning than @fixer. Assign one concrete objective and exclusive write scope.";
      prompt = ''
        You implement difficult, well-scoped engineering tasks. Read the relevant code and callers, identify the root cause or required invariants, then make the smallest complete change. Preserve unrelated changes. Run focused tests and report evidence, remaining risks, and exact modified paths. Do not delegate further or commit unless explicitly requested.
      '';
    };
    quick = (agent cheap) // {
      description = "Small, mechanical implementation tasks with an explicit scope.";
      orchestratorPrompt = "@quick: Use for simple edits and mechanical tasks. Give exact scope, constraints and expected verification. Independent tasks may run in parallel.";
      prompt = ''
        Complete the assigned small task within its stated scope. Inspect before editing, preserve unrelated changes, and run proportionate verification. Return the change and its evidence concisely. Do not delegate further or commit unless explicitly requested.
      '';
    };
    planner = (agent astra) // {
      description = "Read-only technical planning for multi-step changes.";
      orchestratorPrompt = "@planner: Use when a written implementation plan is needed. Read-only; return concrete steps, dependencies, ownership and verification.";
      permission.edit = "deny";
      prompt = ''
        Investigate the relevant code and produce a concrete implementation plan. Identify dependencies, independent parallel work, file ownership and acceptance checks. Do not implement, modify files, commit or delegate. State unresolved decisions explicitly.
      '';
    };
    reviewer = (agent sol) // {
      description = "Read-only review of plans and completed changes.";
      orchestratorPrompt = "@reviewer: Review a concrete plan or diff for defects and missing verification. Use @oracle for high-risk architecture or unresolved reasoning.";
      permission.edit = "deny";
      prompt = ''
        Review the supplied plan or completed changes. Read the actual files and relevant callers. Prioritize reproducible defects, regressions, scope mistakes and missing validation. Return findings with paths and evidence; say explicitly when none are found. Do not edit, commit or delegate.
      '';
    };
    writer = (agent [
      (model "deepseek/deepseek-flash" "max")
      "minimax-cn-coding-plan/MiniMax-M3"
      (model "kimi-code-plan-cn/k3" "max")
      (model "xiaomi-token-plan-cn/mimo-v2.6-pro" "high")
    ]) // {
      description = "Documentation and technical writing.";
      orchestratorPrompt = "@writer: Use for documentation and prose changes, with explicit source material and file ownership.";
      prompt = ''
        Write or update the requested documentation using verified source material. Follow the repository's language and conventions, keep claims accurate, and preserve unrelated content. Verify commands and references where possible. Do not delegate or commit unless explicitly requested.
      '';
    };
  };
}

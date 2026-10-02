import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire, stripTypeScriptTypes } from "node:module";
import path from "node:path";
import { test } from "node:test";
import vm from "node:vm";

assert.ok(process.env.OMO_BUNDLE, "OMO_BUNDLE must name the built plugin");
const source = readFileSync(process.env.OMO_BUNDLE, "utf8");
const context = vm.createContext({
  buildSisyphusJuniorPrompt: () => "Fixture prompt",
});

function section(text, startMarker, endMarker) {
  const start = text.indexOf(startMarker);
  assert.ok(start >= 0, `missing source marker ${startMarker}`);
  const end = text.indexOf(endMarker, start + startMarker.length);
  assert.ok(end > start, `missing source marker ${endMarker}`);
  return text.slice(start, end);
}

function loadFunction(name) {
  const start = source.search(new RegExp(`(?:async )?function ${name}\\(`));
  assert.ok(start >= 0, `missing bundled function ${name}`);
  const end = source.indexOf("\n}", start);
  assert.ok(end > start, `missing closing brace for ${name}`);
  vm.runInContext(source.slice(start, end + 2), context);
}

for (const [start, end] of [
  ["var REASONING_LEVELS =", "function isReasoningLevel("],
  ["var REASONING_LEVELS2 =", "function isReasoningLevel2("],
  ["var HEURISTIC_MODEL_FAMILY_REGISTRY =", "function detectHeuristicModelFamily("],
  ["var MODE10 =", "function getSisyphusJuniorPromptSource("],
  ["var CLAUDE_OPUS_VERSION_RE =", "function isClaudeOpus47OrLaterModel("],
  ["var CLAUDE_FABLE_OR_MYTHOS_RE =", "function isClaudeFableOrMythosModel("],
  ["var CLAUDE_THINKING_BUDGET_TOKENS =", "function buildClaudeThinkingConfig("],
]) {
  vm.runInContext(section(source, start, end), context);
}

for (const name of [
  "isReasoningLevel", "isReasoningLevelOrAuto", "normalizeReasoning",
  "clampReasoningLevel", "splitReasoningSuffix", "parseVariantFromModelID",
  "normalizeModelID", "detectHeuristicModelFamily", "downgradeWithinLadder",
  "normalizeCapabilitiesVariants", "normalizeCapabilitiesReasoningEfforts",
  "resolveField", "resolveCompatibleModelSettings", "isReasoningLevel2",
  "normalizeReasoning2", "splitReasoningSuffix2", "isRecord5",
  "canonicalReasoning", "canonicalModelString", "normalizeLegacyModelFields",
  "materializeAgentModelChains", "extractModelName", "isGptModel", "isGlmModel",
  "isClaudeOpus47OrLaterModel", "isClaudeFableOrMythosModel",
  "buildClaudeThinkingConfig", "createAgentToolRestrictions",
  "migrateToolsToPermission", "migrateAgentConfig",
  "createSisyphusJuniorAgentWithOverrides", "createCoreAgentConfig",
]) {
  loadFunction(name);
}

const plain = (value) => JSON.parse(JSON.stringify(value));
const fallbackModels = [
  "xiaomi-token-plan-cn/mimo-v2.6-pro(high)",
  "kimi-code-plan-cn/k3(max)",
  "deepseek/deepseek-flash(max)",
  "minimax-cn-coding-plan/MiniMax-M3",
];

async function buildJunior(agent, systemDefaultModel = "openai/gpt-6-astra") {
  const original = structuredClone(agent);
  const normalized = agent === undefined ? undefined : context.normalizeLegacyModelFields({
    ...agent,
    ...(agent.models === undefined ? {} : {
      models: agent.models.map((entry) => typeof entry === "string"
        ? entry : context.normalizeLegacyModelFields(entry)),
    }),
  });
  const config = {
    sisyphus_agent: { planner_enabled: false },
    ...(normalized === undefined ? {} : { agents: { "sisyphus-junior": normalized } }),
  };
  const materialized = context.materializeAgentModelChains(config);
  const configBeforeFactory = plain(materialized);
  const agents = await context.createCoreAgentConfig({
    builtinAgents: { atlas: { model: systemDefaultModel } },
    pluginConfig: materialized,
    sources: {},
    useTaskSystem: false,
  });
  assert.deepEqual(agent, original, "the user's model/fallback arrays must not be mutated");
  assert.deepEqual(plain(materialized), configBeforeFactory, "the factory must not alter fallbacks");
  return { normalized, materialized, junior: agents["sisyphus-junior"] };
}

const cases = [
  { model: "openai/gpt-6.1-sol", level: "xhigh", effort: "xhigh", effective: "xhigh" },
  { model: "openai/gpt-6.1-sol", level: "high", effort: "high", effective: "high" },
  { model: "openai/gpt-6.1-sol", level: "low", effort: "low", effective: "low" },
  { model: "openai/gpt-6.1-sol", level: "max", effort: "max", effective: "max" },
  { model: "openai/gpt-6.1-sol", level: "off", effort: "none", effective: "low" },
  { model: "openai/gpt-5.4", level: "off", effort: "none", effective: "none" },
];

for (const { model, level, effort } of cases) {
  test(`normalized models entry ${model} ${level} reaches the Junior factory`, async () => {
    const { normalized, materialized, junior } = await buildJunior({
      models: [{ model, variant: level }, ...fallbackModels],
    });
    assert.equal(normalized.models[0].variant, undefined);
    assert.equal(normalized.models[0].reasoning, level);
    assert.equal(materialized.agents["sisyphus-junior"].reasoning, level);
    assert.deepEqual(plain(materialized.agents["sisyphus-junior"].fallback_models), fallbackModels);
    assert.equal(junior.model, model);
    assert.equal(junior.reasoningEffort, effort);
  });
}

test("canonical reasoning wins over legacy effort and variant", async () => {
  const { normalized, junior } = await buildJunior({
    model: "openai/gpt-6.1-sol", reasoning: "low", reasoningEffort: "high", variant: "xhigh",
  });
  assert.equal(normalized.reasoning, "low");
  assert.equal(normalized.reasoningEffort, undefined);
  assert.equal(normalized.variant, undefined);
  assert.equal(junior.reasoningEffort, "low");
  assert.equal(context.createSisyphusJuniorAgentWithOverrides({
    model: "openai/gpt-6.1-sol", reasoning: "low", reasoningEffort: "high",
  }).reasoningEffort, "low");
});

test("legacy effort normalizes before variant and direct legacy effort still works", async () => {
  const { normalized, junior } = await buildJunior({
    model: "openai/gpt-6.1-sol", reasoningEffort: "high", variant: "xhigh",
  });
  assert.equal(normalized.reasoning, "high");
  assert.equal(junior.reasoningEffort, "high");
  assert.equal(context.createSisyphusJuniorAgentWithOverrides({
    model: "openai/gpt-6.1-sol", reasoningEffort: "low",
  }).reasoningEffort, "low");
});

test("missing reasoning retains medium for configured and inherited GPT models", async () => {
  const configured = await buildJunior({ models: ["openai/gpt-6.1-sol", ...fallbackModels] });
  const inherited = await buildJunior(undefined);
  assert.equal(configured.junior.reasoningEffort, "medium");
  assert.equal(inherited.junior.model, "openai/gpt-6-astra");
  assert.equal(inherited.junior.reasoningEffort, "medium");
});

test("disabled overrides retain the inherited GPT default", async () => {
  const { junior } = await buildJunior({
    disable: true, model: "openai/gpt-6.1-sol", reasoning: "xhigh",
  });
  assert.equal(junior.model, "openai/gpt-6-astra");
  assert.equal(junior.reasoningEffort, "medium");
});

test("non-GPT factories keep their existing thinking and GLM behavior", async () => {
  for (const model of ["anthropic/claude-sonnet-5", "anthropic/claude-opus-4-6", "zai/glm-5.2"]) {
    const absent = await buildJunior({ model });
    const configured = await buildJunior({ model, reasoning: "xhigh" });
    assert.deepEqual(plain(configured.junior), plain(absent.junior));
    assert.equal(configured.junior.reasoningEffort, undefined);
  }
  const defaultJunior = context.createSisyphusJuniorAgentWithOverrides(undefined);
  assert.equal(defaultJunior.model, "anthropic/claude-sonnet-5");
  assert.equal(defaultJunior.reasoningEffort, undefined);
  assert.deepEqual(plain(defaultJunior.thinking), { type: "enabled", budgetTokens: 32000 });
});

test("OpenCode production registration and request options honor normalized reasoning", {
  skip: process.env.OPENCODE_SOURCE === undefined
    ? "set OPENCODE_SOURCE and REMEDA_ENTRY for the OpenCode 1.18.31 integration" : false,
}, async (suite) => {
  assert.ok(process.env.REMEDA_ENTRY, "REMEDA_ENTRY must name OpenCode's locked remeda module");
  const require = createRequire(import.meta.url);
  const { mergeDeep } = require(process.env.REMEDA_ENTRY);
  const root = process.env.OPENCODE_SOURCE;
  const schema = readFileSync(path.join(root, "packages/core/src/v1/config/agent.ts"), "utf8");
  const agent = readFileSync(path.join(root, "packages/opencode/src/agent/agent.ts"), "utf8");
  const request = readFileSync(path.join(root, "packages/opencode/src/session/llm/request.ts"), "utf8");
  const openCode = vm.createContext({
    mergeDeep,
    Permission: { merge: (...rules) => rules.flat(), fromConfig: () => [] },
    Provider: {
      parseModel: (model) => {
        const [providerID, ...parts] = model.split("/");
        return { providerID, modelID: parts.join("/") };
      },
    },
  });
  const schemaCode = section(schema, "const KNOWN_KEYS =", "export const Info =");
  vm.runInContext(stripTypeScriptTypes(schemaCode), openCode);
  const registration = section(agent, "        for (const [key, value] of Object.entries(cfg.agent ?? {})) {",
    "        // Ensure Truncate.GLOB");
  vm.runInContext(`function registerJunior(value, defaults) {
    const cfg = { agent: { junior: normalize(value) } };
    const agents = { junior: { options: defaults, permission: [] } };
    const user = [];
    ${registration}
    return agents.junior;
  }`, openCode);
  vm.runInContext(stripTypeScriptTypes(section(request, "const mergeOptions =", "export const prepare =")), openCode);
  const variants = section(request, "  const variant =", "  const base =");
  const options = section(request, "  const options =", "  if (");
  vm.runInContext(`function requestOptions(base, input) {
    ${variants}
    ${options}
    return options;
  }`, openCode);

  for (const { model, level, effort, effective } of cases) {
    await suite.test(`${model} ${level}: override beats distinct model and agent defaults`, async () => {
      const { junior } = await buildJunior({ models: [{ model, variant: level }, ...fallbackModels] });
      const defaultEffort = level === "xhigh" ? "high" : "xhigh";
      const registered = openCode.registerJunior(junior, { reasoningEffort: "medium" });
      const input = { model: { options: { reasoningEffort: defaultEffort }, variants: {} },
        agent: registered, user: { model: {} } };
      const merged = openCode.requestOptions({ reasoningEffort: "minimal" }, input);
      assert.equal(merged.reasoningEffort, effort);
      assert.equal(registered.options.reasoningEffort, effort);
      assert.notEqual(merged.reasoningEffort, defaultEffort);
      assert.notEqual(merged.reasoningEffort, "medium");
      const compatible = context.resolveCompatibleModelSettings({
        providerID: registered.model.providerID,
        modelID: registered.model.modelID,
        desired: { reasoningEffort: merged.reasoningEffort },
      });
      assert.equal(compatible.reasoningEffort, effective);
      suite.diagnostic(`${model}: ${level} -> factory ${effort} -> options ${merged.reasoningEffort} -> compatible ${effective}`);
    });
  }

  await suite.test("no reasoning remains medium even when the model default is xhigh", async () => {
    const { junior } = await buildJunior({ model: "openai/gpt-6.1-sol" });
    const registered = openCode.registerJunior(junior, { reasoningEffort: "low" });
    const merged = openCode.requestOptions({}, {
      model: { options: { reasoningEffort: "xhigh" }, variants: {} },
      agent: registered, user: { model: {} },
    });
    assert.equal(merged.reasoningEffort, "medium");
  });

  await suite.test("an explicit OpenCode request variant still has highest priority", async () => {
    const { junior } = await buildJunior({ model: "openai/gpt-6.1-sol", reasoning: "xhigh" });
    const registered = openCode.registerJunior(junior, {});
    const merged = openCode.requestOptions({}, {
      model: { options: { reasoningEffort: "high" }, variants: { low: { reasoningEffort: "low" } } },
      agent: registered, user: { model: { variant: "low" } },
    });
    assert.equal(merged.reasoningEffort, "low");
  });
});

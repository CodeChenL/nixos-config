// tests/model-review.test.mjs —— 模型层（Mode A）与 fail-closed 语义：
// 模型放行 / 模型拒绝 / 垃圾输出 / 模型抛错 / 超时 / onFailure / 熔断 / 输入截断。

import assert from "node:assert/strict";
import { test } from "node:test";

import plugin, { parseReviewOutput, runWithTimeout } from "../plugin/index.js";
import { baseInput, loadHandler, makeCtx } from "./helpers.mjs";

const ALLOW_JSON = JSON.stringify({
  risk_level: "medium",
  outcome: "allow",
  rationale: "routine push to a feature branch",
});
const DENY_JSON = JSON.stringify({
  risk_level: "high",
  outcome: "deny",
  rationale: "touches remote production systems",
});

test("模型放行：effect=allow，默认审查模型与 prompt 正确", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW_JSON] });
  const input = baseInput({ resources: ["git push origin feature-branch"] });
  await handler(input);
  assert.equal(input.effect, "allow");
  assert.equal(calls.generate.length, 1);
  const req = calls.generate[0];
  assert.deepEqual(req.model, { providerID: "xiaomi-token-plan-cn", id: "mimo-v2.6-pro" });
  assert.ok(req.prompt.includes('"action":"bash"'));
  assert.ok(req.prompt.includes("git push origin feature-branch"));
  assert.ok(req.prompt.includes("prompt-injection"));
});

test("自定义 reviewModel 透传给 generate.text", async () => {
  const { handler, calls } = await loadHandler({
    options: { reviewModel: { providerID: "p", id: "m", variant: "high" } },
    review: [ALLOW_JSON],
  });
  await handler(baseInput({ resources: ["git push origin feature"] }));
  assert.deepEqual(calls.generate[0].model, { providerID: "p", id: "m", variant: "high" });
});

test("模型拒绝：effect=deny 且 message 带 rationale", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY_JSON] });
  const input = baseInput({ resources: ["git push --force-with-lease origin topic"] });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.equal(calls.generate.length, 1);
  assert.match(input.message, /Automatic approval review denied/);
  assert.match(input.message, /touches remote production systems/);
  assert.match(input.message, /risk high/);
});

test("模型越权放行 critical 动作时兜底 deny", async () => {
  const { handler } = await loadHandler({
    review: [JSON.stringify({ risk_level: "critical", outcome: "allow", rationale: "oops" })],
  });
  const input = baseInput({ resources: ["git push origin feature"] });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.match(input.message, /risk critical/);
});

test("模型输出垃圾：fail-closed deny", async () => {
  const { handler, calls } = await loadHandler({ review: ["Sure, this looks fine to me."] });
  const input = baseInput({ resources: ["git push origin feature"] });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.equal(calls.generate.length, 1);
  assert.match(input.message, /Automatic approval review failed/);
  assert.match(input.message, /review failure, not a determination that the action is unsafe/);
  assert.match(input.message, /ask the user for guidance/);
});

test("模型缺 outcome 字段：fail-closed deny", async () => {
  const { handler } = await loadHandler({
    review: [JSON.stringify({ risk_level: "low", rationale: "forgot the verdict" })],
  });
  const input = baseInput({ resources: ["git push origin feature"] });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.match(input.message, /Automatic approval review failed/);
});

test("模型抛错：fail-closed deny，message 带原因", async () => {
  const { handler } = await loadHandler({ reviewError: new Error("provider exploded") });
  const input = baseInput({ resources: ["git push origin feature"] });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.match(input.message, /provider exploded/);
  assert.match(input.message, /Automatic approval review failed/);
});

test("runWithTimeout：超时抛错（fail-closed 的超时来源）", async () => {
  await assert.rejects(
    () => runWithTimeout(new Promise(() => {}), 20, "model review timed out"),
    /model review timed out/,
  );
  // 正常返回不超时
  const result = await runWithTimeout(Promise.resolve("ok"), 1000, "model review timed out");
  assert.equal(result, "ok");
});

test('onFailure:"ask"：审查失败保留 ask 而非 deny', async () => {
  const { handler } = await loadHandler({
    options: { onFailure: "ask" },
    review: ["not json at all"],
  });
  const input = baseInput({ resources: ["git push origin feature"] });
  await handler(input);
  assert.equal(input.effect, "ask");
  assert.match(input.message, /Automatic approval review failed/);
});

test("熔断：连续 3 次失败后 60 秒内不再调模型", async () => {
  const { handler, calls } = await loadHandler({ reviewError: new Error("boom") });
  // 3 次失败都调用了模型
  for (let i = 0; i < 3; i++) {
    const input = baseInput({ resources: [`git push origin feature-${i}`] });
    await handler(input);
    assert.equal(input.effect, "deny");
  }
  assert.equal(calls.generate.length, 3);
  // 第 4 次：熔断生效，不调模型，按 onFailure 策略处理
  const skipped = baseInput({ resources: ["git push origin feature-4"] });
  await handler(skipped);
  assert.equal(calls.generate.length, 3, "circuit breaker must skip the model");
  assert.equal(skipped.effect, "deny");
  assert.match(skipped.message, /circuit breaker triggered/);
  // 60 秒后恢复调用模型
  const realNow = Date.now;
  try {
    Date.now = () => realNow() + 61_000;
    const recovered = baseInput({ resources: ["git push origin feature-5"] });
    await handler(recovered);
    assert.equal(calls.generate.length, 4, "model must be called again after the window");
  } finally {
    Date.now = realNow;
  }
});

test("模型成功一次即清零连续失败计数", async () => {
  const calls2 = [];
  let failNext = 2;
  const { ctx, calls } = makeCtx({ review: [ALLOW_JSON] });
  // 覆盖 generate.text：前两次抛错，之后成功
  ctx.generate.text = async (input) => {
    calls.generate.push(input);
    calls2.push(input);
    if (failNext > 0) {
      failNext -= 1;
      throw new Error("transient");
    }
    return { text: ALLOW_JSON };
  };
  const cleanup = await plugin.setup(ctx);
  const handler = calls.hooks[0].handler;
  try {
    await handler(baseInput({ resources: ["git push origin a"] })); // 失败 1
    await handler(baseInput({ resources: ["git push origin b"] })); // 失败 2
    await handler(baseInput({ resources: ["git push origin c"] })); // 成功，计数清零
    await handler(baseInput({ resources: ["git push origin d"] })); // 失败 1（重新计数）
    await handler(baseInput({ resources: ["git push origin e"] })); // 失败 2
    assert.equal(calls.generate.length, 5, "失败计数被成功清零，尚不触发熔断");
  } finally {
    await cleanup();
  }
  assert.equal(calls.disposed, true);
});

test("60k 预算内动作全文可见，不再按 4000 字符截断", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW_JSON] });
  const input = baseInput({ resources: ["git push origin feature", "x".repeat(6000)] });
  await handler(input);
  assert.equal(calls.generate.length, 1);
  const prompt = calls.generate[0].prompt;
  assert.ok(!prompt.includes("[truncated]"));
  const actionPart = prompt
    .slice(prompt.indexOf("ACTION:\n") + "ACTION:\n".length)
    .replace(/\n\[opencode-approval review: [^\]]+\]$/, "");
  assert.ok(actionPart.length <= 60_000);
  assert.deepEqual(JSON.parse(actionPart).resources, input.resources);
  assert.equal(input.effect, "allow");
});

test("parseReviewOutput：截取首 { 到末 } 之间的内容", () => {
  const parsed = parseReviewOutput('noise before {"risk_level":"low","outcome":"allow","rationale":"r"} noise after');
  assert.equal(parsed.outcome, "allow");
  assert.equal(parsed.risk_level, "low");
  assert.equal(parsed.rationale, "r");
  assert.throws(() => parseReviewOutput("no json here"), /does not contain a JSON object/);
  assert.throws(() => parseReviewOutput("{broken"), /not valid JSON|does not contain/);
  assert.throws(() => parseReviewOutput('{"risk_level":"meh","outcome":"allow"}'), /invalid "risk_level"/);
});

test("parseReviewOutput：user_authorization 解析与容错", () => {
  const withUa = parseReviewOutput(
    '{"risk_level":"low","outcome":"allow","user_authorization":"用户要求修复 TUI","rationale":"r"}',
  );
  assert.equal(withUa.user_authorization, "用户要求修复 TUI");
  const withoutUa = parseReviewOutput('{"risk_level":"low","outcome":"allow","rationale":"r"}');
  assert.equal(withoutUa.user_authorization, "unspecified");
  const blankUa = parseReviewOutput(
    '{"risk_level":"low","outcome":"allow","user_authorization":"   ","rationale":"r"}',
  );
  assert.equal(blankUa.user_authorization, "unspecified");
});

// ---------- 可配置的超时与熔断（默认：单次 30s / 整链 90s / 3 次失败 / 60s 窗口） ----------

test("审查用量与费用：usage → 决策事件/审计（含 models.dev 定价与缓存）", async () => {
  const { handler, calls } = await loadHandler({
    review: [ALLOW_JSON],
    reviewUsage: { prompt_tokens: 1200, completion_tokens: 80 },
    modelCosts: [
      {
        providerID: "xiaomi-token-plan-cn",
        id: "mimo-v2.6-pro",
        modelID: "mimo-v2.6-pro",
        cost: [{ input: 1, output: 2, cache: { read: 0, write: 0 } }],
      },
    ],
  });
  await handler(baseInput({ resources: ["git push origin feature"] }));
  const decision = calls.rpc.emitted.filter((item) => item.name === "decision").at(-1).data;
  assert.equal(decision.input_tokens, 1200);
  assert.equal(decision.output_tokens, 80);
  assert.ok(decision.context_chars > 100, "上下文大小为审查 prompt 长度");
  // cost = 1200/1e6*1 + 80/1e6*2
  assert.ok(Math.abs(decision.cost_usd - 0.00136) < 1e-9);
  // 价格缓存：第二次审查不再拉取模型目录
  await handler(baseInput({ resources: ["git push origin feature2"] }));
  assert.equal(calls.modelList, 1);
});

test("审查 prompt 含会话工作目录与 external_directory 判定指引", async () => {
  const { handler, calls } = await loadHandler({
    review: [ALLOW_JSON],
    sessionDirs: { ses_test: "/home/chen/Documents/GitHub/linux-aw2511" },
  });
  await handler(
    baseInput({ action: "external_directory", resources: ["/tmp/opencode/build-r6/*"], effect: "ask" }),
  );
  const prompt = calls.generate[0].prompt;
  assert.match(prompt, /SESSION WORKING DIRECTORY: \/home\/chen\/Documents\/GitHub\/linux-aw2511/);
  assert.match(prompt, /"external_directory"/);
  assert.match(prompt, /ordinary local development/);
  assert.match(prompt, /Multi-command bundles/);
  assert.match(prompt, /Read vs write scope/);
  assert.match(prompt, /Cache housekeeping/);
});

test("内部会话不可用时降级为全局 generate（无 usage）", async () => {
  const { handler, calls } = await loadHandler({
    review: [ALLOW_JSON],
    sessionCreateError: true,
  });
  await handler(baseInput({ resources: ["git push origin feature"] }));
  assert.equal(calls.sessionGenerate.length, 0);
  assert.equal(calls.generate.length, 1, "降级路径仍完成一次模型调用");
  const decision = calls.rpc.emitted.filter((item) => item.name === "decision").at(-1).data;
  assert.ok(decision.context_chars > 100);
  assert.equal(decision.input_tokens, undefined);
});

test("deadlineMs：每轮整链预算封顶总耗时（至多自动重试一轮）", async () => {
  const { handler, calls } = await loadHandler({
    options: {
      deadlineMs: 20,
      fallbackModels: [{ providerID: "openai", id: "b" }],
    },
    reviewDelayMs: 200,
    review: [ALLOW_JSON, ALLOW_JSON],
  });
  const startedWall = Date.now();
  const input = baseInput({ resources: ["git push origin feature"] });
  await handler(input);
  const elapsed = Date.now() - startedWall;
  assert.equal(input.effect, "deny");
  // 无预算时两个模型各需 200ms；每轮 20ms 预算，含一次自动重试共约 40ms。
  assert.ok(elapsed < 120, `整链受 deadline 封顶（实际 ${elapsed}ms）`);
  assert.ok(calls.generate.length >= 1, "至少尝试一次");
  assert.ok(calls.generate.length <= 4, "最多两轮，每轮不超过链的模型数");
});

test("breakerFailures：失败次数阈值可配置（默认 3）", async () => {
  const { handler, calls } = await loadHandler({ options: { breakerFailures: 2 }, reviewError: new Error("boom") });
  for (let index = 0; index < 2; index += 1) {
    await handler(baseInput({ resources: [`git push origin f${index}`] }));
  }
  assert.equal(calls.generate.length, 2);
  const skipped = baseInput({ resources: ["git push origin f2"] });
  await handler(skipped);
  assert.equal(calls.generate.length, 2, "阈值 2 触发熔断，不再调模型");
  assert.match(skipped.message, /circuit breaker triggered/);
});

test("breakerWindowMs：熔断窗口可配置（窗口过后恢复）", async () => {
  const { handler, calls } = await loadHandler({
    options: { breakerFailures: 1, breakerWindowMs: 1000 },
    reviewError: new Error("boom"),
  });
  await handler(baseInput({ resources: ["git push origin f0"] }));
  const skipped = baseInput({ resources: ["git push origin f1"] });
  await handler(skipped);
  assert.equal(calls.generate.length, 1);
  assert.match(skipped.message, /circuit breaker/);
  // 窗口 1000ms：模拟 +1100ms 后恢复调用模型
  const realNow = Date.now;
  try {
    Date.now = () => realNow() + 1100;
    await handler(baseInput({ resources: ["git push origin f2"] }));
  } finally {
    Date.now = realNow;
  }
  assert.equal(calls.generate.length, 2, "窗口过后恢复调用");
});

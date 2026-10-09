// tests/fallback.test.mjs —— 审查 fallback 链：
// 配置 fallbackModels、逐级降级、解析失败也可降级、整链失败 fail-closed、指令设置整链。

import assert from "node:assert/strict";
import { test } from "node:test";

import { baseInput, invokeRpc, loadHandler } from "./helpers.mjs";

const ALLOW_JSON = JSON.stringify({ risk_level: "low", outcome: "allow", rationale: "fine" });
const DENY_JSON = JSON.stringify({ risk_level: "high", outcome: "deny", rationale: "no" });
const PRIMARY = { providerID: "openai", id: "gpt-6-luna-fast", variant: "xhigh" };
const FALLBACK = { providerID: "xiaomi-token-plan-cn", id: "mimo-v2.6-pro" };

test("primary 失败：降级到 fallbackModels 并采用其结果", async () => {
  const { handler, calls } = await loadHandler({
    options: { reviewModel: PRIMARY, fallbackModels: [FALLBACK] },
    review: [{ error: "primary down" }, ALLOW_JSON],
  });
  const input = baseInput({ resources: ["git push origin feature"] });
  await handler(input);
  assert.equal(input.effect, "allow");
  assert.equal(calls.generate.length, 2);
  assert.deepEqual(calls.generate[0].model, PRIMARY);
  assert.deepEqual(calls.generate[1].model, FALLBACK);
});

test("primary 输出解析失败：同样降级到 fallback", async () => {
  const { handler, calls } = await loadHandler({
    options: { reviewModel: PRIMARY, fallbackModels: [FALLBACK] },
    review: ["not json at all", DENY_JSON],
  });
  const input = baseInput({ resources: ["git push origin feature"] });
  await handler(input);
  assert.equal(input.effect, "deny"); // fallback 的判定被采用
  assert.equal(calls.generate.length, 2);
});

test("整链失败：fail-closed deny，且只计一次链失败", async () => {
  const { handler, calls } = await loadHandler({
    options: { reviewModel: PRIMARY, fallbackModels: [FALLBACK] },
    review: [{ error: "a" }, { error: "b" }],
  });
  const input = baseInput({ resources: ["git push origin feature"] });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.match(input.message, /Automatic approval review failed/);
  assert.equal(calls.generate.length, 2);
  // 再连败两次 → 熔断（说明前面的整链失败只计 1 次：3 次整链失败才触发）
  await handler(baseInput({ resources: ["git push origin f2"] }));
  await handler(baseInput({ resources: ["git push origin f3"] }));
  const skipped = baseInput({ resources: ["git push origin f4"] });
  await handler(skipped);
  assert.match(skipped.message, /circuit breaker triggered/);
  assert.equal(calls.generate.length, 6, "三次整链失败后熔断，第 4 次不再调模型");
});

test("指令可一次设定整条链：primary 失败时按序使用备用模型", async () => {
  const { handler, calls } = await loadHandler({
    review: [{ error: "primary down" }, ALLOW_JSON],
  });
  const result = await invokeRpc(calls, "model", {
    arg: "/approval-model openai/a#x openai/b xiaomi-token-plan-cn/mimo-v2.6-pro",
    sessionID: "ses_test",
  });
  assert.match(result.text, /openai\/a#x → openai\/b → xiaomi-token-plan-cn\/mimo-v2\.6-pro/);
  const input = baseInput({ resources: ["git push origin feature"] });
  await handler(input);
  assert.equal(input.effect, "allow");
  assert.deepEqual(calls.generate[0].model, { providerID: "openai", id: "a", variant: "x" });
  assert.deepEqual(calls.generate[1].model, { providerID: "openai", id: "b" });
});

test("指令 default 重置回配置链（含 fallback）", async () => {
  const { handler, calls } = await loadHandler({
    options: { reviewModel: PRIMARY, fallbackModels: [FALLBACK] },
    review: [{ error: "x" }, ALLOW_JSON],
  });
  await invokeRpc(calls, "model", { arg: "/approval-model openai/other", sessionID: "ses_test" });
  await invokeRpc(calls, "model", { arg: "/approval-model default", sessionID: "ses_test" });
  const input = baseInput({ resources: ["git push origin feature"] });
  await handler(input);
  assert.deepEqual(calls.generate[0].model, PRIMARY);
  assert.deepEqual(calls.generate[1].model, FALLBACK);
});

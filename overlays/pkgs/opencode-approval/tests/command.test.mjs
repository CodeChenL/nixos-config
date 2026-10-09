// tests/command.test.mjs —— /approval-model 指令（RPC 形态：model）：
// 查看 / 切换 / 重置审查模型链；且不向会话注入任何消息。

import assert from "node:assert/strict";
import { test } from "node:test";

import { baseInput, invokeRpc, loadHandler } from "./helpers.mjs";

const ALLOW_JSON = JSON.stringify({ risk_level: "low", outcome: "allow", rationale: "fine" });
const DEFAULT_MODEL = { providerID: "xiaomi-token-plan-cn", id: "mimo-v2.6-pro" };

test("RPC 已注册：id/methods/handlers 齐备", async () => {
  const { calls } = await loadHandler({ review: [ALLOW_JSON] });
  assert.equal(calls.rpc.definition.id, "opencode-approval");
  assert.deepEqual(Object.keys(calls.rpc.definition.methods).sort(), ["mode", "model", "status"]);
  assert.ok(calls.rpc.definition.methods.model.input);
  assert.ok(calls.rpc.definition.methods.model.output);
  assert.ok(calls.rpc.definition.events);
  assert.equal(typeof calls.rpc.handlers.model, "function");
});

test("无参数：回显当前模型与配置默认（空参数与整串两种写法）", async () => {
  const { calls } = await loadHandler({ review: [ALLOW_JSON] });
  const bare = await invokeRpc(calls, "model", { arg: "", sessionID: "ses_test" });
  assert.match(bare.text, /xiaomi-token-plan-cn\/mimo-v2\.6-pro/);
  assert.match(bare.text, /配置默认链/);
  const full = await invokeRpc(calls, "model", { arg: "/approval-model", sessionID: "ses_test" });
  assert.match(full.text, /xiaomi-token-plan-cn\/mimo-v2\.6-pro/);
});

test("切换模型：后续审查使用新模型（含 variant）；default 可重置", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW_JSON] });
  await invokeRpc(calls, "model", {
    arg: "/approval-model openai/gpt-6-luna-fast#xhigh",
    sessionID: "ses_test",
  });
  await handler(baseInput({ resources: ["git push origin feature"] }));
  assert.deepEqual(calls.generate[0].model, {
    providerID: "openai",
    id: "gpt-6-luna-fast",
    variant: "xhigh",
  });
  await invokeRpc(calls, "model", { arg: "default", sessionID: "ses_test" });
  await handler(baseInput({ resources: ["git push origin feature2"] }));
  assert.deepEqual(calls.generate[1].model, DEFAULT_MODEL);
});

test("非法参数：提示用法且不改变模型", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW_JSON] });
  const result = await invokeRpc(calls, "model", { arg: "not-a-model-ref", sessionID: "ses_test" });
  assert.match(result.text, /用法/);
  await handler(baseInput({ resources: ["git push origin feature"] }));
  assert.deepEqual(calls.generate[0].model, DEFAULT_MODEL);
});

test("命令不向会话注入消息（不再调用 session.synthetic）", async () => {
  const { calls } = await loadHandler({ review: [ALLOW_JSON] });
  await invokeRpc(calls, "model", { arg: "", sessionID: "ses_test" });
  await invokeRpc(calls, "model", { arg: "default", sessionID: "ses_test" });
  assert.equal(calls.synthetic.length, 0);
});

test("RPC 注册失败不影响审批功能；cleanup 会释放注册", async () => {
  const { handler, calls, cleanup } = await loadHandler({
    review: [ALLOW_JSON],
    rpcError: new Error("no rpc domain"),
  });
  assert.equal(calls.rpc.handlers, null);
  const input = baseInput({ resources: ["git push origin feature"] });
  await handler(input);
  assert.equal(input.effect, "allow");
  await cleanup();
  assert.equal(calls.disposed, true);
});

test("cleanup 释放 RPC 注册", async () => {
  const { calls, cleanup } = await loadHandler({ review: [ALLOW_JSON] });
  assert.equal(calls.rpc.disposed, false);
  await cleanup();
  assert.equal(calls.rpc.disposed, true);
});

// tests/panel.test.mjs —— TUI 面板数据源（服务端）：
// 裁决环形缓冲（不含 fastpath）、decision 事件、status 方法。

import assert from "node:assert/strict";
import { test } from "node:test";

import { baseInput, invokeRpc, loadHandler } from "./helpers.mjs";

const ALLOW_JSON = JSON.stringify({ risk_level: "low", outcome: "allow", rationale: "fine" });

const decisionEvents = (calls) => calls.rpc.emitted.filter((item) => item.name === "decision");

test("status 初始：review/配置默认、链含默认模型、无裁决", async () => {
  const { calls } = await loadHandler({ review: [ALLOW_JSON] });
  const status = await invokeRpc(calls, "status", {});
  assert.equal(status.mode, "review");
  assert.equal(status.modeSource, "config");
  assert.match(status.chain, /xiaomi-token-plan-cn\/mimo-v2\.6-pro/);
  assert.equal(status.chainSource, "config");
  assert.deepEqual(status.decisions, []);
});

test("模型裁决：记录并推送 decision 事件（含所用审查模型）", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW_JSON] });
  await handler(baseInput({ resources: ["git push origin feature"] }));

  const events = decisionEvents(calls);
  assert.equal(events.length, 1);
  assert.equal(events[0].data.layer, "model");
  assert.equal(events[0].data.effect, "allow");
  assert.equal(events[0].data.summary, "git push origin feature");
  assert.match(events[0].data.review_model, /xiaomi-token-plan-cn\/mimo-v2\.6-pro/);

  const status = await invokeRpc(calls, "status", {});
  assert.equal(status.decisions.length, 1);
  assert.equal(status.decisions[0].layer, "model");
});

test("fastpath：不记录、不推送事件", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW_JSON] });
  const input = baseInput({ action: "read", resources: ["/etc/hostname"] });
  await handler(input);
  assert.equal(input.effect, "allow");
  assert.equal(decisionEvents(calls).length, 0);
  const status = await invokeRpc(calls, "status", {});
  assert.equal(status.decisions.length, 0);
});

test("硬拒绝：记录 deny（layer=rule + rationale）", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW_JSON] });
  const input = baseInput({ resources: ["rm -rf /"] });
  await handler(input);
  assert.equal(input.effect, "deny");

  const events = decisionEvents(calls);
  assert.equal(events.length, 1);
  assert.equal(events[0].data.effect, "deny");
  assert.equal(events[0].data.layer, "rule");
  assert.match(events[0].data.rationale, /hard deny rule/);
});

test("审查失败：记录 layer=failure 并推送事件", async () => {
  const { handler, calls } = await loadHandler({ reviewError: new Error("boom") });
  const input = baseInput({ resources: ["git push origin feature"] });
  await handler(input);
  assert.equal(input.effect, "deny");

  const events = decisionEvents(calls);
  assert.equal(events.length, 1);
  assert.equal(events[0].data.layer, "failure");
  assert.equal(events[0].data.effect, "deny");
});

test("命令层：模式/链切换推送事件，status 反映会话内覆盖；最新裁决在前", async () => {
  const { calls } = await loadHandler({ review: [ALLOW_JSON] });
  await invokeRpc(calls, "mode", { arg: "allow-all", sessionID: "ses_test" });
  await invokeRpc(calls, "model", { arg: "openai/x#y", sessionID: "ses_test" });

  const commands = decisionEvents(calls).filter((item) => item.data.layer === "command");
  assert.equal(commands.length, 2);

  const status = await invokeRpc(calls, "status", {});
  assert.equal(status.mode, "allow-all");
  assert.equal(status.modeSource, "runtime");
  assert.equal(status.chainSource, "runtime");
  assert.match(status.chain, /openai\/x#y/);
  assert.equal(status.decisions.length, 2);
  assert.match(status.decisions[0].summary, /openai\/x#y/); // 最新在前
});

test("环形缓冲上限：只保留最近 12 条", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW_JSON] });
  for (let index = 0; index < 13; index += 1) {
    await handler(baseInput({ resources: ["pwd"] }));
  }
  const status = await invokeRpc(calls, "status", {});
  assert.equal(status.decisions.length, 12);
  assert.equal(decisionEvents(calls).length, 13); // 事件不设上限
});

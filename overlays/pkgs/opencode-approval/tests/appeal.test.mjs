// tests/appeal.test.mjs —— 行政复议（approval_appeal 工具）：
// 注册、无拒绝记录、通过（一次性放行）、连续驳回计数、critical 不通过、链失败不计次、拒绝消息提示。

import assert from "node:assert/strict";
import { test } from "node:test";

import { baseInput, loadHandler } from "./helpers.mjs";

const DENY_JSON = JSON.stringify({ risk_level: "high", outcome: "deny", rationale: "remote write" });
const ALLOW_JSON = JSON.stringify({
  risk_level: "medium",
  outcome: "allow",
  rationale: "user authorized it",
});
const CRITICAL_JSON = JSON.stringify({
  risk_level: "critical",
  outcome: "allow",
  rationale: "should never be granted",
});

const findTool = (calls) => calls.tools.find((tool) => tool.name === "approval_appeal");

test("注册 approval_appeal 工具（JSON Schema 输入 + execute）", async () => {
  const { calls } = await loadHandler({ review: [DENY_JSON] });
  const tool = findTool(calls);
  assert.ok(tool, "approval_appeal 应注册");
  assert.equal(tool.input.type, "object");
  assert.deepEqual(tool.input.required, ["justification"]);
  assert.equal(typeof tool.execute, "function");
});

test("无拒绝记录：给出说明且不调模型", async () => {
  const { calls } = await loadHandler({ review: [ALLOW_JSON] });
  const out = await findTool(calls).execute({ justification: "理由" }, { sessionID: "ses_test" });
  assert.match(out.content, /不存在可复议的拒绝记录/);
  assert.equal(calls.generate.length, 0);
});

test("模型层拒绝：拒绝消息带复议提示；复议通过后返回一次性放行并消费记录", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY_JSON, ALLOW_JSON] });
  const input = baseInput({ action: "write", resources: ["/tmp/out.txt"] });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.match(input.message, /approval_appeal/);
  const out = await findTool(calls).execute(
    { justification: "该动作是用户要求的工作流一部分" },
    { sessionID: "ses_test" },
  );
  assert.match(out.content, /行政复议通过/);
  assert.match(out.content, /一次性放行/);
  const decision = calls.rpc.emitted.filter((item) => item.name === "decision").at(-1).data;
  assert.equal(decision.layer, "appeal");
  assert.equal(decision.effect, "allow");
  // 复议通过后拒绝记录被消费：再次复议提示无记录
  const again = await findTool(calls).execute({ justification: "again" }, { sessionID: "ses_test" });
  assert.match(again.content, /不存在可复议的拒绝记录/);
});

test("连续三次驳回：之后直接失败且不再调模型", async () => {
  const { handler, calls } = await loadHandler({
    review: [DENY_JSON, DENY_JSON, DENY_JSON, DENY_JSON, ALLOW_JSON],
  });
  await handler(baseInput({ action: "write", resources: ["/tmp/out.txt"] }));
  const tool = findTool(calls);
  const first = await tool.execute({ justification: "one" }, { sessionID: "ses_test" });
  assert.match(first.content, /行政复议被驳回（1\/3）/);
  const second = await tool.execute({ justification: "two" }, { sessionID: "ses_test" });
  assert.match(second.content, /行政复议被驳回（2\/3）/);
  const third = await tool.execute({ justification: "three" }, { sessionID: "ses_test" });
  assert.match(third.content, /行政复议失败/);
  const callsBefore = calls.generate.length;
  const fourth = await tool.execute({ justification: "four" }, { sessionID: "ses_test" });
  assert.match(fourth.content, /已失败/);
  assert.equal(calls.generate.length, callsBefore, "失败后不再调模型");
});

test("critical 风险：复议不通过（即使 outcome=allow）", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY_JSON, CRITICAL_JSON] });
  await handler(baseInput({ action: "write", resources: ["/tmp/out.txt"] }));
  const out = await findTool(calls).execute({ justification: "x" }, { sessionID: "ses_test" });
  assert.match(out.content, /行政复议被驳回（1\/3）/);
});

test("复议审查链失败：不计入驳回次数，可重试并成功", async () => {
  const { handler, calls } = await loadHandler({
    review: [DENY_JSON, { error: "boom" }, ALLOW_JSON],
  });
  await handler(baseInput({ action: "write", resources: ["/tmp/out.txt"] }));
  const tool = findTool(calls);
  const failed = await tool.execute({ justification: "a" }, { sessionID: "ses_test" });
  assert.match(failed.content, /未能裁决/);
  assert.match(failed.content, /不计入驳回次数/);
  const retry = await tool.execute({ justification: "b" }, { sessionID: "ses_test" });
  assert.match(retry.content, /行政复议通过/);
});

test("缺少理由：提示补理由（不消耗次数、不调模型）", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY_JSON, ALLOW_JSON] });
  await handler(baseInput({ action: "write", resources: ["/tmp/out.txt"] }));
  const out = await findTool(calls).execute({}, { sessionID: "ses_test" });
  assert.match(out.content, /需要理由/);
  assert.equal(calls.generate.length, 1, "仅原始审查调用过一次模型");
});

test("复议通过后：原动作重试被一次性直接放行（layer=appeal），且仅一次", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY_JSON, ALLOW_JSON, DENY_JSON] });
  const denied = baseInput({ action: "write", resources: ["/tmp/out.txt"] });
  await handler(denied);
  assert.equal(denied.effect, "deny");
  const out = await findTool(calls).execute(
    { justification: "用户已授权" },
    { sessionID: "ses_test" },
  );
  assert.match(out.content, /行政复议通过/);
  const reviewsBefore = calls.generate.length;
  const retry = baseInput({ action: "write", resources: ["/tmp/out.txt"] });
  await handler(retry);
  assert.equal(retry.effect, "allow");
  assert.equal(calls.generate.length, reviewsBefore, "grant 放行不再调模型");
  const decision = calls.rpc.emitted.filter((item) => item.name === "decision").at(-1).data;
  assert.equal(decision.layer, "appeal");
  assert.equal(decision.effect, "allow");
  // 一次性：第二次重试进入模型审查（fixture 3 = DENY）
  const retry2 = baseInput({ action: "write", resources: ["/tmp/out.txt"] });
  await handler(retry2);
  assert.equal(calls.generate.length, reviewsBefore + 1, "grant 已被消费");
});

test("cleanup：释放工具注册", async () => {
  const { calls, cleanup } = await loadHandler({ review: [DENY_JSON] });
  await cleanup();
  assert.equal(calls.toolsDisposed, 1);
});

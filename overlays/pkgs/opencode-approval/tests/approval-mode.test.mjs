// tests/approval-mode.test.mjs —— /approval-mode 指令（RPC 形态：mode）：
// 查看/切换/恢复审批模式（review / ask / allow-all）；且不向会话注入任何消息。

import assert from "node:assert/strict";
import { test } from "node:test";

import { baseInput, invokeRpc, loadHandler } from "./helpers.mjs";

const ALLOW_JSON = JSON.stringify({ risk_level: "low", outcome: "allow", rationale: "fine" });

const invokeMode = (calls, text) => invokeRpc(calls, "mode", { arg: text, sessionID: "ses_test" });

test("模式 RPC 已注册：mode handler 与 JSON Schema 输入输出", async () => {
  const { calls } = await loadHandler({ review: [ALLOW_JSON] });
  assert.equal(typeof calls.rpc.handlers.mode, "function");
  assert.equal(calls.rpc.definition.methods.mode.output.required[0], "text");
});

test("模式状态机：查看（默认 review）→ allow-all → review → default → 非法参数", async () => {
  const { calls } = await loadHandler({ review: [ALLOW_JSON] });
  let result = await invokeMode(calls, "");
  assert.match(result.text, /当前模式：review（模型审查）/);
  assert.match(result.text, /配置默认/);

  result = await invokeMode(calls, "allow-all");
  assert.match(result.text, /已切换为 allow-all/);

  result = await invokeMode(calls, "");
  assert.match(result.text, /当前模式：allow-all（全部允许）/);
  assert.match(result.text, /本节点覆盖/);

  result = await invokeMode(calls, "ask");
  assert.match(result.text, /已切换为 ask/);
  result = await invokeMode(calls, "");
  assert.match(result.text, /当前模式：ask（人工确认，不调模型）/);
  assert.match(result.text, /本节点覆盖/);

  result = await invokeMode(calls, "/approval-mode review");
  assert.match(result.text, /已切换为 review/);

  result = await invokeMode(calls, "/approval-mode default");
  assert.match(result.text, /已恢复配置默认模式：review/);

  result = await invokeMode(calls, "bogus");
  assert.match(result.text, /用法/);
});

test("配置 allowAll:true 作默认：显示配置默认 allow-all，可会话内切回 review", async () => {
  const { calls } = await loadHandler({ options: { allowAll: true }, review: [ALLOW_JSON] });
  let result = await invokeMode(calls, "");
  assert.match(result.text, /当前模式：allow-all（全部允许）/);
  assert.match(result.text, /配置默认/);
  await invokeMode(calls, "review");
  result = await invokeMode(calls, "");
  assert.match(result.text, /当前模式：review（模型审查）/);
  assert.match(result.text, /本节点覆盖/);
});

test("allowAll 配置：非 fastpath 动作直接放行、不调模型", async () => {
  const { handler, calls } = await loadHandler({ options: { allowAll: true }, review: [ALLOW_JSON] });
  const input = baseInput({ resources: ["npm run build"] });
  await handler(input);
  assert.equal(input.effect, "allow");
  assert.equal(calls.generate.length, 0);
});

test("allowAll：灾难性硬拒绝仍生效（不调模型）", async () => {
  const { handler, calls } = await loadHandler({ options: { allowAll: true }, review: [ALLOW_JSON] });
  const input = baseInput({ resources: ["rm -rf /"] });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.match(input.message, /hard rule/);
  assert.equal(calls.generate.length, 0);
});

test("allowAll：静态 deny 仍然优先", async () => {
  const { handler, calls } = await loadHandler({ options: { allowAll: true }, review: [ALLOW_JSON] });
  const input = baseInput({ effect: "deny", resources: ["anything"] });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.equal(calls.generate.length, 0);
});

test("运行时切换：allow-all 即时生效，review 恢复模型审查", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW_JSON] });
  await invokeMode(calls, "allow-all");
  const allowed = baseInput({ resources: ["npm run build"] });
  await handler(allowed);
  assert.equal(allowed.effect, "allow");
  assert.equal(calls.generate.length, 0);
  await invokeMode(calls, "review");
  const reviewed = baseInput({ resources: ["git push origin feature"] });
  await handler(reviewed);
  assert.equal(calls.generate.length, 1);
  assert.equal(reviewed.effect, "allow");
});

test("ask 模式：不调模型、effect 保持 ask、审计 layer=ask；确定性层仍生效", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW_JSON] });
  await invokeMode(calls, "ask");

  const input = baseInput({ resources: ["npm run build"] });
  await handler(input);
  assert.equal(input.effect, "ask");
  assert.equal(calls.generate.length, 0);
  const events = calls.rpc.emitted.filter((item) => item.name === "decision");
  assert.equal(events.at(-1).data.layer, "ask");

  // 灾难性硬拒绝仍生效
  const denied = baseInput({ resources: ["rm -rf /"] });
  await handler(denied);
  assert.equal(denied.effect, "deny");

  // fastpath 只读仍放行
  const read = baseInput({ action: "read", resources: ["/etc/hostname"] });
  await handler(read);
  assert.equal(read.effect, "allow");
});

test('配置 mode:"ask" 作默认：状态反映配置、动作交还用户（不调模型）', async () => {
  const { handler, calls } = await loadHandler({ options: { mode: "ask" }, review: [ALLOW_JSON] });
  const status = await invokeRpc(calls, "status", {});
  assert.equal(status.mode, "ask");
  assert.equal(status.modeSource, "config");

  const input = baseInput({ resources: ["npm run build"] });
  await handler(input);
  assert.equal(input.effect, "ask");
  assert.equal(calls.generate.length, 0);
});

test("模式命令不向会话注入消息（不再调用 session.synthetic）", async () => {
  const { calls } = await loadHandler({ review: [ALLOW_JSON] });
  await invokeMode(calls, "");
  await invokeMode(calls, "allow-all");
  await invokeMode(calls, "default");
  assert.equal(calls.synthetic.length, 0);
});

// 危险载荷仅作 mock 数据，不执行任何命令。
import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";
import { buildActionView } from "../plugin/index.js";
import { baseInput, loadCustom, loadHandler } from "./helpers.mjs";

const verdict = (risk_level = "low", outcome = "allow") =>
  JSON.stringify({ risk_level, outcome, rationale: "mock verdict" });
const ALLOW = verdict();
const DENY = verdict("high", "deny");
const MODEL = { providerID: "mock", id: "review" };
const modelCosts = [{ ...MODEL, cost: [
  { input: 2, output: 4 }, { tier: { size: 1000 }, input: 10, output: 20 },
  { tier: { size: 2000 }, input: 30, output: 40 },
] }];
const snapshot = (patch) => ({ fingerprint: "f".repeat(64), ...write(patch) });
const appeal = (calls) => calls.tools.find((tool) => tool.name === "approval_appeal")
  .execute({ justification: "mock authorization" }, { sessionID: "ses_test" });
const lastDecision = (calls) => calls.rpc.emitted.filter((item) => item.name === "decision").at(-1).data;
const patchPieces = (chunks) => chunks.flatMap((json) => JSON.parse(json).fragments)
  .filter((item) => JSON.stringify(item.path) === '["metadata","patch"]');
const write = (patch) => baseInput({ action: "edit", resources: ["/workspace/x"], metadata: { patch } });
const actionJSON = (prompt) => JSON.parse(prompt.split(/ACTION(?: \(the originally denied action\))?:\n/)[1]);

test("分块保留所有资源及 metadata 未知/装饰名键，不 squeeze 或降权", () => {
  const resources = Array.from({ length: 600 }, (_, i) => `resource-${i}-` + "x".repeat(120));
  const metadata = { description: "d".repeat(8000), message: "m".repeat(8000),
    input: { Patch: "p".repeat(8000), unknown: false }, title: null, files: [] };
  const view = buildActionView({ ...snapshot(""), resources, metadata }, 4000);
  assert.equal(view.elidedCritical, false);
  assert.deepEqual(view.elidedFields, []);
  const values = new Map();
  for (const json of view.chunks) for (const item of JSON.parse(json).fragments) {
    const key = JSON.stringify(item.path);
    if (item.offset === undefined) values.set(key, item.value);
    else {
      const prior = values.get(key) ?? "";
      values.set(key, prior + item.value.slice(prior.length - item.offset));
    }
  }
  resources.forEach((value, index) => assert.equal(values.get(JSON.stringify(["resources", index])), value));
  for (const key of ["description", "message", "title", "files"]) {
    assert.deepEqual(values.get(JSON.stringify(["metadata", key])), metadata[key]);
  }
  assert.equal(values.get('["metadata","input","Patch"]'), metadata.input.Patch);
  assert.equal(values.get('["metadata","input","unknown"]'), false);
  assert.equal(values.size, resources.length + 6);
});

test("README 说明 60k 预算、分块严格聚合、压缩告知与失败记账", () => {
  const readme = fs.readFileSync(new URL("../README.md", import.meta.url), "utf8");
  assert.match(readme, /`reviewViewLimit`.*`60000`/);
  assert.match(readme, /全块 allow 才放行/);
  assert.match(readme, /重叠 256 字符/);
  assert.match(readme, /COMPRESSION NOTICE/);
  assert.match(readme, /不转 fallback、不重试/);
  assert.match(readme, /成功或整链失败，都累计/);
});

test("畸形 diff/未知 patch 不剥离上下文，分块仍覆盖全文", () => {
  for (const patch of ["@@ -1,999 +1,999 @@\n", "not a diff\n"].map((head) =>
    head + " context\n".repeat(800) + "+last")) {
    const view = buildActionView(snapshot(patch), 4000);
    assert.equal(view.contextLinesRemoved, 0);
    let restored = "";
    for (const piece of patchPieces(view.chunks)) {
      restored += piece.value.slice(restored.length - piece.offset);
    }
    assert.equal(restored, patch);
  }
});

test("unified diff 只剥完整 hunk 上下文，文件/hunk 头及增删全文保留", () => {
  const headers = "--- a/x\n+++ b/x\n@@ -1,101 +1,101 @@ section\n";
  const changed = "-old\n+new\n";
  const patch = headers + (" " + "context".repeat(10) + "\n").repeat(100) + changed;
  assert.equal(JSON.parse(buildActionView(snapshot(patch)).json).metadata.patch, patch);
  const view = buildActionView(snapshot(patch), 4000);
  assert.equal(view.elidedCritical, false);
  assert.equal(view.contextLinesRemoved, 100);
  assert.equal(JSON.parse(view.json).metadata.patch, headers + changed);
  assert.match(view.compressionNotice, /已剥离 100 行上下文/);
});

test("阶梯价：小输入用基础档，到阈值才换档", async () => {
  for (const [tokens, price] of [[10, 2], [999, 2], [1000, 10], [1999, 10], [2000, 30]]) {
    const { handler, calls } = await loadHandler({
      options: { reviewModel: MODEL }, modelCosts, review: [ALLOW],
      reviewUsage: { prompt_tokens: tokens, completion_tokens: 0 },
    });
    await handler(write("safe"));
    assert.equal(lastDecision(calls).cost_usd, tokens * price / 1_000_000);
  }
});

for (const chunked of [false, true]) for (const reconsider of [false, true]) {
  test(`失败记账：分块=${chunked} 复议=${reconsider}`, async () => {
    const review = [...(reconsider ? [DENY] : []), ...(chunked ? [ALLOW] : []), "invalid"];
    const { handler, calls, ctx } = await loadCustom({ review, modelCosts,
      reviewUsage: { prompt_tokens: 10, completion_tokens: 2 },
      options: { reviewModel: MODEL, fallbackModels: [MODEL], reviewViewLimit: 4000 },
    });
    await handler(write("x".repeat(chunked ? 9000 : 9)));
    if (reconsider) assert.match((await appeal(calls)).content, /不计入驳回次数/);
    const event = lastDecision(calls);
    assert.equal(event.effect, "deny");
    assert.equal(event.input_tokens, 20);
    assert.equal(event.output_tokens, 4);
    assert.ok(Math.abs(event.cost_usd - 0.000056) < 1e-12);
    const audit = fs.readFileSync(ctx.options.auditPath, "utf8").trim().split("\n").map(JSON.parse).at(-1);
    assert.equal(audit.input_tokens, 20);
    assert.equal(audit.output_tokens, 4);
    assert.equal(audit.cost_usd, event.cost_usd);
  });
}

for (const reply of [DENY, verdict("critical"), { error: "mock chunk failure" }]) {
  test(`复议后块 ${JSON.stringify(reply)} 不签发 grant`, async () => {
    const { handler, calls } = await loadHandler({ options: { reviewViewLimit: 4000 },
      review: [DENY, ALLOW, reply, DENY],
    });
    await handler(write("x".repeat(9000)));
    assert.doesNotMatch((await appeal(calls)).content, /行政复议通过/);
    assert.equal(calls.generate.length, 3);
    const retry = write("x".repeat(9000));
    await handler(retry);
    assert.equal(retry.effect, "deny");
    assert.equal(calls.generate.length, 4);
  });
}

test("复议全块 allow 才签发一次性 grant", async () => {
  const input = write("x".repeat(9000));
  const count = buildActionView(snapshot(input.metadata.patch), 4000).chunks.length;
  const { handler, calls } = await loadHandler({
    options: { reviewViewLimit: 4000 }, review: [DENY, ALLOW],
  });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.match((await appeal(calls)).content, /行政复议通过/);
  assert.equal(calls.generate.length, count + 1);
  assert.ok(calls.generate.slice(1).every(({ prompt }) => prompt.startsWith("You are the appeal reviewer")));
  const retry = write(input.metadata.patch);
  await handler(retry);
  assert.equal(retry.effect, "allow");
  assert.equal(calls.generate.length, count + 1);
});

test("分块超时立即 deny，不自动重试或换模型", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 1000 });
  const { handler, calls, cleanup } = await loadHandler({ review: [ALLOW],
    options: { includeContext: false, reviewViewLimit: 4000, deadlineMs: 100,
      attemptTimeoutMs: 100, onFailure: "ask" },
    onGenerate: ({ calls }) => calls.generate.length === 2 ? new Promise(() => {}) : undefined,
  });
  t.after(cleanup);
  const input = write("x".repeat(9000));
  const pending = handler(input);
  await new Promise((resolve) => setImmediate(resolve));
  t.mock.timers.tick(100);
  await pending;
  assert.equal(input.effect, "deny");
  assert.equal(calls.generate.length, 2);
  assert.equal(calls.sessionsAlive.size, 0);
});

test("预算连结构/重叠都容不下时零模型调用且强制 deny", async () => {
  for (const limit of [1, 200, 300]) {
    const view = buildActionView(snapshot("x".repeat(9000)), limit);
    assert.equal(view.elidedCritical, true);
    assert.deepEqual(view.chunks, []);
    const { handler, calls } = await loadHandler({
      options: { reviewViewLimit: limit, onFailure: "ask" }, review: [ALLOW],
    });
    const input = write("x".repeat(9000));
    await handler(input);
    assert.equal(input.effect, "deny");
    assert.equal(calls.generate.length, 0);
  }
});

test("reviewViewLimit 配置改变分块数，每块含全部字段归属", async () => {
  for (const limit of [4000, 60_000]) {
    const { handler, calls } = await loadHandler({
      options: { reviewViewLimit: limit }, review: [ALLOW],
    });
    const input = write("x".repeat(9000));
    await handler(input);
    assert.equal(input.effect, "allow");
    assert.equal(calls.generate.length, buildActionView(snapshot(input.metadata.patch), limit).chunks.length);
    assert.ok(calls.generate.every(({ prompt }) => JSON.stringify(actionJSON(prompt)).length <= limit));
  }
});

for (const [label, reply] of [["deny", DENY], ["critical allow", verdict("critical")],
  ["解析失败", "invalid"], ["请求失败", { error: "mock failure" }]]) {
  test(`分块 ${label} 短路拒绝，不能被后块或 fallback 放行`, async () => {
    const { handler, calls } = await loadHandler({ review: [ALLOW, reply, ALLOW],
      options: { reviewViewLimit: 4000, onFailure: "ask",
        fallbackModels: [{ providerID: "mock", id: "fallback" }] },
    });
    const input = write("x".repeat(20_000));
    await handler(input);
    assert.equal(input.effect, "deny");
    assert.equal(calls.generate.length, 2);
    assert.equal(calls.sessionsAlive.size, 0);
  });
}

test("恶意模式跨第一块边界拆分，256 重叠使后块完整可见并拒绝", async () => {
  const marker = "MOCK_CROSS_BOUNDARY_FORBIDDEN";
  const plain = "x".repeat(130_000);
  const first = patchPieces(buildActionView(snapshot(plain)).chunks)[0];
  const start = first.value.length - 12;
  const patch = plain.slice(0, start) + marker + plain.slice(start + marker.length);
  const review = [];
  const { handler, calls } = await loadHandler({ review,
    onGenerate: ({ prompt }) => { review.push(prompt.includes(marker) ? DENY : ALLOW); },
  });
  const input = write(patch);
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.equal(calls.generate.length, 2);
  const firstValue = patchPieces([JSON.stringify(actionJSON(calls.generate[0].prompt))])[0].value;
  assert.equal(firstValue.slice(-12), marker.slice(0, 12));
  assert.ok(!firstValue.includes(marker), "首块只能看到半个模式");
  assert.ok(calls.generate[1].prompt.includes(marker), "重叠块包含完整模式");
});

test("恶意载荷在最后一块仍拒绝（模型按实际可见载荷判定）", async () => {
  const marker = "MOCK_FORBIDDEN_PAYLOAD";
  const input = write("x".repeat(130_000) + marker);
  const review = [];
  const { handler, calls } = await loadHandler({ review,
    onGenerate: ({ prompt }) => { review.push(prompt.includes(marker) ? DENY : ALLOW); },
  });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.equal(calls.generate.length, buildActionView(snapshot(input.metadata.patch)).chunks.length);
  assert.ok(!calls.generate[0].prompt.includes(marker));
  assert.ok(calls.generate.at(-1).prompt.includes(marker));
});

test("所有块 allow 才放行，风险取最大，usage 按块累计", async () => {
  const input = write("x".repeat(130_000));
  const count = buildActionView(snapshot(input.metadata.patch)).chunks.length;
  const { handler, calls, ctx } = await loadCustom({
    review: [ALLOW, verdict("high"), verdict("medium")],
    reviewUsage: { prompt_tokens: 10, completion_tokens: 2 },
  });
  await handler(input);
  assert.equal(input.effect, "allow");
  assert.equal(calls.generate.length, count);
  const audit = fs.readFileSync(ctx.options.auditPath, "utf8").trim().split("\n").map(JSON.parse).at(-1);
  assert.equal(audit.risk_level, "high");
  for (const [index, { prompt }] of calls.generate.entries()) {
    assert.ok(prompt.includes(`第 ${index + 1}/${count} 块，共 ${count} 块`));
    assert.ok(JSON.stringify(actionJSON(prompt)).length <= 60_000);
  }
  assert.equal(lastDecision(calls).input_tokens, count * 10);
  assert.equal(lastDecision(calls).output_tokens, count * 2);
});

test("分块覆盖转义、Unicode 全文且连续重叠 256 字符", () => {
  const patch = '文😀\\"\n'.repeat(16000);
  const view = buildActionView(snapshot(patch), 4000);
  assert.equal(view.elidedCritical, false);
  assert.ok(view.chunks.length > 2);
  assert.ok(view.chunks.every((json) => json.length <= 4000));
  let end = 0;
  for (const piece of patchPieces(view.chunks)) {
    assert.equal(piece.offset, end ? end - 256 : 0);
    assert.equal(piece.value, patch.slice(piece.offset, piece.offset + piece.value.length));
    assert.equal(piece.total, patch.length);
    end = piece.offset + piece.value.length;
  }
  assert.equal(end, patch.length);
});

test("30k 良性 patch 全文优先于装饰 message，单次审查放行", async () => {
  const patch = "+safe\n".repeat(5000);
  const input = { ...write(patch), message: "m".repeat(80_000) };
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  await handler(input);
  assert.equal(input.effect, "allow");
  assert.equal(calls.generate.length, 1);
  const action = actionJSON(calls.generate[0].prompt);
  assert.equal(action.metadata.patch, patch);
  assert.match(action.message, /^m{80}\n\[truncated\][\s\S]*\nm{80}$/);
  assert.match(calls.generate[0].prompt, /COMPRESSION NOTICE: Only decorative/);
});

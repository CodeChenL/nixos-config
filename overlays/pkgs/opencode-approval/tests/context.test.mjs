// tests/context.test.mjs —— 会话上下文摘要（buildContextDigest）与获取/缓存/降级行为。

import assert from "node:assert/strict";
import { test } from "node:test";

import { buildContextDigest } from "../plugin/index.js";
import { baseInput, loadHandler } from "./helpers.mjs";

const ALLOW_JSON = JSON.stringify({ risk_level: "low", outcome: "allow", rationale: "fine" });

const userMsg = (text) => ({ type: "user", id: "m1", time: { created: 1 }, text });
const assistantMsg = (parts) => ({
  type: "assistant",
  id: "a1",
  time: { created: 2 },
  agent: "build",
  model: {},
  content: parts,
});

test("buildContextDigest：过滤消息类型、提取文本与工具名", () => {
  const digest = buildContextDigest([
    userMsg("修复 TUI 加载失败"),
    assistantMsg([
      { type: "text", text: "我先检查配置" },
      { type: "tool", name: "bash" },
      { type: "tool", name: "bash" },
      { type: "tool", name: "read" },
    ]),
    { type: "system", text: "ignored" },
    { type: "synthetic", text: "ignored" },
  ]);
  assert.equal(
    digest,
    "[user] 修复 TUI 加载失败\n[assistant] 我先检查配置 (tools: bash, read)",
  );
});

test("buildContextDigest：无有效消息返回 null", () => {
  assert.equal(buildContextDigest([]), null);
  assert.equal(buildContextDigest([{ type: "system", text: "x" }]), null);
  assert.equal(buildContextDigest(null), null);
});

test("buildContextDigest：保留最近 maxMessages 条，用户消息额外保留至 userBudget", () => {
  const messages = [];
  for (let i = 0; i < 20; i++) messages.push(userMsg(`msg-${i}`));
  const digest = buildContextDigest(messages, { maxMessages: 3 });
  // 最近 3 条 + 额外保留更早的用户消息（userBudget 默认 6）
  assert.ok(digest.includes("msg-19"));
  assert.ok(digest.includes("msg-17"));
  assert.ok(digest.includes("msg-14"), "更早的用户消息被额外保留（授权证据）");
  assert.ok(!digest.includes("msg-13"), "超出 userBudget 的更早消息不再保留");
  const budgeted = buildContextDigest(messages, { maxMessages: 3, userBudget: 3 });
  assert.ok(budgeted.includes("msg-17"));
  assert.ok(!budgeted.includes("msg-16"), "userBudget 收紧后不再额外保留");
  const clipped = buildContextDigest(messages, { maxMessages: 20, maxChars: 30 });
  assert.equal(clipped.length, 30);
  assert.ok(clipped.endsWith("msg-19"));
});

test("buildContextDigest：question 工具作答计入用户输入证据", () => {
  const messages = [
    { type: "user", text: "帮我配置一下" },
    {
      type: "assistant",
      content: [
        { type: "text", text: "好的，先确认几个选项" },
        {
          type: "tool",
          name: "question",
          state: { status: "completed", metadata: { answers: [["允许沙箱验证"], ["选项B"]] } },
        },
      ],
    },
  ];
  const digest = buildContextDigest(messages);
  assert.ok(digest.includes("[user via question] 允许沙箱验证; 选项B"));
});

test("buildContextDigest：question 未完成不产生证据；content 文本可作兜底", () => {
  const pending = buildContextDigest([
    {
      type: "assistant",
      content: [{ type: "tool", name: "question", state: { status: "running" } }],
    },
  ]);
  assert.ok(pending === null || !pending.includes("[user via question]"));
  const fallback = buildContextDigest([
    {
      type: "assistant",
      content: [
        {
          type: "tool",
          name: "question",
          state: {
            status: "completed",
            content: [{ type: "text", text: "User has answered your questions: \"q\"=\"A\"." }],
          },
        },
      ],
    },
  ]);
  assert.ok(fallback.includes("[user via question] User has answered your questions"));
});

test("buildContextDigest：单条消息截断", () => {
  const digest = buildContextDigest([userMsg("x".repeat(1000))], { perMessageChars: 50 });
  assert.ok(digest.length <= "[user] ".length + 50);
  assert.ok(digest.endsWith("…"));
});

test("会话上下文：TTL 缓存——同一会话短时间两次裁决只取一次", async () => {
  const { handler, calls } = await loadHandler({
    review: [ALLOW_JSON],
    sessionMessages: { ses_test: [userMsg("hello")] },
  });
  await handler(baseInput({ resources: ["git push origin a"] }));
  await handler(baseInput({ resources: ["git push origin b"] }));
  assert.equal(calls.sessionContext.length, 1);
  assert.equal(calls.generate.length, 2);
});

test("includeContext:false 时不取上下文", async () => {
  const { handler, calls } = await loadHandler({
    options: { includeContext: false },
    review: [ALLOW_JSON],
    sessionMessages: { ses_test: [userMsg("hello")] },
  });
  await handler(baseInput({ resources: ["git push origin a"] }));
  assert.equal(calls.sessionContext.length, 0);
  assert.equal(calls.sessionGet.length, 0);
  assert.equal(calls.generate.length, 1);
});

test("上下文获取失败：降级为无上下文，审查照常进行且不触发熔断", async () => {
  const { handler, calls } = await loadHandler({
    review: [ALLOW_JSON],
    contextError: new Error("session store down"),
  });
  for (let i = 0; i < 3; i++) {
    const input = baseInput({ resources: [`git push origin r${i}`] });
    await handler(input);
    assert.equal(input.effect, "allow");
  }
  assert.equal(calls.generate.length, 3, "context failures must not trip the breaker");
});

test("子代理会话无用户消息时回退父会话上下文", async () => {
  const { handler, calls } = await loadHandler({
    review: [ALLOW_JSON],
    sessionMessages: {
      ses_child: [assistantMsg([{ type: "text", text: "working" }])],
      ses_parent: [userMsg("请完成整个迁移")],
    },
    sessionParents: { ses_child: "ses_parent" },
  });
  await handler(baseInput({ sessionID: "ses_child", resources: ["git push origin a"] }));
  assert.ok(calls.sessionGet.includes("ses_child"));
  assert.ok(calls.sessionContext.includes("ses_parent"));
});

test("prompt 包含 CONVERSATION CONTEXT 与 digest 文本", async () => {
  const { handler, calls } = await loadHandler({
    review: [ALLOW_JSON],
    sessionMessages: { ses_test: [userMsg("请修复 TUI 侧边栏加载失败的问题")] },
  });
  await handler(baseInput({ resources: ["git push origin feature"] }));
  const prompt = calls.generate[0].prompt;
  assert.ok(prompt.includes("CONVERSATION CONTEXT"));
  assert.ok(prompt.includes("请修复 TUI 侧边栏加载失败的问题"));
  assert.ok(prompt.includes('"user_authorization"'));
});

test("无上下文时 prompt 标注 no conversation context available", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW_JSON] });
  await handler(baseInput({ resources: ["git push origin feature"] }));
  assert.ok(calls.generate[0].prompt.includes("(no conversation context available)"));
});

test("父会话回退的 digest 内容进入 prompt", async () => {
  const { handler, calls } = await loadHandler({
    review: [ALLOW_JSON],
    sessionMessages: {
      ses_child: [assistantMsg([{ type: "text", text: "working" }])],
      ses_parent: [userMsg("请完成整个迁移")],
    },
    sessionParents: { ses_child: "ses_parent" },
  });
  await handler(baseInput({ sessionID: "ses_child", resources: ["git push origin feature"] }));
  const prompt = calls.generate[0].prompt;
  assert.ok(prompt.includes("请完成整个迁移"));
  assert.ok(prompt.includes("parent session"));
});

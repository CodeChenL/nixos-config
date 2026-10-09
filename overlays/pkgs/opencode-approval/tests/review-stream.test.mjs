// tests/review-stream.test.mjs —— 审查调用的流式观测（会话 http.response 钩子）：
// usage 解析、响应流透传/无输出超时、内部会话与钩子注册。

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  createHttpResponseHandler,
  createReviewResponseStream,
  parseUsageFromText,
} from "../plugin/index.js";
import { loadHandler } from "./helpers.mjs";

const ALLOW_JSON = JSON.stringify({ risk_level: "low", outcome: "allow", rationale: "fine" });

test("parseUsageFromText：OpenAI / Anthropic 风格与容错", () => {
  assert.deepEqual(parseUsageFromText('data: {"usage":{"prompt_tokens":120,"completion_tokens":30}}'), {
    inputTokens: 120,
    outputTokens: 30,
  });
  assert.deepEqual(parseUsageFromText('data: {"usage":{"input_tokens":7,"output_tokens":9}}'), {
    inputTokens: 7,
    outputTokens: 9,
  });
  // 分片出现时取各字段最大值（Anthropic message_start / message_delta）
  assert.deepEqual(parseUsageFromText('{"usage":{"input_tokens":100}} ... {"usage":{"output_tokens":20}}'), {
    inputTokens: 100,
    outputTokens: 20,
  });
  // 嵌套 details 不破坏括号配对
  assert.deepEqual(
    parseUsageFromText(
      '{"usage":{"prompt_tokens":12,"completion_tokens":3,"prompt_tokens_details":{"cached_tokens":2}}}',
    ),
    { inputTokens: 12, outputTokens: 3 },
  );
  assert.equal(parseUsageFromText("no usage here"), null);
  assert.equal(parseUsageFromText(""), null);
});

test("createReviewResponseStream：透传字节并解析 usage", async () => {
  const raw =
    'data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: {"usage":{"prompt_tokens":120,"completion_tokens":30}}\n\ndata: [DONE]\n\n';
  const source = new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode(raw));
      controller.close();
    },
  });
  const captured = [];
  const reader = createReviewResponseStream(source, 1000, (usage) => captured.push(usage)).getReader();
  let bytes = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    bytes += value.length;
  }
  assert.ok(bytes > 0, "字节应原样透传");
  assert.deepEqual(captured, [{ inputTokens: 120, outputTokens: 30 }]);
});

test("createReviewResponseStream：无输出超时中断流（间隔而非总时长）", async () => {
  let cancelled = false;
  const source = new ReadableStream({
    cancel() {
      cancelled = true;
    },
  });
  const reader = createReviewResponseStream(source, 60, () => {}).getReader();
  await assert.rejects(async () => {
    for (;;) {
      const { done } = await reader.read();
      if (done) break;
    }
  }, /idle timeout/);
  assert.equal(cancelled, true);
});

test("createReviewResponseStream：持续有输出不受空闲超时影响", async () => {
  let emitted = 0;
  const source = new ReadableStream({
    async pull(controller) {
      if (emitted >= 4) return;
      await new Promise((resolve) => setTimeout(resolve, 25));
      emitted += 1;
      controller.enqueue(new TextEncoder().encode("x"));
      if (emitted === 4) controller.close();
    },
  });
  const reader = createReviewResponseStream(source, 80, () => {}).getReader();
  let count = 0;
  for (;;) {
    const { done } = await reader.read();
    if (done) break;
    count += 1;
  }
  assert.equal(count, 4);
});

test("createReviewResponseStream：流被提前取消也能捕获已出现的 usage（增量解析）", async () => {
  const captured = [];
  const source = new ReadableStream({
    start(controller) {
      controller.enqueue(
        new TextEncoder().encode('data: {"usage":{"prompt_tokens":10,"completion_tokens":2}}\n\n'),
      );
      // 不 close：模拟传输层读到 [DONE] 后取消底层流
    },
  });
  const reader = createReviewResponseStream(source, 1000, (usage) => captured.push(usage)).getReader();
  const first = await reader.read();
  assert.ok(first.value, "首个 chunk 应透传");
  await reader.cancel();
  assert.deepEqual(captured, [{ inputTokens: 10, outputTokens: 2 }]);
});

test("createHttpResponseHandler：仅内部审查会话的 generate 响应被包装", async () => {
  const usage = { inputTokens: 0, outputTokens: 0 };
  const handler = createHttpResponseHandler({
    getSessionID: () => "ses_internal",
    getInFlight: () => usage,
    idleTimeoutMs: 60,
  });
  // 非 generate（聊天主请求）→ 原样
  const chat = { kind: "primary", sessionID: "ses_internal", response: new Response("x") };
  const chatResponse = chat.response;
  handler(chat);
  assert.equal(chat.response, chatResponse);
  // 其他会话 → 原样
  const other = { kind: "generate", sessionID: "ses_other", response: new Response("x") };
  const otherResponse = other.response;
  handler(other);
  assert.equal(other.response, otherResponse);
  // 无在途审查 → 原样
  const idleHandler = createHttpResponseHandler({
    getSessionID: () => "ses_internal",
    getInFlight: () => null,
    idleTimeoutMs: 60,
  });
  const idle = { kind: "generate", sessionID: "ses_internal", response: new Response("x") };
  const idleResponse = idle.response;
  idleHandler(idle);
  assert.equal(idle.response, idleResponse);
  // 内部 generate → 替换响应；消费后 usage 累计
  const event = {
    kind: "generate",
    sessionID: "ses_internal",
    response: new Response('data: {"usage":{"prompt_tokens":120,"completion_tokens":30}}\n\n'),
  };
  const original = event.response;
  handler(event);
  assert.notEqual(event.response, original);
  for await (const _chunk of event.response.body) {
    // drain
  }
  assert.deepEqual(usage, { inputTokens: 120, outputTokens: 30 });
});

test("setup：为审查链 provider 注册 http.response 钩子；链变更后重注册", async () => {
  const { calls, cleanup } = await loadHandler({ review: [ALLOW_JSON] });
  assert.equal(calls.sessionHooks.length, 1);
  assert.equal(calls.sessionHooks[0].name, "http.response");
  assert.deepEqual(calls.sessionHooks[0].options, { providerID: "xiaomi-token-plan-cn" });
  // 运行时切换到多 provider 链 → 旧注册清理、按新链注册
  await calls.rpc.handlers.model({ arg: "openai/x deepseek/y", sessionID: "ses_test" });
  assert.equal(calls.sessionHooksDisposed, 1);
  assert.equal(calls.sessionHooks.length, 3, "1 个旧注册 + 2 个新 provider 注册");
  await cleanup();
  assert.equal(calls.sessionHooksDisposed, 3, "cleanup 释放全部钩子注册");
});

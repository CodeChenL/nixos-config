// 0.7.7：审查预算、deadline 有界重试与工作区提示词。所有模型/动作均 mock，不执行命令。
import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";

import { buildAppealPrompt, buildReviewPrompt } from "../plugin/index.js";
import { baseInput, deferred, loadCustom } from "./helpers.mjs";

const PRIMARY = { providerID: "test", id: "primary" };
const FALLBACK = { providerID: "test", id: "fallback" };
const ALLOW = JSON.stringify({ outcome: "allow", risk_level: "medium", rationale: "task artifact" });
const DENY = JSON.stringify({ outcome: "deny", risk_level: "high", rationale: "explicit user scope" });
const HANG = () => new Promise(() => {});
const input = () => baseInput({ action: "edit", resources: ["/tmp/opencode/pvr-resume-20261005/TASKS.md"] });
const flush = () => new Promise((resolve) => setImmediate(resolve));
const advance = async (t, ms) => { t.mock.timers.tick(ms); await flush(); };
const decision = (calls) => calls.rpc.emitted.filter((event) => event.name === "decision").at(-1).data;
const appeal = (calls) => calls.tools.find((tool) => tool.name === "approval_appeal")
  .execute({ justification: "原拒绝误读了用户任务范围" }, { sessionID: "ses_test" });
const user = (text) => ({ type: "user", text });

async function setup(t, fixture = {}, configure) {
  // 虚拟时钟精确推进生产的 timeout/Date.now，不依赖机器负载或真实等待 45/90 秒。
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 1_000 });
  const loaded = await loadCustom({
    review: [ALLOW],
    ...fixture,
    options: { includeContext: false, reviewModel: PRIMARY, ...fixture.options },
  }, configure);
  t.after(loaded.cleanup);
  return loaded;
}

for (const [deadlineMs, cap] of [[120_000, 45_000], [200, 100]]) {
  test(`默认单次预算 min(45s, deadline/2)：deadline=${deadlineMs}，主模型挂起后 fallback 放行`, async (t) => {
    const { handler, calls } = await setup(t, {
      options: { deadlineMs, fallbackModels: [FALLBACK] },
      onGenerate: ({ model }) => model.id === PRIMARY.id ? HANG() : undefined,
    });
    const action = input();
    const pending = handler(action);
    await flush();
    await advance(t, cap - 1);
    assert.equal(calls.generate.length, 1);
    await advance(t, 1);
    assert.equal(calls.generate.length, 2);
    await pending;
    assert.equal(action.effect, "allow");
    assert.equal(decision(calls).review_model, "test/fallback");
    assert.equal(calls.sessionInterrupt.length, 1);
    assert.equal(calls.sessionsAlive.size, 0);
  });
}

for (const stage of ["create", "switchModel", "generate", "global"]) {
  test(`attemptTimeoutMs 覆盖 ${stage}：超限转 fallback，不等待整链截止`, async (t) => {
    let invoked = 0;
    const { handler, calls } = await setup(t, {
      options: { deadlineMs: 1_000, attemptTimeoutMs: 100, fallbackModels: [FALLBACK] },
      sessionCreateError: stage === "global",
    }, (ctx) => {
      const object = stage === "global" ? ctx.generate : ctx.session;
      const method = stage === "global" ? "text" : stage;
      const original = object[method];
      object[method] = (...args) => ++invoked === 1 ? HANG() : original(...args);
    });
    const action = input();
    const pending = handler(action);
    await flush();
    await advance(t, 100);
    assert.equal(invoked, 2);
    await pending;
    assert.equal(action.effect, "allow");
    assert.equal(decision(calls).review_model, "test/fallback");
    assert.equal(calls.sessionsAlive.size, 0);
  });
}

test("建会话/切模型/生成共用一次 attempt 预算，不逐步重置", async (t) => {
  const { handler, calls } = await setup(t, {
    options: { deadlineMs: 1_000, attemptTimeoutMs: 100, fallbackModels: [FALLBACK] },
    onGenerate: ({ model }) => model.id === PRIMARY.id ? HANG() : undefined,
  }, (ctx) => {
    for (const method of ["create", "switchModel"]) {
      const original = ctx.session[method];
      let first = true;
      ctx.session[method] = async (...args) => {
        if (first) {
          first = false;
          await new Promise((resolve) => setTimeout(resolve, 40));
        }
        return original(...args);
      };
    }
  });
  const action = input();
  const pending = handler(action);
  await flush();
  await advance(t, 40);
  await advance(t, 40);
  assert.equal(calls.generate.length, 1);
  await advance(t, 19);
  assert.equal(calls.generate.length, 1);
  await advance(t, 1);
  assert.equal(calls.generate.length, 2, "t=100 即 fallback，不给 generate 新的 100ms");
  await pending;
  assert.equal(action.effect, "allow");
});

test("超时建会话迟到成功：立即清理，不生成、不污染 fallback 身份", async (t) => {
  const late = deferred();
  let creations = 0;
  const { handler, calls } = await setup(t, {
    options: { deadlineMs: 1_000, attemptTimeoutMs: 100, fallbackModels: [FALLBACK] },
  }, (ctx) => {
    const original = ctx.session.create;
    ctx.session.create = async (...args) => {
      if (++creations === 1) await late.promise;
      return original(...args);
    };
  });
  const action = input();
  const pending = handler(action);
  await flush();
  await advance(t, 100);
  assert.equal(creations, 2);
  await pending;
  late.resolve();
  await flush();
  assert.equal(action.effect, "allow");
  assert.equal(calls.generate.length, 1);
  assert.equal(decision(calls).review_model, "test/fallback");
  assert.equal(calls.sessionCreate.length, 2);
  assert.equal(calls.sessionRemove.length, 2);
  assert.equal(calls.sessionsAlive.size, 0);
});

test("首次整链 deadline 后以全新预算从 primary 重试成功，usage 合计且迟到响应隔离", async (t) => {
  let firstSession;
  const { handler, calls } = await setup(t, {
    options: { deadlineMs: 100, attemptTimeoutMs: 50, fallbackModels: [FALLBACK], breakerFailures: 1 },
    onGenerate: async ({ model, sessionID, calls }) => {
      const n = calls.generate.length;
      firstSession ??= sessionID;
      await calls.fireUsage(model, sessionID, { prompt_tokens: n * 10, completion_tokens: n });
      if (n <= 2) return HANG();
      await calls.fireUsage(PRIMARY, firstSession, { prompt_tokens: 900_000, completion_tokens: 900_000 });
    },
  });
  const action = input();
  const pending = handler(action);
  await flush();
  await advance(t, 50);
  assert.equal(calls.generate.length, 2);
  await advance(t, 50);
  assert.equal(calls.generate.length, 3);
  await pending;
  assert.equal(action.effect, "allow");
  assert.deepEqual(calls.generate.map(({ model }) => model.id), ["primary", "fallback", "primary"]);
  assert.equal(decision(calls).review_model, "test/primary");
  assert.equal(decision(calls).input_tokens, 60);
  assert.equal(decision(calls).output_tokens, 6);
  assert.equal(calls.rpc.emitted.filter((event) => event.name === "decision").length, 1);
  assert.equal(calls.sessionRemove.length, 3);
  const next = input();
  await handler(next);
  assert.equal(next.effect, "allow", "恢复成功不触发熔断");
});

for (const onFailure of ["deny", "ask"]) {
  test(`两轮整链均超时：有界结束、onFailure=${onFailure}、一次审批仅计一次失败`, async (t) => {
    const { handler, calls } = await setup(t, {
      options: { deadlineMs: 100, attemptTimeoutMs: 1_000, onFailure, breakerFailures: 2 },
      onGenerate: HANG,
    });
    for (let request = 0; request < 2; request += 1) {
      const action = input();
      const pending = handler(action);
      await flush();
      assert.equal(calls.generate.length, request * 2 + 1);
      await advance(t, 100);
      assert.equal(calls.generate.length, request * 2 + 2);
      await advance(t, 100);
      await pending;
      assert.equal(action.effect, onFailure);
      assert.match(action.message, /review deadline exceeded/);
    }
    const blocked = input();
    await handler(blocked);
    assert.equal(calls.generate.length, 4, "没有第三轮；两次审批失败后熔断");
    assert.match(blocked.message, /circuit breaker/);
    assert.equal(calls.sessionsAlive.size, 0);
  });
}

for (const [name, response] of [
  ["模型明确 deny", DENY],
  ["模型 critical/allow", JSON.stringify({ outcome: "allow", risk_level: "critical" })],
  ["模型非法输出", "review deadline exceeded {invalid JSON}"],
  ["供应商同名错误", { error: "review deadline exceeded" }],
  ["普通供应商错误", { error: "provider unavailable" }],
  ["idle 超时", { error: "model review idle timed out" }],
]) {
  test(`${name} 不触发整链自动重试`, async (t) => {
    const { handler, calls } = await setup(t, {
      options: { deadlineMs: 100 }, review: [response, ALLOW],
    });
    const action = input();
    await handler(action);
    await advance(t, 200);
    assert.equal(action.effect, "deny");
    assert.equal(calls.generate.length, 1);
  });
}

test("单模型 attempt 超时但整链预算未耗尽，不触发 deadline 重试", async (t) => {
  const { handler, calls } = await setup(t, {
    options: { deadlineMs: 1_000, attemptTimeoutMs: 100 }, onGenerate: HANG,
  });
  const action = input();
  const pending = handler(action);
  await flush();
  await advance(t, 100);
  assert.equal(calls.sessionInterrupt.length, 1, "t=100 已弃置尝试，不继续等整链截止");
  await pending;
  assert.equal(action.effect, "deny");
  assert.match(action.message, /review attempt timed out/);
  assert.equal(calls.generate.length, 1);
});

test("上下文准备耗尽 deadline 后重新准备，成功才审查；不复用空 prompt", async (t) => {
  let contexts = 0;
  const { handler, calls } = await setup(t, {
    options: { includeContext: true, deadlineMs: 100 },
    sessionMessages: { ses_test: [user("write only to perf-docs/")] },
  }, (ctx) => {
    const original = ctx.session.context;
    ctx.session.context = (...args) => ++contexts === 1 ? HANG() : original(...args);
  });
  const action = input();
  const pending = handler(action);
  await flush();
  assert.equal(calls.generate.length, 0);
  await advance(t, 100);
  assert.equal(contexts, 2);
  await pending;
  assert.equal(action.effect, "allow");
  assert.equal(calls.generate.length, 1);
  assert.match(calls.generate[0].prompt, /\[user\].*write only to perf-docs\//);
});

test("重试重新获取最新用户约束；范围拒绝不重试成 allow", async (t) => {
  const messages = { ses_test: [user("update task artifacts")] };
  const { handler, calls } = await setup(t, {
    options: { includeContext: true, deadlineMs: 100, attemptTimeoutMs: 100 },
    sessionMessages: messages,
    review: [DENY, ALLOW],
    onGenerate: ({ calls }) => calls.generate.length === 1 ? HANG() : undefined,
  });
  const action = input();
  const pending = handler(action);
  await flush();
  messages.ses_test.push(user("r15 write root = perf-docs/; do not execute ssh perf events"));
  await advance(t, 100);
  assert.equal(calls.generate.length, 2);
  await pending;
  assert.match(calls.generate[1].prompt, /\[user\].*r15 write root = perf-docs\/; do not execute ssh perf events/);
  assert.equal(action.effect, "deny");
  assert.match(action.message, /explicit user scope/);
});

test("复议独立 deadline：初审很久后受理，首次超时重试成功，grant 只消费一次", async (t) => {
  const { handler, calls } = await setup(t, {
    options: { deadlineMs: 100, attemptTimeoutMs: 100 },
    review: [DENY, ALLOW, DENY],
    onGenerate: ({ calls }) => calls.generate.length === 2 ? HANG() : undefined,
  });
  const original = input();
  await handler(original);
  assert.equal(original.effect, "deny");
  await advance(t, 1_000); // 原审查的 deadline 早已过去。
  const pending = appeal(calls);
  await flush();
  assert.equal(calls.generate.length, 2, "复议不继承已过期的初审预算");
  await advance(t, 99);
  assert.equal(calls.generate.length, 2, "受理后仍享完整独立预算");
  await advance(t, 1);
  assert.equal(calls.generate.length, 3);
  assert.match((await pending).content, /行政复议通过/);
  const granted = input();
  await handler(granted);
  assert.equal(granted.effect, "allow");
  assert.equal(calls.generate.length, 3);
  assert.equal(decision(calls).layer, "appeal");
  const consumed = input();
  await handler(consumed);
  assert.equal(consumed.effect, "deny");
  assert.equal(calls.generate.length, 4);
});

test("复议也受单次 attempt 上限保护，慢 primary 转 fallback 签发 grant", async (t) => {
  const { handler, calls } = await setup(t, {
    options: { deadlineMs: 1_000, attemptTimeoutMs: 100, fallbackModels: [FALLBACK] },
    review: [DENY, ALLOW],
    onGenerate: ({ calls }) => calls.generate.length === 2 ? HANG() : undefined,
  });
  await handler(input());
  const pending = appeal(calls);
  await flush();
  await advance(t, 100);
  assert.equal(calls.generate.length, 3);
  assert.match((await pending).content, /行政复议通过/);
  assert.equal(decision(calls).review_model, "test/fallback");
});

test("复议两轮 deadline 均失败：不签发 grant、不计驳回；下一次模型 deny 仅记一次", async (t) => {
  const { handler, calls } = await setup(t, {
    options: { deadlineMs: 100, attemptTimeoutMs: 100 },
    review: [DENY],
    onGenerate: ({ calls }) => [2, 3].includes(calls.generate.length) ? HANG() : undefined,
  });
  await handler(input());
  const pending = appeal(calls);
  await flush();
  await advance(t, 100);
  await advance(t, 100);
  const failed = await pending;
  assert.match(failed.content, /未能裁决.*review deadline exceeded/);
  assert.match(failed.content, /不计入驳回次数/);
  assert.equal(calls.generate.length, 3);
  assert.equal(decision(calls).effect, "deny");
  const rejected = await appeal(calls);
  assert.match(rejected.content, /行政复议被驳回（1\/3）/);
  assert.equal(calls.generate.length, 4);
  const ungranted = input();
  await handler(ungranted);
  assert.equal(ungranted.effect, "deny");
  assert.equal(calls.generate.length, 5, "没有 grant，原动作仍须审查");
});

test("初审与复议 prompt 均明确工作区默认来源、动作边界、写根优先且不扩大读限制", () => {
  for (const prompt of [buildReviewPrompt("{}"), buildAppealPrompt("{}", null, "outside working directory", "misread")]) {
    assert.match(prompt, /boundary applies ONLY to "external_directory"/);
    assert.match(prompt, /Do NOT apply that stricter boundary to "edit"\/"write"/);
    assert.match(prompt, /\/tmp\/opencode\/\*\* is the orchestrator's standard task workspace/);
    assert.match(prompt, /task-created artifacts BY DEFAULT, unless context explicitly contradicts this/);
    assert.match(prompt, /do not require separate proof/);
    assert.match(prompt, /Explicit user write-root restrictions still take precedence/);
    assert.match(prompt, /r15 write root = perf-docs\//);
    assert.match(prompt, /does not restrict read-only operations/);
    assert.match(prompt, /not blanket authorization for unrelated actions or remote execution/);
  }
});

test("README 保留预算/重试/工作区边界说明，发行示例升级 0.7.9", () => {
  const readme = fs.readFileSync(new URL("../README.md", import.meta.url), "utf8");
  assert.match(readme, /opencode-approval-0\.7\.9\.tgz/);
  assert.match(readme, /`attemptTimeoutMs`.*min\(45000, deadlineMs \/ 2\)/);
  assert.match(readme, /仅插件自身的整链 deadline 失败/);
  assert.match(readme, /重试整链一次/);
  assert.match(readme, /从受理时刻起独立计算/);
  assert.match(readme, /默认视为任务创建物/);
  assert.match(readme, /严格边界仅适用于 `external_directory`/);
  assert.match(readme, /r15 写入根 = perf-docs\//);
  assert.match(readme, /写范围不等于读限制/);
});

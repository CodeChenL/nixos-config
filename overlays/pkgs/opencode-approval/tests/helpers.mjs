// tests/helpers.mjs —— mock ctx 与输入构造器（node --test 不会把本文件当测试执行）
// mock 的 ctx 只实现插件实际用到的接口：
// permission.hook / generate.text / session(context|get|synthetic|create|switchModel|generate|hook)
// / model.list / rpc.register / options。
// 默认把 auditPath/statePath 指向独立临时目录，避免测试污染真实日志/模式及并行测试。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const clone = (value) => JSON.parse(JSON.stringify(value ?? null));

export function makeCtx({
  options = {},
  review = [],
  reviewError = null,
  reviewDelayMs = 0,
  reviewUsage = null,
  modelCosts = [],
  sessionMessages = {},
  sessionParents = {},
  sessionDirs = {},
  sessionCreateError = false,
  contextError = null,
  contextDelayMs = 0,
  rpcError = null,
  // major 6 夹具：是否提供事件流（ctx.event.subscribe）；会话版本信号（time.updated）
  // 默认随消息计数变化，模拟宿主 projector 在消息到达时刷新 Session.Info.time.updated。
  events = true,
  sessionSignal = true,
  onGenerate = null,
  generateError = null,
} = {}) {
  const calls = {
    hooks: [],
    generate: [],
    sessionContext: [],
    sessionGet: [],
    sessionCreate: [],
    sessionRemove: [],
    sessionsAlive: new Set(),
    sessionInterrupt: [],
    switchModel: [],
    sessionGenerate: [],
    sessionHooks: [],
    sessionHooksDisposed: 0,
    tools: [],
    toolsDisposed: 0,
    toolTransforms: 0,
    synthetic: [],
    eventSubscribe: 0,
    modelList: 0,
    disposed: false,
    rpc: { definition: null, handlers: null, disposed: false, emitted: [] },
  };
  let index = 0;
  let mockSessionModel = null;
  const auditDir = fs.mkdtempSync(path.join(os.tmpdir(), "opencode-approval-test-"));

  // 模拟宿主 http.response 钩子：带上 usage 的 SSE 响应（供 usage/费用链路与
  // major 9 的"迟到响应"场景复用；由测试显式调用时可精确控制时机）。
  const fireUsageEvent = (model, sessionID, usage) => {
    const hook = calls.sessionHooks.find((item) => item.name === "http.response");
    if (!hook) return Promise.resolve();
    const event = {
      kind: "generate",
      sessionID: sessionID ?? null,
      model,
      response: new Response(`data: ${JSON.stringify({ usage })}\n\ndata: [DONE]\n\n`),
    };
    hook.callback(event);
    if (event.response && event.response.body) {
      return (async () => {
        for await (const _chunk of event.response.body) {
          // 消费被包装后的流，触发 usage finalize
        }
      })();
    }
    return Promise.resolve();
  };
  calls.fireUsage = fireUsageEvent;

  // 共享的"模型调用"行为：记录 {model, prompt}、延迟/异常/应答 fixture、
  // 并模拟 session http.response 钩子（带 usage 的 SSE）。
  const runModelCall = async (model, prompt, sessionID) => {
    calls.generate.push(clone({ model, prompt }));
    if (onGenerate) await onGenerate({ model, prompt, sessionID, calls });
    if (reviewDelayMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, reviewDelayMs));
    }
    if (generateError) throw generateError;
    if (reviewError) throw reviewError;
    const entry = review[Math.min(index, review.length - 1)];
    index += 1;
    if (entry && typeof entry === "object" && typeof entry.error === "string") {
      throw new Error(entry.error);
    }
    if (reviewUsage) await fireUsageEvent(model, sessionID, reviewUsage);
    return { text: entry };
  };

  // 事件流缓冲（events=false 时无 ctx.event；calls.emitEvent 退化为空操作）
  const eventStream = { queue: [], waiters: [] };
  calls.emitEvent = (event) => {
    if (!events) return;
    eventStream.queue.push(event);
    for (const resolve of eventStream.waiters.splice(0)) resolve();
  };

  const ctx = {
    options: {
      auditPath: path.join(auditDir, "approval-audit.jsonl"),
      statePath: path.join(auditDir, "approval-state.json"),
      ...options,
    },
    permission: {
      hook: async (name, handler) => {
        calls.hooks.push({ name, handler });
        return {
          dispose: async () => {
            calls.disposed = true;
          },
        };
      },
    },
    generate: {
      text: async (input) => runModelCall(input?.model, input?.prompt, null),
    },
    model: {
      list: async () => {
        calls.modelList += 1;
        return { data: modelCosts };
      },
    },
    session: {
      context: async ({ sessionID }) => {
        calls.sessionContext.push(sessionID);
        if (contextDelayMs > 0) {
          await new Promise((resolve) => setTimeout(resolve, contextDelayMs));
        }
        if (contextError) throw contextError;
        return sessionMessages[sessionID] ?? [];
      },
      get: async ({ sessionID }) => {
        calls.sessionGet.push(sessionID);
        const directory = sessionDirs[sessionID];
        const messageCount = (sessionMessages[sessionID] ?? []).length;
        return {
          id: sessionID,
          parentID: sessionParents[sessionID],
          ...(directory === undefined ? {} : { location: { directory } }),
          // 宿主 Session.Info 会随消息到达更新 time.updated（projector）；这里用消息计数
          // 模拟该廉价版本信号，供上下文缓存键感知"追加/撤回消息"。
          ...(sessionSignal ? { time: { created: 1, updated: messageCount }, metadata: { messageCount } } : {}),
        };
      },
      interrupt: async (input) => {
        calls.sessionInterrupt.push(clone(input));
        return { interrupted: true };
      },
      create: async (input) => {
        calls.sessionCreate.push(clone(input));
        if (sessionCreateError) throw new Error("cannot create session");
        // 每次创建返回不同 ID（宿主语义）：审查插件按会话 ID 绑定请求身份（usage 归属）
        const ordinal = calls.sessionCreate.length;
        const id = ordinal === 1 ? "ses_approval_internal" : `ses_approval_internal_${ordinal}`;
        calls.sessionsAlive.add(id);
        return { id, title: input?.title };
      },
      remove: async ({ sessionID }) => {
        calls.sessionRemove.push(clone({ sessionID }));
        calls.sessionRemoved = calls.sessionRemove.length; // 计数别名（探针/审计友好）
        calls.sessionsAlive.delete(sessionID);
        return {};
      },
      switchModel: async ({ sessionID, model }) => {
        calls.switchModel.push(clone({ sessionID, model }));
        mockSessionModel = clone(model);
        return {};
      },
      generate: async ({ sessionID, prompt }) => {
        calls.sessionGenerate.push(clone({ sessionID, prompt }));
        return runModelCall(mockSessionModel, prompt, sessionID);
      },
      hook: async (name, callback, options) => {
        calls.sessionHooks.push({ name, callback, options });
        return {
          dispose: async () => {
            calls.sessionHooksDisposed += 1;
          },
        };
      },
      synthetic: async (input) => {
        calls.synthetic.push(clone(input));
        return {};
      },
    },
    // 公共事件流（major 6）：测试可用 calls.emitEvent 注入消息到达类事件
    ...(events
      ? {
          event: {
            subscribe: ({ signal } = {}) => {
              calls.eventSubscribe += 1;
              signal?.addEventListener?.("abort", () => {
                for (const resolve of eventStream.waiters.splice(0)) resolve();
              }, { once: true });
              return {
                [Symbol.asyncIterator]() {
                  return {
                    async next() {
                      for (;;) {
                        if (signal?.aborted) return { done: true, value: undefined };
                        if (eventStream.queue.length > 0) {
                          return { done: false, value: eventStream.queue.shift() };
                        }
                        await new Promise((resolve) => eventStream.waiters.push(resolve));
                      }
                    },
                    async return() {
                      return { done: true, value: undefined };
                    },
                  };
                },
              };
            },
          },
        }
      : {}),
    tool: {
      transform: async (callback) => {
        calls.toolTransforms += 1;
        const added = [];
        const editor = {
          add: (tool) => {
            added.push(tool);
            return tool.name;
          },
          get: () => undefined,
          list: () => added,
          namespace: () => {},
        };
        callback(editor);
        calls.tools.push(...added);
        return {
          dispose: async () => {
            calls.toolsDisposed += 1;
          },
        };
      },
    },
    rpc: {
      register: async (definition, handlers) => {
        if (rpcError) throw rpcError;
        calls.rpc.definition = definition;
        calls.rpc.handlers = handlers;
        return {
          dispose: async () => {
            calls.rpc.disposed = true;
          },
          events: {
            emit: async (name, data) => {
              calls.rpc.emitted.push({ name, data: clone(data) });
            },
          },
        };
      },
    },
  };
  return { ctx, calls };
}

// 通过 mock 的 RPC 注册调用插件方法（对应 TUI 侧 client.rpc.call）
export function invokeRpc(calls, method, input) {
  const handler = calls.rpc.handlers?.[method];
  if (typeof handler !== "function") throw new Error(`RPC handler not registered: ${method}`);
  return handler(input, {});
}

// 标准待审动作输入：默认 ask，由 handler 裁决
export function baseInput(overrides = {}) {
  return {
    sessionID: "ses_test",
    action: "bash",
    resources: [],
    metadata: { source: "tool-call" },
    effect: "ask",
    ...overrides,
  };
}

// 装载插件并取出 evaluate handler（fixture 参数与 makeCtx 相同）
export async function loadHandler(fixture = {}) {
  const { ctx, calls } = makeCtx(fixture);
  const plugin = (await import("../plugin/index.js")).default;
  const cleanup = await plugin.setup(ctx);
  if (calls.hooks.length !== 1) throw new Error("expected exactly one permission hook");
  if (calls.hooks[0].name !== "evaluate") throw new Error("expected evaluate hook");
  return { handler: calls.hooks[0].handler, calls, cleanup };
}

// 装载插件前自定义 ctx（覆盖 session.get / session.generate 等），其余同 loadHandler
export async function loadCustom(fixture = {}, configure) {
  const { ctx, calls } = makeCtx(fixture);
  if (typeof configure === "function") configure(ctx, calls);
  const plugin = (await import("../plugin/index.js")).default;
  const cleanup = await plugin.setup(ctx);
  return { ctx, handler: calls.hooks[0].handler, calls, cleanup };
}

// 可手动完成的 promise（控制并发/迟到响应时序）
export function deferred() {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

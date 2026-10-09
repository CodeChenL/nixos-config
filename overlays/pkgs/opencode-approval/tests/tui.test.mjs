// tests/tui.test.mjs —— TUI 半（tui.js）：slash 命令 + 侧栏面板 + deny 提醒。
// 说明：Node 测试环境无法解析 render-lib.js 的 opentui:runtime-module:* 虚拟标识，
// 因此 setup 里面板被静默禁用（这正是宿主不提供运行时模块时的降级路径）；
// 面板逻辑通过 __test 导出的纯函数验证。

import assert from "node:assert/strict";
import { test } from "node:test";

const tuiModule = await import("../plugin/tui.js");
const tuiPlugin = tuiModule.default;
const { buildPanel, buildDecisionDetail, createDecisionHandler } = tuiModule.__test;

function makeTui({ rpcResult, rpcError, location, sessionLocation } = {}) {
  const calls = {
    slotClaims: [],
    layers: [],
    toasts: [],
    rpcCalls: [],
    rpcCallOptions: [],
    dataSubs: [],
    dataOff: false,
    slotDisposed: 0,
  };
  const ctx = {
    ...(location === undefined ? {} : { location }),
    ui: {
      toast: { show: (options) => calls.toasts.push(options) },
      router: { current: () => ({ type: "session", sessionID: "ses_tui" }) },
      slot: (claim) => {
        calls.slotClaims.push(claim);
        return () => {
          calls.slotDisposed += 1;
        };
      },
    },
    keymap: {
      layer: (thunk) => {
        calls.layers.push(thunk());
      },
    },
    data: {
      on: (type, handler) => {
        calls.dataSubs.push({ type, handler });
        return () => {
          calls.dataOff = true;
        };
      },
    },
    client: {
      ...(sessionLocation === undefined
        ? {}
        : {
            session: {
              get: async ({ sessionID }) => ({ id: sessionID, location: sessionLocation }),
            },
          }),
      rpc: {
        call: async (input, options) => {
          calls.rpcCalls.push(JSON.parse(JSON.stringify(input)));
          calls.rpcCallOptions.push(options ? JSON.parse(JSON.stringify(options)) : undefined);
          if (rpcError) throw rpcError;
          return rpcResult ?? { output: { text: "OK 文本" } };
        },
      },
    },
  };
  return { ctx, calls };
}

const loadTui = async (fixture) => {
  const { ctx, calls } = makeTui(fixture);
  const cleanup = await tuiPlugin.setup(ctx);
  // 模拟主机把 app 槽位挂载为组件：调用 render 完成 keymap 层注册
  const appClaim = calls.slotClaims.find((claim) => claim.append === "app");
  if (appClaim) appClaim.render();
  return { ctx, calls, cleanup, appClaim };
};

test("TUI 模块形态：id + setup（2.0.x 的 { id, setup } 形态）", async () => {
  assert.equal(tuiPlugin.id, "opencode-approval:tui");
  assert.equal(typeof tuiPlugin.setup, "function");
});

test("注册两个 slash 命令：approval-mode / approval-model（arguments: true）", async () => {
  const { calls, appClaim } = await loadTui();
  assert.ok(appClaim);
  assert.equal(calls.layers.length, 1);
  assert.equal(calls.layers[0].mode, "global");
  const bySlash = new Map(calls.layers[0].commands.map((command) => [command.slash.name, command]));
  assert.ok(bySlash.has("approval-mode"));
  assert.ok(bySlash.has("approval-model"));
  assert.equal(bySlash.get("approval-mode").slash.arguments, true);
  assert.equal(bySlash.get("approval-model").slash.arguments, true);
});

test("render-lib 不可用时不注册侧栏面板（降级路径）", async () => {
  const { calls } = await loadTui();
  assert.equal(
    calls.slotClaims.some((claim) => claim.append === "sidebar.content"),
    false,
  );
});

test("订阅 decision 事件：deny 弹 warning toast，allow 静默", async () => {
  const { calls } = await loadTui();
  assert.equal(calls.dataSubs.length, 1);
  assert.equal(calls.dataSubs[0].type, "rpc.opencode-approval.decision");
  calls.dataSubs[0].handler({
    data: { layer: "rule", effect: "deny", action: "bash", summary: "iptables -F" },
  });
  assert.equal(calls.toasts.at(-1).variant, "warning");
  assert.match(calls.toasts.at(-1).message, /iptables -F/);
  const before = calls.toasts.length;
  calls.dataSubs[0].handler({ data: { layer: "model", effect: "allow", action: "bash", summary: "pwd" } });
  assert.equal(calls.toasts.length, before);
});

test("审查失败事件也弹 toast（layer=failure, effect=ask）", async () => {
  const { calls } = await loadTui();
  calls.dataSubs[0].handler({ data: { layer: "failure", effect: "ask", action: "bash", summary: "git push" } });
  assert.equal(calls.toasts.at(-1).variant, "warning");
  assert.match(calls.toasts.at(-1).message, /审查失败/);
});

test("run：透传参数到 RPC（含 sessionID），并把结果 toast 出来", async () => {
  const { calls } = await loadTui({ rpcResult: { output: { text: "当前模式：review" } } });
  const bySlash = new Map(calls.layers[0].commands.map((command) => [command.slash.name, command]));
  await bySlash.get("approval-mode").run("allow-all");
  assert.deepEqual(calls.rpcCalls[0], {
    rpcID: "opencode-approval",
    method: "mode",
    input: { arg: "allow-all", sessionID: "ses_tui" },
  });
  assert.equal(calls.toasts.at(-1).message, "当前模式：review");

  await bySlash.get("approval-model").run("");
  assert.equal(calls.rpcCalls[1].method, "model");
  assert.equal(calls.rpcCalls[1].input.arg, "");
  assert.equal(calls.toasts.at(-1).message, "当前模式：review");
});

test("major 10：RPC 调用携带工作目录 Location（x-opencode-directory 头）", async () => {
  const { calls } = await loadTui({ location: { directory: "/work/a" } });
  const bySlash = new Map(calls.layers[0].commands.map((command) => [command.slash.name, command]));
  await bySlash.get("approval-mode").run("review");
  const options = calls.rpcCallOptions[0];
  assert.equal(options.headers["x-opencode-directory"], encodeURIComponent("/work/a"));
  assert.equal(options.location, undefined, "RequestOptions.location 是死代码，不得再传");
  assert.deepEqual(calls.rpcCalls[0], {
    rpcID: "opencode-approval",
    method: "mode",
    input: { arg: "review", sessionID: "ses_tui" },
  });
});

test("major 10：Location 取当前会话的工作目录（优先于插件实例 Location）", async () => {
  const { calls } = await loadTui({
    location: { directory: "/work/instance" },
    sessionLocation: { directory: "/work/session/" },
  });
  await calls.layers[0].commands[0].run("review");
  assert.equal(calls.rpcCallOptions[0].headers["x-opencode-directory"], encodeURIComponent("/work/session"));
});

test("major 10：decision 事件按 Location 过滤，两个 Location 的事件不串", async () => {
  const { calls } = await loadTui({ location: { directory: "/work/a" } });
  const handler = calls.dataSubs[0].handler;
  const before = calls.toasts.length;
  handler({
    data: { layer: "rule", effect: "deny", action: "bash", summary: "other-location" },
    location: { directory: "/work/b" },
  });
  assert.equal(calls.toasts.length, before, "其他 Location 的裁决不进本实例");
  handler({
    data: { layer: "rule", effect: "deny", action: "bash", summary: "same-location" },
    location: { directory: "/work/a/" },
  });
  assert.equal(calls.toasts.length, before + 1, "本 Location 的裁决正常进入");
  assert.match(calls.toasts.at(-1).message, /same-location/);
  // 旧宿主/无 Location 的事件不过滤（兼容）
  handler({ data: { layer: "rule", effect: "deny", action: "bash", summary: "legacy-event" } });
  assert.equal(calls.toasts.length, before + 2);
});

test("RPC 失败：error toast，不抛异常", async () => {
  const { calls } = await loadTui({ rpcError: new Error("boom") });
  await calls.layers[0].commands[0].run("x");
  assert.equal(calls.toasts.at(-1).variant, "error");
  assert.match(calls.toasts.at(-1).message, /boom/);
});

test("RPC 返回空文本：给出兜底提示", async () => {
  const { calls } = await loadTui({ rpcResult: { output: {} } });
  await calls.layers[0].commands[0].run("");
  assert.match(calls.toasts.at(-1).message, /没有返回结果/);
});

test("cleanup：释放 slot 注册与事件订阅", async () => {
  const { calls, cleanup } = await loadTui();
  assert.equal(calls.slotDisposed, 0);
  assert.equal(calls.dataOff, false);
  await cleanup();
  assert.equal(calls.slotDisposed, 1);
  assert.equal(calls.dataOff, true);
});

// ---------- __test 纯函数 ----------

const makeFakeLib = () => ({
  createElement: (tag) => ({ tag, props: {}, children: [] }),
  setProp: (node, key, value) => {
    node.props[key] = value;
  },
  insert: (node, child) => {
    node.children.push(typeof child === "function" ? child() : child);
  },
});

const collectText = (node, out = []) => {
  if (node === null || node === undefined || node === false) return out;
  if (typeof node === "string") {
    out.push(node);
    return out;
  }
  if (Array.isArray(node)) {
    for (const item of node) collectText(item, out);
    return out;
  }
  for (const child of node.children ?? []) collectText(child, out);
  return out;
};

test("buildPanel：单行条目（模式/链/条目含所用模型；指标与理由移入详情）", () => {
  const lib = makeFakeLib();
  const state = {
    mode: "allow-all",
    modeSource: "runtime",
    chain: "deepseek/deepseek-flash#xhigh → mimo-v2.6-pro",
    chainSource: "runtime",
    decisions: [
      {
        layer: "model",
        effect: "deny",
        summary: "rm -rf /tmp/x --with-a-rather-long-flag-list a b c",
        rationale: "outside working copy and no user authorization is present in the conversation context",
        review_model: "deepseek/deepseek-flash#xhigh",
        action: "bash",
        context_chars: 1200,
        input_tokens: 1200,
        output_tokens: 80,
        cost_usd: 0.00136,
      },
      { layer: "rule", effect: "allow", summary: "pwd", rationale: "hard allow command", action: "bash" },
    ],
  };
  const text = collectText(buildPanel(lib, undefined, state)).join("\n");
  assert.match(text, /▼ Approval/);
  assert.match(text, /allow-all（本节点）/);
  assert.match(text, /模型：deepseek\/deepseek-flash#xhigh → mimo-v2\.6-pro（会话内）/);
  // 单项单行：mark 与条目行分属两个文本节点（收集后以换行连接）
  assert.match(text, /✖\nmodel · rm -rf \/tmp\/x --with-a-rather-long-flag-list a b c @deepseek-flash#xhigh/);
  assert.match(text, /✔\nrule · pwd/);
  assert.match(text, /点击条目看详情/);
  // 指标与理由不再占用面板行（移入详情弹窗）
  assert.doesNotMatch(text, /ctx 1\.2k字/);
  assert.doesNotMatch(text, /理由：/);
});

test("buildPanel：传入 openDetail 时条目可点击", () => {
  const lib = makeFakeLib();
  const clicked = [];
  const state = {
    mode: "review",
    chain: "c",
    decisions: [{ layer: "model", effect: "deny", summary: "s", action: "bash" }],
  };
  const panel = buildPanel(lib, undefined, state, { openDetail: (item) => clicked.push(item) });
  const findHandler = (node) => {
    if (!node || typeof node !== "object") return null;
    if (typeof node.props?.onMouseUp === "function") return node.props.onMouseUp;
    for (const child of node.children ?? []) {
      const found = findHandler(child);
      if (found) return found;
    }
    return null;
  };
  const onClick = findHandler(panel);
  assert.equal(typeof onClick, "function");
  onClick();
  assert.equal(clicked.length, 1);
  assert.equal(clicked[0].summary, "s");
});

test("buildPanel：共享状态来源显示持久化，不冒充配置默认", () => {
  const text = collectText(buildPanel(makeFakeLib(), undefined, {
    mode: "ask", modeSource: "persisted", chain: "model", decisions: [],
  })).join("\n");
  assert.match(text, /ask（持久化）/);
});

test("buildDecisionDetail：完整字段（资源/指标/理由/授权）与 esc/关闭回调", () => {
  const lib = makeFakeLib();
  let closed = 0;
  const item = {
    ts: "2026-10-05T07:47:08.970Z",
    layer: "appeal",
    effect: "allow",
    action: "bash",
    resources: ["npm --version", "/tmp/out.txt"],
    risk_level: "low",
    review_model: "mock/mock-allow",
    context_chars: 2726,
    input_tokens: 4321,
    output_tokens: 123,
    cost_usd: 0.004567,
    user_authorization: "mock",
    rationale: "复议通过（一次性放行原动作）：mock allow",
  };
  const tree = buildDecisionDetail(lib, undefined, item, () => {
    closed += 1;
  });
  const text = collectText(tree).join("\n");
  assert.match(text, /✔ appeal · allow/);
  assert.match(text, /npm --version\n\/tmp\/out\.txt/);
  assert.match(text, /ctx 2\.7k字/);
  assert.match(text, /↑4\.3k ↓123 tokens/);
  assert.match(text, /\$0\.004567/);
  assert.match(text, /复议通过/);
  assert.match(text, /mock\/mock-allow/);
  const handlers = [];
  const collectHandlers = (node) => {
    if (!node || typeof node !== "object") return;
    if (typeof node.props?.onMouseUp === "function") handlers.push(node.props.onMouseUp);
    for (const child of node.children ?? []) collectHandlers(child);
  };
  collectHandlers(tree);
  assert.ok(handlers.length >= 2, "esc 与 [ 关闭 ] 至少两个关闭入口");
  for (const handle of handlers) handle();
  assert.equal(closed, handlers.length);
});

test("buildPanel：空/缺失状态给出占位", () => {
  const lib = makeFakeLib();
  const text = collectText(buildPanel(lib, undefined, undefined)).join("\n");
  assert.match(text, /▼ Approval/);
  assert.match(text, /模型：\?/);
  assert.match(text, /—— 暂无裁决/);
});

test("createDecisionHandler：记录、deny toast、command 刷新状态", () => {
  const toasts = [];
  let refreshed = 0;
  let state = { mode: "review", chain: "c", decisions: [] };
  const handler = createDecisionHandler({
    getState: () => state,
    setState: (value) => {
      state = value;
    },
    refresh: async () => {
      refreshed += 1;
    },
    toast: (message, variant) => toasts.push({ message, variant }),
  });

  handler({ data: { layer: "rule", effect: "deny", action: "bash", summary: "iptables -F", rationale: "hard deny rule: iptables-flush" } });
  assert.equal(toasts.at(-1).variant, "warning");
  assert.match(toasts.at(-1).message, /拒绝（rule）/);
  assert.match(toasts.at(-1).message, /\n理由：hard deny rule: iptables-flush/);
  assert.equal(state.decisions.length, 1);

  handler({ data: { layer: "model", effect: "allow", summary: "pwd" } });
  assert.equal(toasts.length, 1);
  assert.equal(state.decisions.length, 2);

  handler({ data: { layer: "command", effect: "allow", summary: "mode -> allow-all" } });
  assert.equal(refreshed, 1);
  assert.equal(state.decisions.length, 3);
});

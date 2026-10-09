// opencode-approval TUI 半：slash 命令 + 侧栏 Approval 面板。
//
// - /approval-mode、/approval-model：经 RPC 读写服务端运行时变量，toast 回显，
//   绝不向会话注入消息。
// - 侧栏面板（sidebar.content）：当前模式与来源、审查模型链、最近裁决
//   （每条含所用审查模型）；deny 或审查失败时另弹 toast 提醒。
// - 元素渲染来自宿主注入的 OpenTUI 运行时（见 render-lib.js 的
//   opentui:runtime-module:* 虚拟标识）；宿主不提供时面板静默禁用，命令不受影响。
//
// 兼容 OpenCode 2.0.x 的 TUI 插件形态：default export { id, setup(ctx) }。
// keymap.layer 依赖 Solid 组件作用域，因此通过 ui.slot(append "app") 在组件内注册。

const RPC_ID = "opencode-approval";
const DECISION_EVENT = "rpc.opencode-approval.decision";
const MAX_PANEL_DECISIONS = 6;
const MAX_STATE_DECISIONS = 12;

// 顶层动态导入：Node（单测环境）无法解析虚拟标识 → 捕获后禁用面板；宿主内正常加载。
let renderLib = null;
try {
  renderLib = await import("./render-lib.js");
} catch {
  renderLib = null;
}

const truncate = (value, limit) => {
  const text = String(value ?? "");
  return text.length > limit ? text.slice(0, limit - 1) + "…" : text;
};

// 目录归一化：比较 Location 时忽略末尾斜杠差异
const normalizeDirectory = (value) => {
  const text = String(value ?? "").trim();
  if (text === "") return "";
  return text.length > 1 ? text.replace(/\/+$/, "") : text;
};

const formatCount = (value) => {
  const number = Number(value);
  if (!Number.isFinite(number)) return "0";
  return number >= 1000 ? (number / 1000).toFixed(1) + "k" : String(number);
};

const formatCost = (value) => {
  const number = Number(value);
  if (!Number.isFinite(number)) return "";
  return "$" + (Math.abs(number) < 0.01 ? number.toFixed(6) : number.toFixed(4));
};

// 元素构造小工具：把 props/children 施加到宿主运行时元素上。
const makeEl = (lib) => (tag, props = {}, children = []) => {
  const node = lib.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value !== undefined) lib.setProp(node, key, value);
  }
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    lib.insert(node, child);
  }
  return node;
};

const panelColors = (theme) => ({
  muted: typeof theme?.text?.muted === "string" ? { fg: theme.text.muted } : {},
  warning: typeof theme?.text?.feedback?.warning?.base === "string" ? { fg: theme.text.feedback.warning.base } : {},
});

// 纯函数：用给定元素运行时构造面板（供 setup 与单测复用）。
// 列表单项只占一行（超出宽度由宿主截断）；点击条目打开详情弹窗（buildDecisionDetail）。
function buildPanel(lib, theme, state, handlers = {}) {
  const el = makeEl(lib);
  const { muted, warning } = panelColors(theme);
  const snapshot = state ?? {};
  const mode =
    snapshot.mode === "allow-all" || snapshot.mode === "ask" || snapshot.mode === "review"
      ? snapshot.mode
      : "?";
  const modeSource = snapshot.modeSource === "runtime" ? "（本节点）"
    : snapshot.modeSource === "persisted" ? "（持久化）" : "";
  const chainSource = snapshot.chainSource === "runtime" ? "（会话内）" : "";
  const rows = [
    el("box", { width: "100%", flexDirection: "row", justifyContent: "space-between" }, [
      el("text", { ...muted }, ["▼ Approval"]),
      el("text", { ...(mode === "allow-all" ? warning : {}) }, [mode + modeSource]),
    ]),
    el("text", { ...muted, wrapMode: "word" }, ["模型：" + (snapshot.chain ?? "?") + chainSource]),
  ];
  const decisions = Array.isArray(snapshot.decisions) ? snapshot.decisions : [];
  if (decisions.length === 0) {
    rows.push(el("text", { ...muted }, ["—— 暂无裁决"]));
  } else {
    rows.push(el("text", { ...muted }, ["—— 最近裁决（点击条目看详情）"]));
    for (const item of decisions.slice(0, MAX_PANEL_DECISIONS)) {
      const effect = String(item?.effect ?? "");
      const layer = String(item?.layer ?? "");
      const denied = effect === "deny";
      const failed = layer === "failure";
      const mark = denied ? "✖" : effect === "allow" ? "✔" : "◌";
      const model = item?.review_model ? " @" + String(item.review_model).split("/").pop() : "";
      const line = layer + " · " + (item?.summary || item?.action || "") + model;
      const rowProps = { width: "100%", flexDirection: "row", gap: 1, minWidth: 0 };
      if (typeof handlers.openDetail === "function") {
        rowProps.onMouseUp = () => handlers.openDetail(item);
      }
      rows.push(
        el("box", rowProps, [
          el("text", { ...(denied || failed ? warning : { ...muted }), flexShrink: 0 }, [mark]),
          el("text", { ...muted, wrapMode: "none", truncate: true, flexGrow: 1, flexShrink: 1, minWidth: 0 }, [
            line,
          ]),
        ]),
      );
    }
  }
  return el("box", { width: "100%", flexDirection: "column" }, rows);
}

// 纯函数：构造单条裁决的详情弹窗内容（点击面板条目打开；Esc / 点击 esc / 点击背景关闭）。
function buildDecisionDetail(lib, theme, item, close) {
  const el = makeEl(lib);
  const { muted, warning } = panelColors(theme);
  const entry = item ?? {};
  const effect = String(entry.effect ?? "");
  const layer = String(entry.layer ?? "");
  const denied = effect === "deny";
  const failed = layer === "failure";
  const mark = denied ? "✖" : effect === "allow" ? "✔" : "◌";
  const rows = [
    el("box", { width: "100%", flexDirection: "row", justifyContent: "space-between" }, [
      el("text", { ...(denied || failed ? warning : { ...muted }) }, [
        mark + " " + (layer || "decision") + " · " + (effect || "?"),
      ]),
      el("text", { ...muted, onMouseUp: close }, ["esc"]),
    ]),
  ];
  const field = (label, value, opts = {}) => {
    const text = String(value ?? "").trim();
    if (text === "") return;
    rows.push(
      el("box", { width: "100%", flexDirection: "row", gap: 1, minWidth: 0 }, [
        el("text", { ...muted, flexShrink: 0 }, [label]),
        el(
          "text",
          { wrapMode: "word", flexGrow: 1, flexShrink: 1, minWidth: 0, ...(opts.warn ? warning : {}) },
          [text],
        ),
      ]),
    );
  };
  field("时间", entry.ts);
  field("动作", entry.action);
  field("资源", Array.isArray(entry.resources) ? entry.resources.join("\n") : entry.resources);
  field("风险", entry.risk_level);
  field("审查模型", entry.review_model);
  if (Number.isFinite(entry.context_chars)) field("上下文", "ctx " + formatCount(entry.context_chars) + "字");
  if (Number.isFinite(entry.input_tokens) || Number.isFinite(entry.output_tokens)) {
    field("用量", "↑" + formatCount(entry.input_tokens ?? 0) + " ↓" + formatCount(entry.output_tokens ?? 0) + " tokens");
  }
  if (Number.isFinite(entry.cost_usd)) field("费用", formatCost(entry.cost_usd));
  field("用户授权", entry.user_authorization);
  field("理由", entry.rationale, { warn: denied || failed });
  rows.push(
    el("box", { width: "100%", flexDirection: "row", justifyContent: "flex-end" }, [
      el("text", { ...muted, onMouseUp: close }, ["[ 关闭 ]"]),
    ]),
  );
  return el("box", { paddingLeft: 2, paddingRight: 2, flexDirection: "column", gap: 1, width: "100%" }, rows);
}

// 纯函数：构造 decision 事件处理器（供 setup 与单测复用）。
// getLocation（可选）返回当前工作目录的 Location：外部订阅会收到**所有** Location 的
// 事件，这里只接受与当前 Location 一致的裁决，两个 Location 的事件互不串扰；
// 任一侧缺少 Location 信息时不过滤（兼容旧宿主/旧事件）。
function createDecisionHandler({ getState, setState, refresh, toast, getLocation }) {
  return (event) => {
    const decision = event?.data;
    if (!decision || typeof decision !== "object") return;
    const eventDirectory = normalizeDirectory(event?.location?.directory);
    const currentDirectory = normalizeDirectory(
      typeof getLocation === "function" ? getLocation()?.directory : undefined,
    );
    if (eventDirectory && currentDirectory && eventDirectory !== currentDirectory) return;
    const current = getState() ?? {};
    const decisions = [
      decision,
      ...(Array.isArray(current.decisions) ? current.decisions : []),
    ].slice(0, MAX_STATE_DECISIONS);
    setState({ ...current, decisions });
    if (decision.layer === "command") void refresh();
    const failed = decision.layer === "failure";
    if (decision.effect === "deny" || failed) {
      const label = failed && decision.effect !== "deny" ? "审查失败（未自动放行）" : "拒绝";
      const what = decision.summary || decision.action || "";
      // toast 直接渲染 message（wrapMode="word"），带上拦截原因便于定位
      const reason = String(decision.rationale ?? "").trim();
      const message =
        "审批" + label + "（" + String(decision.layer ?? "") + "）：" + truncate(what, 80) +
        (reason ? "\n理由：" + truncate(reason, 140) : "");
      toast(message, "warning");
    }
  };
}

const plugin = {
  id: "opencode-approval:tui",

  async setup(ctx) {
    const toast = (message, variant) => {
      try {
        ctx.ui?.toast?.show?.({ message, variant });
      } catch {
        // 回显失败不影响功能
      }
    };
    const currentSessionID = () => {
      try {
        const route = ctx.ui?.router?.current?.();
        return route?.type === "session" ? route.sessionID : "";
      } catch {
        return "";
      }
    };
    // Location 路由：RPC 必须携带工作目录，否则服务端按自身 cwd（常常是 /）解析到错误的
    // 插件实例。优先当前会话的 Location（session.get），回退 TUI 插件实例的 ctx.location；
    // 取到后缓存为"当前 Location"，供事件过滤使用。
    let currentLocation = ctx.location && typeof ctx.location === "object" ? { ...ctx.location } : null;
    const resolveLocation = async () => {
      const sessionID = currentSessionID();
      try {
        if (sessionID && ctx.client?.session && typeof ctx.client.session.get === "function") {
          const info = await Promise.race([
            ctx.client.session.get({ sessionID }),
            new Promise((_, reject) => setTimeout(() => reject(new Error("location timeout")), 3000)),
          ]);
          const directory = info?.location?.directory ?? info?.directory;
          if (typeof directory === "string" && directory !== "") {
            currentLocation = { directory };
          }
        }
      } catch {
        // 会话位置查询失败：沿用缓存/ctx.location
      }
      return currentLocation;
    };
    // RPC 调用统一带 Location：裸 `client.rpc.call` 只认 header（x-opencode-directory），
    // RequestOptions 的 location 字段是 typed 子客户端的参数、在这里是死代码（已删除）。
    const locationOptions = () => {
      const directory = normalizeDirectory(currentLocation?.directory);
      if (directory === "") return undefined;
      return { headers: { "x-opencode-directory": encodeURIComponent(directory) } };
    };
    const callRpc = (method, input) => ctx.client.rpc.call({ rpcID: RPC_ID, method, input }, locationOptions());
    // 命令处理器：把参数透传给服务端 RPC，结果（text）以 toast 回显。
    const run = (method) => async (input) => {
      try {
        await resolveLocation();
        const result = await callRpc(method, { arg: String(input ?? ""), sessionID: currentSessionID() });
        const text = result?.output?.text;
        toast(typeof text === "string" && text !== "" ? text : "opencode-approval：命令没有返回结果");
      } catch (error) {
        toast(`opencode-approval 命令执行失败：${error?.message ?? String(error)}`, "error");
      }
    };
    const commands = [
      {
        id: "opencode-approval.mode",
        title: "审批模式（/approval-mode）",
        description: "查看/切换 opencode-approval 审批模式（review / ask / allow-all / default）",
        group: "Approval",
        palette: true,
        slash: { name: "approval-mode", arguments: true },
        run: run("mode"),
      },
      {
        id: "opencode-approval.model",
        title: "审批审查模型（/approval-model）",
        description: "查看/切换 opencode-approval 审查模型链（default 重置）",
        group: "Approval",
        palette: true,
        slash: { name: "approval-model", arguments: true },
        run: run("model"),
      },
    ];

    // ---------- 侧栏面板 ----------
    const lib = renderLib;
    const signal = lib && typeof lib.createSignal === "function" ? lib.createSignal(null) : null;
    const getState = () => (signal ? signal[0]() : null);
    const setState = (value) => {
      if (signal) signal[1](value);
    };
    const refreshStatus = async () => {
      if (!lib) return;
      try {
        await resolveLocation();
        const result = await Promise.race([
          callRpc("status", {}),
          new Promise((_, reject) => setTimeout(() => reject(new Error("status timeout")), 3000)),
        ]);
        const output = result?.output;
        if (output && typeof output === "object") setState(output);
      } catch {
        // 服务端未注册 status 或不可达：面板保持现值
      }
    };
    // 事件订阅不依赖面板：即使面板禁用，deny 提醒仍可用。
    let offDecisions = null;
    try {
      offDecisions = ctx.data?.on?.(
        DECISION_EVENT,
        createDecisionHandler({
          getState,
          setState,
          refresh: refreshStatus,
          toast,
          getLocation: () => currentLocation,
        }),
      );
    } catch {
      // 事件订阅失败：面板仅显示静态状态
    }
    await refreshStatus();

    // 点击面板条目 → 详情弹窗（内容为纯函数 buildDecisionDetail；Esc / 点击 esc / 背景关闭）
    const openDecisionDetail = (item) => {
      try {
        const dialog = ctx.ui?.dialog;
        if (!dialog || typeof dialog.show !== "function") return;
        dialog.show(() =>
          buildDecisionDetail(lib, ctx.theme, item, () => {
            try {
              dialog.clear?.();
            } catch {
              // 忽略关闭失败
            }
          }),
        );
      } catch {
        // 弹窗失败不影响面板
      }
    };

    const disposers = [];
    try {
      const disposeSlot = ctx.ui?.slot?.({
        append: "app",
        render: () => {
          ctx.keymap.layer(() => ({ mode: "global", commands }));
          return null;
        },
      });
      if (typeof disposeSlot === "function") disposers.push(disposeSlot);
    } catch {
      // 槽位/keymap 注册失败时命令不可用，但不影响服务端审批功能
    }
    if (lib && typeof lib.createElement === "function") {
      try {
        const disposePanel = ctx.ui?.slot?.({
          append: "sidebar.content",
          render: () => {
            const root = lib.createElement("box");
            lib.setProp(root, "width", "100%");
            lib.setProp(root, "flexDirection", "column");
            lib.insert(root, () => buildPanel(lib, ctx.theme, getState(), { openDetail: openDecisionDetail }));
            return root;
          },
        });
        if (typeof disposePanel === "function") disposers.push(disposePanel);
      } catch {
        // 面板注册失败：命令仍可用
      }
    }
    return () => {
      if (typeof offDecisions === "function") {
        try {
          offDecisions();
        } catch {
          // 忽略退订错误
        }
      }
      for (const dispose of disposers.reverse()) {
        try {
          dispose();
        } catch {
          // 忽略卸载错误
        }
      }
    };
  },
};

// 仅供单测使用（宿主 TUI 加载器只读 default）。
export const __test = { buildPanel, buildDecisionDetail, createDecisionHandler };
export default plugin;

// tests/regression-073.test.mjs —— 0.7.3 对抗复核缺口回归（NF1-NF5 + minor 族）。
// 危险字面量仅作为 permission 输入字符串（mock），绝不真实执行；探针式构造，
// 每条都先断言旧缺陷的复现面（0.7.2 下会放行/串单），再断言修复后的裁决。

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  actionDomain,
  buildActionView,
  buildCommandMatchView,
  isHardAllowCommand,
  normalizeActionName,
} from "../plugin/index.js";
import { baseInput, loadCustom, loadHandler, makeCtx } from "./helpers.mjs";

const ALLOW = JSON.stringify({ risk_level: "medium", outcome: "allow", rationale: "reviewed" });
const DENY = JSON.stringify({ risk_level: "high", outcome: "deny", rationale: "not authorized" });
const j = (parts) => parts.join("");
const RB = j(["re", "boot"]); // 关键字分片构造，避免测试文本自身命中宿主硬规则
const MK = j(["mk", "f", "s"]);
const RMRF = j(["r", "m", " -", "r", "f", " /"]);

// ---------- NF1：正则硬规则的引号/转义目标 ----------

test("NF1：引号/转义目标不再绕过正则硬规则（含 allow-all 灾难兜底）", async () => {
  const cases = [
    ["quoted double target", j(["r", "m", " -", "r", "f", " ", '"/"'])],
    ["quoted single target", j(["r", "m", " -", "r", "f", " ", "'/'"])],
    ["escaped slash target", j(["r", "m", " -", "r", "f", " ", "\\/"])],
    ["dd quoted of", j(["d", "d if=/dev/zero of=", '"/dev/sda"'])],
    ["chmod quoted root", j(["chmod -R 777 ", '"/"'])],
    ["chown quoted root", j(["chown -R root:root ", '"/"'])],
    ["tee quoted device", j(["tee ", '"/dev/sda"'])],
    ["glued quote verb", j(["r", "m", '" -', "r", "f", ' /"'])],
  ];
  for (const mode of ["review", "allow-all"]) {
    const { handler, calls } = await loadHandler({ options: { mode }, review: [ALLOW] });
    for (const [label, cmd] of cases) {
      const input = baseInput({ resources: [cmd] });
      await handler(input);
      assert.equal(input.effect, "deny", `${mode}: ${label}`);
      assert.match(input.message, /hard rule/, `${mode}: ${label}`);
    }
    assert.equal(calls.generate.length, 0, `${mode}: 硬拒绝不调模型`);
  }
});

test("NF1：参数位文本提及不硬拒（含 dd of= 形态），真实执行仍拦", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  // G1：执行位门控后，参数位（含未加引号参数）里的危险字样是文本提及，不硬拒
  const mentions = [
    j(["echo ", '"', "r", "m", " -", "r", "f", " /", '"']),
    j(["git commit -m ", '"', "r", "m", " -", "r", "f", " /", '"']),
    j(["echo ", '"', "d", "d if=/dev/zero of=/dev/sda", '"']),
    j(["echo d", "d", " of=/dev/sda"]),
    j(["echo mk", "fs", " note"]),
  ];
  for (const cmd of mentions) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.equal(input.effect, "allow", cmd);
    assert.doesNotMatch(String(input.message ?? ""), /hard rule/, cmd);
  }
  // 真实执行仍拦（fail-closed 不放松）
  const unquoted = baseInput({ resources: [RMRF] });
  await handler(unquoted);
  assert.equal(unquoted.effect, "deny");
  assert.match(unquoted.message, /hard rule: rm-rf-root/);
  const dd = baseInput({ resources: ["dd if=/dev/zero of=/dev/sda"] });
  await handler(dd);
  assert.equal(dd.effect, "deny", "dd 的 of= 参数即破坏载荷，规则起点在命令词 dd");
  assert.match(dd.message, /hard rule: dd-of-dev/);
  assert.ok(calls.generate.length >= 1, "提及照常进模型层");
});

test("NF1：归一化只作用于匹配，不改变展示/审计文本", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY] });
  const cmd = j(["r", "m", " -", "r", "f", " ", '"/"']);
  await handler(baseInput({ resources: [cmd] }));
  assert.equal(calls.generate.length, 0);
  const view = buildCommandMatchView([cmd]);
  assert.equal(view.text, j(["r", "m", " -", "r", "f", " /", "\n"]), "归一化文本用于匹配");
  assert.notEqual(view.text, cmd);
});

// ---------- NF2：命令位引号胶合 / 反引号 / 包装执行器 ----------

test("NF2：命令位引号胶合与反引号命令替换照常判定", async () => {
  const cases = [
    ["quote-glue single", j(["'", RB, "'"])],
    ["quote-glue mid", ["re", '"', "boot", '"'].join("")],
    ["quote-glue empty suffix", j([RB, '""'])],
    ["escaped glue", j(["rebo\\ot"])],
    ["backtick substitution", j(["`", RB, "`"])],
    ["backtick nested in arg", j(["echo x ", "`", RB, "`"])],
    ["dollar-paren substitution", j(["$(", RB, ")"])],
    ["quoted dollar-paren", j(['echo "$(', RB, ')"'])],
  ];
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  for (const [label, cmd] of cases) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.equal(input.effect, "deny", label);
    assert.match(input.message, /hard rule: shutdown-reboot-halt/, label);
  }
  assert.equal(calls.generate.length, 0);
});

test("NF2：参数位/文本提及的放行语义保持（不误伤）", async () => {
  const { handler } = await loadHandler({ review: [ALLOW] });
  const fine = [
    j(['echo "notes; ', RB, '"']),
    j(["git commit -m ", '"', RB, '"']),
    j(["ssh root@target ", RB]),
    j(["rg '(", RB, "|halt)' notes.log"]),
    j(["cat ", RB, "-notes.log"]),
  ];
  for (const cmd of fine) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.equal(input.effect, "allow", cmd);
    assert.doesNotMatch(String(input.message ?? ""), /hard rule/, cmd);
  }
});

test("major5 包装执行器族：xargs/timeout/su/eval/busybox/watch/stdbuf 取内层命令", async () => {
  const cases = [
    j(["xargs ", RB]),
    j(["xargs -0 ", RB]),
    j(["xargs -n 1 ", RB]),
    j(["timeout 1 ", RB]),
    j(["timeout --preserve-status 2 ", RB]),
    j(["su root -c ", RB]),
    j(["su -c ", RB]),
    j(["eval ", RB]),
    j(["busybox ", RB]),
    j(["watch ", RB]),
    j(["stdbuf -o0 ", RB]),
    j(["stdbuf -o 0 ", RB]),
    j(["nohup ", RB]),
    j(["env FOO=1 ", RB]),
  ];
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  for (const cmd of cases) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.equal(input.effect, "deny", cmd);
    assert.match(input.message, /hard rule: shutdown-reboot-halt/, cmd);
  }
  assert.equal(calls.generate.length, 0);
  // 包装器的查询/参数形态不误伤
  const fine = ["command -v " + RB, "xargs --help", j(["su ", RB, " -c id"])];
  for (const cmd of fine) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.doesNotMatch(String(input.message ?? ""), /hard rule/, cmd);
  }
});

// ---------- NF3：未知 / 空白动作名 ----------

test("NF3：动作名归一化（大小写/首尾空白）不再绕过分域与 allow-all", async () => {
  for (const action of ["bash ", "Bash", "BASH", "bash\t", "  bash"]) {
    const { handler } = await loadHandler({ options: { mode: "allow-all" }, review: [ALLOW] });
    const input = baseInput({ action, resources: [RMRF] });
    await handler(input);
    assert.equal(input.effect, "deny", JSON.stringify(action));
    assert.match(input.message, /hard rule/);
  }
  assert.equal(normalizeActionName("  Bash\t"), "bash");
  assert.equal(actionDomain("bash "), "command");
});

test("NF3：未知动作名一律保守——命令规则照扫、allow-all 不放行、进模型层", async () => {
  // 未知动作 + 灾难命令：allow-all 也不能放行
  for (const mode of ["review", "allow-all"]) {
    const { handler, calls } = await loadHandler({ options: { mode }, review: [ALLOW] });
    const input = baseInput({ action: "execute_command", resources: [RMRF] });
    await handler(input);
    assert.equal(input.effect, "deny", mode);
    assert.match(input.message, /hard rule/, mode);
    assert.equal(calls.generate.length, 0);
  }
  // 未知动作 + 无害命令：allow-all 不放行，进模型层
  const { handler, calls } = await loadHandler({ options: { mode: "allow-all" }, review: [ALLOW] });
  const benign = baseInput({ action: "mcp_server_runcmd", resources: ["git status"] });
  await handler(benign);
  assert.equal(calls.generate.length, 1, "未知动作必须进模型层");
  assert.equal(benign.effect, "allow", "模型裁决生效");
  // 未知动作不吃命令白名单（不能凭 git status 零模型放行）
  const whitelisted = baseInput({ action: "custom_tool", resources: ["git status"] });
  await handler(whitelisted);
  assert.equal(calls.generate.length, 2);
  // 已知只读动作仍按 fastpath 放行（无回归）
  const known = baseInput({ action: "read", resources: ["/tmp/x"] });
  await handler(known);
  assert.equal(known.effect, "allow");
  assert.equal(calls.generate.length, 2);
});

test("NF3：显式配置的 fastpathExtra 仍可放行自定义动作（options 兼容）", async () => {
  const { handler, calls } = await loadHandler({
    options: { fastpathExtra: ["custom-read"] },
    review: [ALLOW],
  });
  const input = baseInput({ action: "Custom-Read ", resources: ["whatever"] });
  await handler(input);
  assert.equal(input.effect, "allow");
  assert.equal(calls.generate.length, 0);
});

// ---------- NF4：压缩视图的键分类保守默认 ----------

const middlePayload = (payload, total = 4400) => {
  const half = Math.floor((total - payload.length) / 2);
  return "a".repeat(half) + payload + "b".repeat(half);
};

test("NF4：未知键/大小写伪装键一律决定性，必须全文审查", async () => {
  const payload = j(["DROP ALL TABLES; ", RMRF, " #"]);
  const big = middlePayload(payload);
  const cases = [
    ["metadata.input.script", { input: { script: big } }],
    ["capital-Patch", { files: [{ path: "/tmp/x", Patch: big }] }],
    ["files[].target 内容混入", { files: [{ path: "/tmp/x", target: big }] }],
    ["任意未知键 whatever", { whatever: big }],
  ];
  for (const [label, metadata] of cases) {
    const view = buildActionView({
      fingerprint: "f".repeat(64),
      action: "mcp_server_runcmd",
      resources: ["*"],
      metadata,
    });
    assert.equal(view.elidedCritical, false, label);
    assert.deepEqual(JSON.parse(view.json).metadata, metadata, label);
    const { handler, calls } = await loadHandler({ review: [ALLOW] });
    const input = baseInput({ action: "mcp_server_runcmd", resources: ["*"], metadata });
    await handler(input);
    assert.deepEqual(JSON.parse(calls.generate[0].prompt.split("ACTION:\n")[1]).metadata, metadata, label);
    assert.equal(input.effect, "allow", label);
  }
});

test("G5：装饰化只限顶层 message，metadata.* 一切键一律决定性", async () => {
  const big = middlePayload("just prose ".repeat(3));
  // 顶层 message 是宿主内建字段：中段省略可安全压缩
  const view = buildActionView({
    fingerprint: "f".repeat(64),
    action: "write",
    resources: ["/tmp/x"],
    metadata: { files: [{ path: "/tmp/x", patch: "+ok" }] },
    message: big,
  }, 4000);
  assert.equal(view.elidedCritical, false, "顶层 message 是唯一装饰字段");
  assert.deepEqual(view.elidedFields, ["message"]);
  // metadata.description 也是决定性工具参数，不能按装饰字段裁剪。
  const view2 = buildActionView({
    fingerprint: "f".repeat(64),
    action: "write",
    resources: ["/tmp/x"],
    metadata: { description: big, files: [{ path: "/tmp/x", patch: "+ok" }] },
  });
  assert.equal(view2.elidedCritical, false);
  assert.equal(JSON.parse(view2.json).metadata.description, big);
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  const input = baseInput({
    action: "mcp_x_send",
    resources: ["*"],
    metadata: { input: { description: big } },
  });
  await handler(input);
  assert.equal(JSON.parse(calls.generate[0].prompt.split("ACTION:\n")[1]).metadata.input.description, big);
  assert.equal(input.effect, "allow", "决定性全文经过审查才可放行");
});

test("minor b：files[] 未枚举路径键纳入写域路径扫描", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  const input = baseInput({
    action: "edit",
    resources: ["ok.txt"],
    metadata: { files: [{ target: j(["/home/u/.", "ssh", "/authorized_keys"]), patch: "+x" }] },
  });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.match(input.message, /hard rule: write-sensitive-path/);
  assert.equal(calls.generate.length, 0);
});

test("minor f：资源数组不再省略条目，预算内完整可见", () => {
  const resources = Array.from({ length: 400 }, (_, i) => `resource-${i}-` + "x".repeat(120));
  const view = buildActionView({ fingerprint: "f".repeat(64), action: "bash", resources, metadata: null });
  assert.ok(view.json.length <= 60_000);
  assert.equal(view.elidedCritical, false);
  assert.deepEqual(JSON.parse(view.json).resources, resources);
});

// ---------- NF5：usage 归属按请求身份（反向交错） ----------

test("NF5：反向交错——弃置请求的迟到响应不能夺走在途请求的 usage", async () => {
  const model = { providerID: "xiaomi-token-plan-cn", id: "mimo-v2.6-pro" };
  let attempt = 0;
  let firstSession = null;
  const { ctx, calls } = makeCtx({ review: [ALLOW, ALLOW] });
  ctx.session.generate = async ({ sessionID }) => {
    attempt += 1;
    if (attempt === 1) {
      firstSession = sessionID;
      throw new Error("provider exploded");
    }
    // 在途请求 B 先报自己的 usage；随后 A 的迟到响应才到（反向交错）
    await calls.fireUsage(model, sessionID, { prompt_tokens: 10, completion_tokens: 5 });
    await calls.fireUsage(model, firstSession, { prompt_tokens: 900_000, completion_tokens: 900_000 });
    return { text: ALLOW };
  };
  const cleanup = await plugin_setup(ctx, calls);
  try {
    await calls.hooks[0].handler(baseInput({ sessionID: "ses_u", resources: ["git push origin a"] }));
    const second = baseInput({ sessionID: "ses_u", resources: ["git push origin b"] });
    await calls.hooks[0].handler(second);
    assert.equal(second.effect, "allow");
    const decision = calls.rpc.emitted.filter((item) => item.name === "decision").at(-1).data;
    assert.equal(decision.input_tokens, 10, "B 的真 usage 不能被领到死 slot 丢弃");
    assert.equal(decision.output_tokens, 5, "A 的 900k 迟到 usage 不能记到 B 头上");
  } finally {
    await cleanup();
  }
});

test("G6：同一请求身份的重复响应使归属不确定 → usage 整体不采信", async () => {
  const model = { providerID: "xiaomi-token-plan-cn", id: "mimo-v2.6-pro" };
  let attempt = 0;
  const { ctx, calls } = makeCtx({ review: [ALLOW, ALLOW] });
  ctx.session.generate = async ({ sessionID }) => {
    attempt += 1;
    if (attempt === 1) throw new Error("provider exploded");
    await calls.fireUsage(model, sessionID, { prompt_tokens: 900_000, completion_tokens: 900_000 });
    await calls.fireUsage(model, sessionID, { prompt_tokens: 10, completion_tokens: 5 });
    return { text: ALLOW };
  };
  const cleanup = await plugin_setup(ctx, calls);
  try {
    await calls.hooks[0].handler(baseInput({ sessionID: "ses_u", resources: ["git push origin a"] }));
    await calls.hooks[0].handler(baseInput({ sessionID: "ses_u", resources: ["git push origin b"] }));
    const decision = calls.rpc.emitted.filter((item) => item.name === "decision").at(-1).data;
    assert.equal(decision.input_tokens, undefined, "同一身份两份响应：归属不确定，宁可少报不虚报");
    assert.equal(decision.output_tokens, undefined);
  } finally {
    await cleanup();
  }
});

test("G6：每次 generate 换新会话，上一代迟到重复响应领不到任何 slot", async () => {
  const model = { providerID: "xiaomi-token-plan-cn", id: "mimo-v2.6-pro" };
  const { ctx, calls } = makeCtx({ review: [ALLOW, ALLOW] });
  const seen = [];
  ctx.session.generate = async ({ sessionID }) => {
    seen.push(sessionID);
    if (seen.length === 1) {
      await calls.fireUsage(model, sessionID, { prompt_tokens: 10, completion_tokens: 5 });
      return { text: ALLOW };
    }
    // 上一代迟到/重放响应（旧会话 ID）先到，再报本代真实 usage
    await calls.fireUsage(model, seen[0], { prompt_tokens: 900_000, completion_tokens: 900_000 });
    await calls.fireUsage(model, sessionID, { prompt_tokens: 7, completion_tokens: 3 });
    return { text: ALLOW };
  };
  const cleanup = await plugin_setup(ctx, calls);
  try {
    await calls.hooks[0].handler(baseInput({ sessionID: "s1", resources: ["git push origin a"] }));
    await calls.hooks[0].handler(baseInput({ sessionID: "s1", resources: ["git push origin b"] }));
  } finally {
    await cleanup();
  }
  assert.equal(seen.length, 2);
  assert.notEqual(seen[0], seen[1], "会话 ID 即请求身份：不跨代复用");
  const decision = calls.rpc.emitted.filter((item) => item.name === "decision").at(-1).data;
  assert.equal(decision.input_tokens, 7, "本代 usage 不受上一代迟到响应污染");
  assert.equal(decision.output_tokens, 3);
});

test("minor c：失败尝试轮换内部会话，迟到 switchModel 不污染后续模型选择", async () => {
  const { ctx, calls } = makeCtx({ review: [ALLOW, ALLOW] });
  let attempt = 0;
  ctx.session.generate = async ({ sessionID }) => {
    attempt += 1;
    if (attempt === 1) throw new Error("provider exploded");
    return { text: ALLOW };
  };
  const cleanup = await plugin_setup(ctx, calls);
  try {
    await calls.hooks[0].handler(baseInput({ resources: ["git push origin a"] }));
    await calls.hooks[0].handler(baseInput({ resources: ["git push origin b"] }));
  } finally {
    await cleanup();
  }
  assert.ok(calls.sessionCreate.length >= 2, "失败尝试换新会话");
  const sessions = new Set(calls.switchModel.map((entry) => entry.sessionID));
  assert.equal(sessions.size, calls.switchModel.length, "每次尝试的 switchModel 都在独立会话上");
});

// ---------- minor e：find 谓词大小写不敏感 ----------

test("minor e：find 的 -EXEC/-Delete 大小写变体不再硬放行", () => {
  for (const cmd of ["find . -EXEC x +", "find . -Delete", "find . -Fprint out", "find . -Ok x +"]) {
    assert.equal(isHardAllowCommand(cmd), false, cmd);
  }
  assert.equal(isHardAllowCommand("find . -type f -print"), true);
});

// ---------- 兼容小工具 ----------

// 装载插件（与 helpers.loadHandler 相同，但允许先改造 ctx）
async function plugin_setup(ctx, calls) {
  const plugin = (await import("../plugin/index.js")).default;
  return plugin.setup(ctx);
}

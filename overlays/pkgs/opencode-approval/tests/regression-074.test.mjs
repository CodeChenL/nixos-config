// tests/regression-074.test.mjs —— 0.7.4 对抗复核缺口回归（G1-G6）。
// 危险字面量仅作为 permission 输入字符串（mock），绝不真实执行；关键字分片构造，
// 避免测试文本自身命中宿主硬规则。

import assert from "node:assert/strict";
import { test } from "node:test";

import plugin, {
  buildActionView,
  buildCommandMatchView,
  commandNeedsReview,
  isHardAllowCommand,
  normalizeLexicalPath,
} from "../plugin/index.js";
import { baseInput, loadHandler, makeCtx } from "./helpers.mjs";

const ALLOW = JSON.stringify({ risk_level: "medium", outcome: "allow", rationale: "reviewed" });
const DENY = JSON.stringify({ risk_level: "high", outcome: "deny", rationale: "not authorized" });
const j = (parts) => parts.join("");
const RB = j(["re", "boot"]);
const RM = j(["r", "m", " -", "r", "f"]);
const RMRF = j([RM, " /"]);
const MK = j(["mk", "f", "s"]);

// ---------- G1：执行位门控（echo 提及矩阵） ----------

test("G1：参数位提及放行矩阵（echo/printf/git commit），真实执行对照拦截", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  const mentions = [
    j(["echo ", RMRF]),
    j(["echo ", MK, " note"]),
    j(["printf '%s' \"", RMRF, "\""]),
    j(["git commit -m \"", RMRF, "\""]),
    j(["echo d", "d", " of=/dev/sda"]),
    j(["grep -n \"", MK, "\" notes.txt"]),
  ];
  for (const cmd of mentions) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.equal(input.effect, "allow", cmd);
    assert.doesNotMatch(String(input.message ?? ""), /hard rule/, cmd);
  }
  const executions = [
    RMRF,
    j(["xargs ", RMRF]),
    j(["sh -c '", RMRF, "'"]),
    j(["eval \"", RMRF, "\""]),
    j(["sudo ", RMRF]),
    j(["dd if=/dev/zero of=/dev/sda"]),
  ];
  for (const cmd of executions) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.equal(input.effect, "deny", cmd);
    assert.match(input.message, /hard rule/, cmd);
  }
});

test("G1：命令域子串规则只认执行位；用户 extraDeny 仍是文本策略", async () => {
  const { handler, calls } = await loadHandler({
    options: { extraDeny: ["deploy-to-prod"] },
    review: [ALLOW],
  });
  // 内置子串规则：参数位提及不硬拒
  const mention = baseInput({ resources: [j(["echo ", MK, " note"])] });
  await handler(mention);
  assert.doesNotMatch(String(mention.message ?? ""), /hard rule/);
  // extraDeny 是用户文本策略：按文档在 blob 上匹配（参数位也命中）
  const userRule = baseInput({ resources: ["./deploy.sh deploy-to-prod"] });
  await handler(userRule);
  assert.equal(userRule.effect, "deny");
  assert.match(userRule.message, /hard rule: extraDeny#0/);
  assert.equal(calls.generate.length, 0, "命中文本策略与硬放行的都不调模型");
});

// ---------- G2：rm-rf-root 路径等价目标 ----------

test("G2：路径等价目标矩阵（//、/.、..、--no-preserve-root）", async () => {
  const { handler } = await loadHandler({ review: [ALLOW] });
  const hits = [
    j([RM, " //"]),
    j([RM, " ///"]),
    j([RM, " /."]),
    j([RM, " /./"]),
    j([RM, " /.//"]),
    j([RM, " /tmp/x/../.."]),
    j([RM, " \"/.\""]),
    j([RM, " /. --no-preserve-root"]),
    j([RM, " --no-preserve-root /"]),
    j([RM, " ."]),
    j([RM, " ./"]),
  ];
  for (const cmd of hits) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.equal(input.effect, "deny", cmd);
    assert.match(input.message, /hard rule: rm-rf-root/, cmd);
  }
  const misses = [
    j([RM, " /tmp/x/.."]),   // 归一化为 /tmp，不是根
    j([RM, " /tmp"]),
    j([RM, " /var/lib/x"]),
    j(["echo ", RM, " //"]), // 提及
    j(["echo ", RM, " /."]),
  ];
  for (const cmd of misses) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.doesNotMatch(String(input.message ?? ""), /hard rule/, cmd);
    assert.equal(input.effect, "allow", cmd);
  }
});

test("G2：词法路径归一化语义", () => {
  assert.equal(normalizeLexicalPath("//"), "/");
  assert.equal(normalizeLexicalPath("///"), "/");
  assert.equal(normalizeLexicalPath("/."), "/");
  assert.equal(normalizeLexicalPath("/./"), "/");
  assert.equal(normalizeLexicalPath("/tmp/x/../.."), "/");
  assert.equal(normalizeLexicalPath("/tmp/x/.."), "/tmp");
  assert.equal(normalizeLexicalPath("."), "/");
  assert.equal(normalizeLexicalPath("./"), "/");
  // 依赖运行时语义的形态不动
  assert.equal(normalizeLexicalPath("~/x/../.."), "~/x/../..");
  assert.equal(normalizeLexicalPath("$TARGET"), "$TARGET");
  assert.equal(normalizeLexicalPath("/*"), "/*");
  assert.equal(normalizeLexicalPath("rm -rf /"), "rm -rf /", "非路径 token 不得被路径归一化改写");
});

// ---------- G3：shell 展开族 ----------

test("G3：ANSI-C 引号与 ${IFS} 分词建模", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  const hits = [
    j(["$'\\x72e", "boot'"]),          // $'\x72eboot'
    j(["$'\\162e", "boot'"]),          // $'\162eboot'
    j([RB, "${IFS}-h"]),               // reboot${IFS}-h
    j(["sh${IFS}-c${IFS}", RB]),       // sh${IFS}-c${IFS}reboot
    j(["i=;sh $i-c ", RB]),            // 静态可解析的变量展开（i= 为空）
    j(["$'\\x72m' -rf /"]),            // ANSI-C 命令词 + 路径等价目标
  ];
  for (const cmd of hits) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.equal(input.effect, "deny", cmd);
    assert.match(input.message, /hard rule/, cmd);
  }
  assert.equal(calls.generate.length, 0);
});

test("G3：无法静态解析的变量展开不做确定性放行（进模型层）", async () => {
  // allow-all 也不能放过变量命令词/脚本参数
  for (const cmd of [j(["$CMD --help"]), j(["${RUNNER} --version"]), j(["sh -c $SCRIPT"])]) {
    assert.equal(commandNeedsReview(cmd), true, cmd);
    const { handler, calls } = await loadHandler({ options: { mode: "allow-all" }, review: [ALLOW] });
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.equal(calls.generate.length, 1, `${cmd} 必须进模型层`);
    assert.equal(input.effect, "allow", "模型裁决生效（allow-all 不得直放）");
  }
  // 硬放行白名单同样拒绝变量命令词/脚本参数
  assert.equal(isHardAllowCommand(j(["$CMD --help"])), false);
  assert.equal(isHardAllowCommand("cat notes.txt"), true);
  // 普通参数里的变量不影响只读白名单（$ 触发 shell 元字符保护，一律转模型层）
  assert.equal(commandNeedsReview("cat notes.txt"), false);
  // 已知边界：变量目标不做求解（转模型层），见 README「已知边界」
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  const input = baseInput({ resources: [j([RM, " \"$TARGET\""])] });
  await handler(input);
  assert.doesNotMatch(String(input.message ?? ""), /hard rule/);
  assert.equal(calls.generate.length, 1, "变量目标交模型层判定");
});

// ---------- G4：eval / su -c 双引号脚本 ----------

test("G4：eval/su/doas 的脚本参数不论引号形态都按嵌套命令判定", async () => {
  const { handler } = await loadHandler({ review: [ALLOW] });
  const hits = [
    j(["eval \"", RMRF, "\""]),
    j(["eval '", RMRF, "'"]),
    j(["su root -c \"", RMRF, "\""]),
    j(["su root -c '", RMRF, "'"]),
    j(["doas -u root -c \"", RMRF, "\""]),
    j(["bash -c \"", RMRF, "\""]),
    j(["eval \"", RB, "\""]),
    j(["su root -c \"", RB, "\""]),
  ];
  for (const cmd of hits) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.equal(input.effect, "deny", cmd);
    assert.match(input.message, /hard rule/, cmd);
  }
  // 同语义两形态裁决一致；脚本里的提及不误伤
  const mentions = [
    j(["eval \"echo ", RMRF, "\""]),
    j(["eval 'echo ", RMRF, "'"]),
    j(["su root -c \"echo ", RB, "\""]),
  ];
  for (const cmd of mentions) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.doesNotMatch(String(input.message ?? ""), /hard rule/, cmd);
    assert.equal(input.effect, "allow", cmd);
  }
});

test("G4：执行位归属——脚本参数内层命令词才算执行位", () => {
  const nested = buildCommandMatchView([j(["eval \"echo ", RMRF, "\""])]);
  const at = nested.text.indexOf("rm");
  assert.ok(at >= 0);
  assert.equal(nested.executed[at], false, "eval 脚本里 echo 的参数不是执行位");
  const direct = buildCommandMatchView([j(["eval \"", RMRF, "\""])]);
  const at2 = direct.text.indexOf("rm");
  assert.equal(direct.executed[at2], true, "eval 脚本里的命令词是执行位");
});

// ---------- G5：装饰化只限顶层 message ----------

test("G5：metadata 深路径装饰键载荷一律决定性（全文审查）", async () => {
  const payload = j(["DROP ALL TABLES; ", RMRF, " #"]);
  const big = "a".repeat(2500) + payload + "b".repeat(2500);
  for (const metadata of [
    { input: { description: big } },
    { input: { message: big } },
    { files: [{ path: "/tmp/x", title: big }] },
    { files: [{ path: "/tmp/x", summary: big }] },
  ]) {
    const view = buildActionView({
      fingerprint: "f".repeat(64),
      action: "mcp_x_send",
      resources: ["*"],
      metadata,
    });
    assert.equal(view.elidedCritical, false);
    assert.deepEqual(JSON.parse(view.json).metadata, metadata);
    const { handler, calls } = await loadHandler({ review: [ALLOW] });
    const input = baseInput({ action: "mcp_x_send", resources: ["*"], metadata });
    await handler(input);
    assert.deepEqual(JSON.parse(calls.generate[0].prompt.split("ACTION:\n")[1]).metadata, metadata);
    assert.equal(input.effect, "allow");
  }
});

// ---------- G6：usage 请求身份 ----------

test("G6：每次 generate 独立会话；重复响应与迟到重放都不产生虚报", async () => {
  const model = { providerID: "xiaomi-token-plan-cn", id: "mimo-v2.6-pro" };
  const { ctx, calls } = makeCtx({ review: [ALLOW, ALLOW, ALLOW] });
  const sessions = [];
  ctx.session.generate = async ({ sessionID }) => {
    sessions.push(sessionID);
    if (sessions.length === 1) {
      await calls.fireUsage(model, sessionID, { prompt_tokens: 10, completion_tokens: 5 });
      return { text: ALLOW };
    }
    if (sessions.length === 2) {
      // 上一代迟到/重放（旧会话 ID）+ 本代真实 usage
      await calls.fireUsage(model, sessions[0], { prompt_tokens: 900_000, completion_tokens: 900_000 });
      await calls.fireUsage(model, sessionID, { prompt_tokens: 7, completion_tokens: 3 });
      return { text: ALLOW };
    }
    // 同一身份两份响应（伪造/重放）→ 归属不确定，usage 不采信
    await calls.fireUsage(model, sessionID, { prompt_tokens: 900_000, completion_tokens: 900_000 });
    await calls.fireUsage(model, sessionID, { prompt_tokens: 4, completion_tokens: 2 });
    return { text: ALLOW };
  };
  const cleanup = await plugin.setup(ctx);
  const handler = calls.hooks[0].handler;
  try {
    await handler(baseInput({ sessionID: "s1", resources: ["git push origin a"] }));
    await handler(baseInput({ sessionID: "s1", resources: ["git push origin b"] }));
    await handler(baseInput({ sessionID: "s1", resources: ["git push origin c"] }));
  } finally {
    await cleanup();
  }
  assert.equal(sessions.length, 3);
  assert.equal(new Set(sessions).size, 3, "会话 ID 即请求身份：不跨代复用");
  const decisions = calls.rpc.emitted.filter((item) => item.name === "decision").map((item) => item.data);
  assert.equal(decisions[0].input_tokens, 10);
  assert.equal(decisions[1].input_tokens, 7, "本代 usage 不受上一代重放污染");
  assert.equal(decisions[2].input_tokens, undefined, "重复响应：宁可少报不虚报");
});

// tests/regression-075.test.mjs —— 0.7.5 封盘收尾回归（N3 位置/特殊参数、N1 heredoc、
// N2 写迹象、N4 会话清理、NBSP 与审计标注）。危险字面量仅作 permission 输入字符串（mock）。

import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";

import { commandNeedsReview, isHardAllowCommand } from "../plugin/index.js";
import { baseInput, loadHandler } from "./helpers.mjs";

const ALLOW = JSON.stringify({ risk_level: "medium", outcome: "allow", rationale: "reviewed" });
const j = (parts) => parts.join("");
const RB = j(["re", "boot"]);
const RM = j(["r", "m", " -", "r", "f"]);
const RMRF = j([RM, " /"]);
const MK = j(["mk", "f", "s"]);

// ---------- N3：位置/特殊参数 ----------

test("N3：sh -c 位置参数在 allow-all 下不得确定性放行（4 形态复现即失败）", async () => {
  const forms = [
    j(["sh -c '$0' ", RB]),
    j(["sh -c '$1' x ", RB]),
    j(["sh -c '$@' x ", RB]),
    j(["sh -c '$0 $1 $2' ", RMRF]),
  ];
  for (const cmd of forms) {
    const { handler, calls } = await loadHandler({ options: { mode: "allow-all" }, review: [ALLOW] });
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.notEqual(input.effect, "allow", cmd);
    assert.match(input.message, /hard rule/, cmd);
    assert.equal(calls.generate.length, 0, `${cmd} 位置参数静态可解析 → 硬拒`);
  }
});

test("N3：$ 后非标识符形态一律 unresolved（不做确定性放行）", async () => {
  // 可静态代入的位置参数（sh -c 尾部实参）已解析；eval 上下文/命令位/运行时特殊参数 → unresolved
  for (const form of ["$0", "$1", "$9", "$@", "$*", "$#"]) {
    assert.equal(commandNeedsReview(j(["eval '", form, "'"])), true, `eval ${form}`);
    assert.equal(commandNeedsReview(j([form, " --help"])), true, `cmd ${form}`);
  }
  for (const form of ["$?", "$$", "$!", "$-"]) {
    assert.equal(commandNeedsReview(j(["sh -c '", form, "' x y"])), true, `runtime ${form}`);
    assert.equal(commandNeedsReview(j(["eval '", form, "'"])), true, `eval ${form}`);
  }
  // 命令词/脚本参数里的特殊参数 → allow-all 也不直放，进模型层
  const { handler, calls } = await loadHandler({ options: { mode: "allow-all" }, review: [ALLOW] });
  const input = baseInput({ resources: [j(["sh -c '$?' echo hi"])] });
  await handler(input);
  assert.equal(calls.generate.length, 1, "无法解析的特殊参数必须进模型层");
  // 普通参数位的特殊参数不新增拦截面（只影响确定性放行）
  assert.equal(commandNeedsReview("cat notes.txt"), false);
  assert.equal(isHardAllowCommand("cat notes.txt"), true);
});

// ---------- N1：heredoc 定界体 ----------

test("N1：heredoc 定界体是数据段（体内危险文本不硬拒）", async () => {
  const body = j([RMRF, "\n", MK, " note\n", RB]);
  const heredoc = j(["cat <<EOF > /tmp/f\n", body, "EOF"]);
  const { handler, calls } = await loadHandler({ options: { mode: "allow-all" }, review: [ALLOW] });
  const input = baseInput({ resources: [heredoc] });
  await handler(input);
  assert.doesNotMatch(String(input.message ?? ""), /hard rule/, "heredoc 体内文本不得当命令段");
  assert.equal(calls.generate.length, 1, "定界体数据只按文本提及处理，转模型层");
  // 同样的字面量作为真实命令仍硬拒（对照）
  const direct = baseInput({ resources: [RMRF] });
  await handler(direct);
  assert.equal(direct.effect, "deny");
  assert.match(direct.message, /hard rule: rm-rf-root/);
  // sh -c 脚本仍硬拒（对照）
  const script = baseInput({ resources: [j(["sh -c '", RMRF, "'"])] });
  await handler(script);
  assert.equal(script.effect, "deny");
  assert.match(script.message, /hard rule: rm-rf-root/);
});

test("N1：复杂定界符/未闭合 heredoc 保守转模型层，allow-all 不直放", async () => {
  const cases = [
    j(["cat <<'EOF'\n", RMRF, "\nEOF"]),
    j(["cat <<$D\n", RMRF, "\n$D"]),
    j(["cat <<EOF\n", RMRF]), // 未闭合
  ];
  for (const cmd of cases) {
    const { handler, calls } = await loadHandler({ options: { mode: "allow-all" }, review: [ALLOW] });
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.doesNotMatch(String(input.message ?? ""), /hard rule/, cmd);
    assert.equal(calls.generate.length, 1, `${cmd} 保守转模型层`);
  }
});

// ---------- N2：写迹象（token 精确匹配） ----------

test("N2：sudoedit 与编辑器族是写迹象；短词按命令词精确匹配不误伤读操作", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  const writers = [
    j(["sudoedit ~/", ".ssh", "/authorized_keys"]),
    j(["vi ~/", ".ssh", "/authorized_keys"]),
    j(["nano ~/", ".ssh", "/authorized_keys"]),
    j(["sudo vi ~/", ".ssh", "/authorized_keys"]),
    j(["vim ~/", ".gnupg", "/gpg.conf"]),
  ];
  for (const cmd of writers) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.equal(input.effect, "deny", cmd);
    assert.match(input.message, /hard rule: write-sensitive-path/, cmd);
  }
  const readers = [
    j(["view ~/", ".ssh", "/id_rsa"]),
    j(["cat ~/", ".ssh", "/id_rsa"]),
    j(["echo ~/", ".ssh", "/id_rsa"]),
    j(["expose ~/", ".ssh", "/id_rsa"]),
  ];
  for (const cmd of readers) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.doesNotMatch(String(input.message ?? ""), /hard rule/, cmd);
    assert.equal(input.effect, "allow", cmd);
  }
});

// ---------- N4：内部审查会话不泄漏 ----------

test("N4：generate 结束即清理内部会话，两轮审查后无残留", async () => {
  const { handler, calls, cleanup } = await loadHandler({ review: [ALLOW, ALLOW] });
  await handler(baseInput({ resources: ["git push origin a"] }));
  await handler(baseInput({ resources: ["git push origin b"] }));
  assert.equal(calls.sessionCreate.length, 2, "每次 generate 独立会话");
  assert.equal(calls.sessionRemove.length, 2, "每次 generate 结束即清理");
  assert.equal(calls.sessionsAlive.size, 0, "两轮审查后无残留内部会话");
  await cleanup();
  assert.equal(calls.sessionRemove.length, 2, "无残留时 cleanup 不重复清理");
});

test("N4：失败/超时尝试同样清理；cleanup 兜底清残留", async () => {
  const { ctx, calls } = await import("./helpers.mjs").then((m) => m.makeCtx({ review: [ALLOW, ALLOW] }));
  ctx.session.generate = async () => {
    throw new Error("provider exploded");
  };
  const plugin = (await import("../plugin/index.js")).default;
  const cleanup = await plugin.setup(ctx);
  const handler = calls.hooks[0].handler;
  await handler(baseInput({ resources: ["git push origin a"] }));
  assert.equal(calls.sessionCreate.length, 1);
  assert.equal(calls.sessionsAlive.size, 0, "失败尝试的会话也立即清理");
  await cleanup();
  assert.equal(calls.sessionsAlive.size, 0);
});

// ---------- NBSP 与审计标注（文档项） ----------

test("NBSP 不再当分词空白（富文本粘贴不误伤）", async () => {
  const { handler } = await loadHandler({ review: [ALLOW] });
  const glued = j([RM, "\u00a0", "/"]); // rm\u00a0-rf\u00a0/
  const input = baseInput({ resources: [glued] });
  await handler(input);
  assert.doesNotMatch(String(input.message ?? ""), /hard rule/, "NBSP 不是 shell 分词空白");
  assert.equal(input.effect, "allow");
  // 普通空白照常命中
  const plain = baseInput({ resources: [RMRF] });
  await handler(plain);
  assert.match(plain.message, /hard rule: rm-rf-root/);
});

test("审计标注：经归一化命中的文案注明，字面命中保持原文案", async () => {
  const dir = fs.mkdtempSync("/tmp/opencode-approval-audit-");
  const auditPath = `${dir}/audit.jsonl`;
  const { handler } = await loadHandler({ options: { auditPath }, review: [ALLOW] });
  await handler(baseInput({ resources: [RMRF] }));
  await handler(baseInput({ resources: [j([RM, " //"])] }));
  const entries = fs
    .readFileSync(auditPath, "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line))
    .filter((entry) => entry.layer !== "setup");
  assert.equal(entries[0].rationale, "hard deny rule: rm-rf-root", "字面命中不加标注");
  assert.match(entries[1].rationale, /hard deny rule: rm-rf-root（经归一化命中）/, "归一化命中文案标注");
  assert.match(entries[1].rationale, /经归一化命中/);
});

test("README 声明封盘：确定性层定位与已知边界", () => {
  const readme = fs.readFileSync(new URL("../README.md", import.meta.url), "utf8");
  assert.match(readme, /确定性层是尽力而为的灾难兜底/);
  assert.match(readme, /正式裁决者/);
  assert.match(readme, /## 已知边界/);
});

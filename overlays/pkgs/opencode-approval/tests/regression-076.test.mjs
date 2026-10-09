// tests/regression-076.test.mjs —— 0.7.6 收口回归：heredoc 谓词误伤、写迹象提及误伤、NBSP 边界声明。
// 危险字面量仅作为 permission 输入字符串（mock），绝不真实执行。

import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";

import { baseInput, loadHandler } from "./helpers.mjs";

const ALLOW = JSON.stringify({ risk_level: "medium", outcome: "allow", rationale: "reviewed" });
const j = (parts) => parts.join("");
const RB = j(["re", "boot"]);
const RMRF = j(["r", "m", " -", "r", "f", " /"]);

// ---------- 1. heredoc 定界体不得进谓词判定 ----------

test("heredoc 正文含 reboot/shutdown/halt 不硬拒（进模型）", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  for (const word of [RB, "shutdown", "halt", "poweroff"]) {
    const heredoc = j(["cat <<EOF > /tmp/f\n", word, "\nEOF"]);
    const input = baseInput({ resources: [heredoc] });
    await handler(input);
    assert.doesNotMatch(String(input.message ?? ""), /hard rule/, heredoc);
    assert.equal(input.effect, "allow", heredoc);
    assert.ok(calls.generate.length >= 1, `${heredoc} 正文只是数据，转模型层`);
  }
  // 多行正文（危险字样在中段）同样不硬拒
  const multiline = j(["cat <<EOF > /tmp/f\nnote\n", RB, "\n", RMRF, "\nEOF"]);
  const input = baseInput({ resources: [multiline] });
  await handler(input);
  assert.doesNotMatch(String(input.message ?? ""), /hard rule/);
  assert.equal(input.effect, "allow");
});

test("heredoc 之外的真实命令仍硬拒（对照）", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  // 段首真实命令
  for (const cmd of [RB, j(["sudo ", RB]), j(["nohup ", "shutdown", " -h now"])]) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.equal(input.effect, "deny", cmd);
    assert.match(input.message, /hard rule: shutdown-reboot-halt/, cmd);
  }
  // heredoc 之后的真实命令仍拦
  const after = j(["cat <<EOF\nbody\nEOF\n", RB]);
  const input = baseInput({ resources: [after] });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.match(input.message, /hard rule: shutdown-reboot-halt/);
  // 正文里的 rm -rf 同样不硬拒，真实 rm 仍拒
  const body = j(["cat <<EOF > /tmp/f\n", RMRF, "\nEOF"]);
  const bodyInput = baseInput({ resources: [body] });
  await handler(bodyInput);
  assert.doesNotMatch(String(bodyInput.message ?? ""), /hard rule/);
  const real = baseInput({ resources: [RMRF] });
  await handler(real);
  assert.match(real.message, /hard rule: rm-rf-root/);
  assert.equal(calls.generate.length, 1, "仅正文提及进模型；真实命令硬拒不调模型");
});

// ---------- 2. 写迹象提及不得误伤（G1 口径） ----------

test("写迹象参数位提及不硬拒，真实写命令仍拦（对照）", async () => {
  const { handler } = await loadHandler({ review: [ALLOW] });
  // 提及：写迹象在参数位/无写意图 → 不硬拒
  const mentions = [
    j(["echo sudoedit ~/", ".ssh", "/x"]),
    j(["printf '%s' '~/.ssh/x'"]),
    j(["echo ~/", ".ssh", "/x"]),
    j(["echo vi ~/", ".ssh", "/authorized_keys"]),
    j(["cat ~/", ".ssh", "/id_rsa.pub"]),
  ];
  for (const cmd of mentions) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.doesNotMatch(String(input.message ?? ""), /hard rule/, cmd);
    assert.equal(input.effect, "allow", cmd);
  }
  // 真实写命令/写意图 → 仍硬拒
  const writers = [
    j(["sudoedit ~/", ".ssh", "/x"]),
    j(["vi ~/", ".ssh", "/authorized_keys"]),
    j(["nano ~/", ".ssh", "/authorized_keys"]),
    j(["echo x > ~/", ".ssh", "/authorized_keys"]),
    j(["su root -c \"cp key ~/", ".gnupg", "/x\""]),
  ];
  for (const cmd of writers) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.equal(input.effect, "deny", cmd);
    assert.match(input.message, /hard rule: write-sensitive-path/, cmd);
  }
});

test("heredoc 正文里的敏感路径提及不硬拒，重定向目标仍拦", async () => {
  const { handler } = await loadHandler({ review: [ALLOW] });
  // 正文提到敏感路径 → 不硬拒
  const body = j(["cat <<EOF > /tmp/f\nsudoedit ~/", ".ssh", "/x\nEOF"]);
  const bodyInput = baseInput({ resources: [body] });
  await handler(bodyInput);
  assert.doesNotMatch(String(bodyInput.message ?? ""), /hard rule/);
  // 重定向目标就是敏感路径 → 仍拦（真实写）
  const redirect = j(["cat <<EOF > ~/", ".ssh", "/authorized_keys\nkey\nEOF"]);
  const redirectInput = baseInput({ resources: [redirect] });
  await handler(redirectInput);
  assert.equal(redirectInput.effect, "deny");
  assert.match(redirectInput.message, /hard rule: write-sensitive-path/);
});

test("git-force-push-main 同口径：heredoc 正文/参数位提及不硬拒，真实 push 仍拦", async () => {
  const { handler } = await loadHandler({ review: [ALLOW] });
  const push = j(["git push --force origin main"]);
  const body = j(["cat <<EOF\ngit push --force origin main\nEOF"]);
  const mention = j(["git commit -m \"git push --force origin main\""]);
  for (const cmd of [body, mention]) {
    const input = baseInput({ resources: [cmd] });
    await handler(input);
    assert.doesNotMatch(String(input.message ?? ""), /hard rule/, cmd);
    assert.equal(input.effect, "allow", cmd);
  }
  const real = baseInput({ resources: [push] });
  await handler(real);
  assert.equal(real.effect, "deny");
  assert.match(real.message, /hard rule: git-force-push-main/);
});

// ---------- 3. 文档边界声明 ----------

test("README 已知边界：NBSP 按保守方向处理（不再作分词空白）", () => {
  const readme = fs.readFileSync(new URL("../README.md", import.meta.url), "utf8");
  assert.match(readme, /NBSP/);
  assert.match(readme, /分词空白/);
  assert.match(readme, /## 已知边界/);
});

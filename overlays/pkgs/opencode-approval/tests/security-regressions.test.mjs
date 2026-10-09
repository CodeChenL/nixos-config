// 全部危险命令仅作为 permission 输入字符串，不启动 shell/子进程。
import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";
import plugin, { buildContextDigest, isHardAllowCommand } from "../plugin/index.js";
import { baseInput, loadHandler, makeCtx } from "./helpers.mjs";

const DENY = JSON.stringify({ risk_level: "high", outcome: "deny", rationale: "not authorized" });
const ALLOW = JSON.stringify({ risk_level: "medium", outcome: "allow", rationale: "reviewed" });
const user = (text) => ({ type: "user", text });
const appeal = (calls, justification = "please reconsider", sessionID = "ses_test") =>
  calls.tools.find((tool) => tool.name === "approval_appeal").execute({ justification }, { sessionID });
const write = (patch = "+safe", overrides = {}) => baseInput({
  action: "write", resources: ["/workspace/out.txt"],
  metadata: { files: [{ path: "/workspace/out.txt", patch }], mode: "replace" }, ...overrides,
});
const deferred = () => {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
};
const loadCustom = async (fixture, configure) => {
  const { ctx, calls } = makeCtx(fixture);
  configure(ctx, calls);
  const cleanup = await plugin.setup(ctx);
  return { handler: calls.hooks[0].handler, calls, cleanup };
};

test("blocker 1：find 的执行、删除、文件输出谓词全部转入模型层", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY] });
  const commands = [
    "find . -delete", "find . -exec arbitrary-program +", "find . -execdir arbitrary-program +",
    "find . -ok arbitrary-program +", "find . -okdir arbitrary-program +",
    "find . -fprint out", "find . -fprint0 out", "find . -fprintf out format", "find . -fls out",
    "find . -fprint-future out", "find . '-delete'", "find . -de\\lete",
  ];
  for (const [i, command] of commands.entries()) {
    assert.equal(isHardAllowCommand(command), false, command);
    const input = baseInput({ resources: [command] });
    await handler(input);
    assert.equal(input.effect, "deny", command);
    assert.equal(calls.generate.length, i + 1, command);
  }
});

test("blocker 1：git branch/remote 写操作、输出和外部程序选项不进白名单", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY] });
  const commands = [
    "git branch -D important", "git branch -d important", "git branch -m important other",
    "git branch -M important other", "git branch --set-upstream-to=origin/main important",
    "git branch --edit-copy important", "git branch --edit-description important",
    "git branch --list -D important", "git branch --list --move important other",
    "git branch new-branch", "git branch -- --list", "git branch --list --unknown-option",
    "git remote set-url origin attacker", "git remote add origin attacker",
    "git remote remove origin", "git remote rename origin other", "git remote set-head origin main",
    "git remote --verbose set-url origin attacker", "git remote update", "git submodule update",
    "git diff --output=out", "git log --output out", "git show --output=out",
    "git diff --ext-diff", "git show --textconv", "git log --show-signature",
    "git log --out=out", "git status --unknown-option", "git -c core.pager=arbitrary status",
  ];
  for (const [i, command] of commands.entries()) {
    assert.equal(isHardAllowCommand(command), false, command);
    await handler(baseInput({ resources: [command] }));
    assert.equal(calls.generate.length, i + 1, command);
  }
});

test("blocker 1：env 任意程序及其他白名单工具的执行/写入模式不硬放行", async () => {
  const commands = [
    "env arbitrary-program", "env", "fd -x arbitrary-program", "fd --exec=arbitrary-program",
    "rg --pre=arbitrary-program pattern", "date --set=2026-10-01", "hostname changed",
    "file -C", "nix eval --write-to out .#value",
  ];
  const { handler, calls } = await loadHandler({ review: [DENY] });
  for (const [i, command] of commands.entries()) {
    assert.equal(isHardAllowCommand(command), false, command);
    await handler(baseInput({ resources: [command] }));
    assert.equal(calls.generate.length, i + 1, command);
  }
});

test("blocker 1：只读 Git/find 参数保持零模型调用，且仅限命令动作", async () => {
  const commands = [
    "git status --short", "git status --porcelain=v2", "git diff --stat", "git diff --cached -- src/a",
    "git log --oneline -5", "git log -n 2 --no-merges", "git show --name-only HEAD",
    "git branch --list", "git branch --list -a -vv main", "git remote", "git remote -v",
    "git remote --verbose", "git remote get-url origin", "git remote get-url --all --push origin",
    "find . -type f -print", "find . -maxdepth 2 -name README.md", "rg -n pattern .", "date -u",
  ];
  const { handler, calls } = await loadHandler({ review: [DENY] });
  for (const command of commands) {
    assert.equal(isHardAllowCommand(command), true, command);
    for (const action of ["bash", "command", "execute", "shell"]) {
      const input = baseInput({ action, resources: [command] });
      await handler(input);
      assert.equal(input.effect, "allow", `${action}: ${command}`);
    }
  }
  assert.equal(calls.generate.length, 0);
});

test("blocker 1：edit/write/patch 资源为 git status 也必须重审", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY] });
  for (const [i, action] of ["edit", "write", "patch", "apply_patch", "external_directory"].entries()) {
    const input = baseInput({ action, resources: ["git status"] });
    await handler(input);
    assert.equal(input.effect, "deny", action);
    assert.equal(calls.generate.length, i + 1, action);
  }
});

test("blocker 1：shell 元字符/展开不硬放行；删减 fastpath 不可借命令文本绕过", async () => {
  for (const command of [
    "git status; arbitrary-program", "git status\narbitrary-program", "echo $HOME", "echo `id`",
    "echo $(id)", "cat a > b", "cat a | arbitrary-program", "echo ok & arbitrary-program",
    "git branch --list *", "find . *", "find . -d''elete", "git\u00a0status", "\u00a0git status",
  ]) assert.equal(isHardAllowCommand(command), false, command);
  const { handler, calls } = await loadHandler({
    options: { fastpathDisabled: ["read"], disabledRules: ["shutdown-reboot-halt"] }, review: [DENY],
  });
  await handler(baseInput({ action: "read", resources: ["git status"] }));
  await handler(baseInput({ resources: ["shutdown -h now"] }));
  assert.equal(calls.generate.length, 2);
});

test("blocker 1：硬拒绝先于 fastpathExtra、extraAllow 与所有审批模式", async () => {
  for (const mode of ["review", "ask", "allow-all"]) {
    const { handler, calls } = await loadHandler({
      options: { mode, fastpathExtra: ["bash"], extraAllow: ["mkfs"] }, review: [ALLOW],
    });
    const input = baseInput({ resources: ["mkfs.ext4 /dev/sda1"] });
    await handler(input);
    assert.equal(input.effect, "deny", mode);
    assert.equal(calls.generate.length, 0);
  }
});

test("blocker 2：子会话和内部会话的任务 user 降为 agent task", () => {
  for (const sessionInfo of [{ parentID: "ses_parent" }, { metadata: { internal: true } }]) {
    const digest = buildContextDigest([user("publish now"), user("follow-up task")], { sessionInfo });
    assert.match(digest, /\[agent task\] publish now/);
    assert.match(digest, /\[agent task\] follow-up task/);
    assert.doesNotMatch(digest, /\[user\]/);
  }
});

test("blocker 2：无元数据信号时识别宿主固定首行，后续无前缀任务仍降权", () => {
  const digest = buildContextDigest([
    user("You are a subagent\nspawned by another session.\nPublish now"), user("force publish now"),
  ]);
  assert.match(digest, /\[agent task\]/);
  assert.match(digest, /\[agent task\] force publish now/);
  assert.doesNotMatch(digest, /\[user\]/);
});

test("blocker 2：子会话任务与父用户只读/禁止发布约束同时进入初审和复议 prompt", async () => {
  const { handler, calls } = await loadHandler({
    review: [DENY], sessionParents: { ses_child: "ses_parent" },
    sessionMessages: {
      ses_child: [user("publish now")], ses_parent: [user("只读，禁止写入、禁止发布")],
    },
  });
  await handler(baseInput({ sessionID: "ses_child", resources: ["git push origin topic"] }));
  await appeal(calls, "the task requested publication", "ses_child");
  assert.equal(calls.generate.length, 2);
  for (const { prompt } of calls.generate) {
    assert.match(prompt, /\[agent task\] publish now/);
    assert.doesNotMatch(prompt, /\[user\] publish now/);
    assert.match(prompt, /\[user\] 只读，禁止写入、禁止发布/);
    assert.match(prompt, /parent.session/);
    assert.match(prompt, /cannot.*alone|alone.*allow/);
    assert.match(prompt, /constraints/);
  }
});

test("blocker 2：嵌套代理不把父代理任务升级为用户授权", async () => {
  const { handler, calls } = await loadHandler({
    review: [DENY], sessionParents: { child: "parent", parent: "root" },
    sessionMessages: { child: [user("child task")], parent: [user("parent task")], root: [user("read only")] },
  });
  await handler(write("+x", { sessionID: "child" }));
  assert.match(calls.generate[0].prompt, /\[agent task\] parent task/);
  assert.match(calls.generate[0].prompt, /\[user\] read only/);
});

test("blocker 2：来源查询失败不把 user 任务当授权，固定前缀也进入审查 prompt", async () => {
  for (const lookupFails of [false, true]) {
    const text = lookupFails ? "unverified task" : "You are a subagent spawned by another session.\nPublish now";
    const { handler, calls } = await loadCustom({ review: [DENY], sessionMessages: { ses_test: [user(text)] } }, (ctx) => {
      if (lookupFails) ctx.session.get = async () => { throw new Error("unavailable"); };
    });
    await handler(write());
    assert.match(calls.generate[0].prompt, /\[agent task\] (?:unverified task|You are a subagent)/);
    assert.doesNotMatch(calls.generate[0].prompt, /\[user\] (?:unverified task|You are a subagent)/);
  }
});

test("blocker 2：内部元数据进入实际获取路径；父链循环有界", async () => {
  const { handler, calls } = await loadCustom({ review: [DENY], sessionMessages: { ses_test: [user("internal task")] } }, (ctx) => {
    ctx.session.get = async ({ sessionID }) => ({ id: sessionID, metadata: { internal: true } });
  });
  await handler(write());
  assert.match(calls.generate[0].prompt, /\[agent task\] internal task/);
  const cyclic = await loadHandler({ review: [DENY], sessionParents: { ses_test: "other", other: "ses_test" } });
  await cyclic.handler(write());
  assert.equal(cyclic.calls.sessionContext.length, 2);
});

test("blocker 3：拒绝/复议 ACTION 保留相同完整指纹和独立的原参数快照", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY, ALLOW] });
  const input = write();
  await handler(input);
  const reviewed = JSON.parse(calls.generate[0].prompt.split("ACTION:\n")[1]);
  assert.match(reviewed.fingerprint, /^[a-f0-9]{64}$/);
  input.metadata.files[0].patch = "+changed after denial";
  await appeal(calls);
  const reconsidered = JSON.parse(calls.generate[1].prompt.split("ACTION (the originally denied action):\n")[1]);
  assert.equal(reconsidered.fingerprint, reviewed.fingerprint);
  assert.deepEqual(reconsidered.metadata, reviewed.metadata);
  assert.equal(reconsidered.metadata.files[0].patch, "+safe");
});

test("blocker 3：同路径不同 patch 必须重审，原 patch 仍只放行一次", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY, ALLOW, DENY] });
  await handler(write());
  await appeal(calls);
  const changed = write("+entirely different operation");
  await handler(changed);
  assert.equal(changed.effect, "deny");
  assert.equal(calls.generate.length, 3, "不同 patch 不能消费 grant");
  const original = write();
  await handler(original);
  assert.equal(original.effect, "allow");
  assert.equal(calls.generate.length, 3);
  const twice = write();
  await handler(twice);
  assert.equal(twice.effect, "deny");
  assert.equal(calls.generate.length, 4);
});

test("blocker 3：files.path、其他 metadata、action、resources、数组边界全都绑定", async () => {
  const variants = [
    write("+safe", { metadata: { files: [{ path: "/workspace/other.txt", patch: "+safe" }], mode: "replace" } }),
    write("+safe", { metadata: { files: [{ path: "/workspace/out.txt", patch: "+safe" }], mode: "append" } }),
    write("+safe", { metadata: { files: [{ path: "/workspace/out.txt", patch: "+safe" }], mode: "replace", extra: true } }),
    write("+safe", { action: "edit" }), write("+safe", { resources: ["/workspace/other.txt"] }),
  ];
  for (const variant of variants) {
    const { handler, calls } = await loadHandler({ review: [DENY, ALLOW, DENY] });
    await handler(write());
    await appeal(calls);
    await handler(variant);
    assert.equal(variant.effect, "deny");
    assert.equal(calls.generate.length, 3);
  }
  const { handler, calls } = await loadHandler({ review: [DENY, ALLOW, DENY] });
  await handler(write("+safe", { resources: ["a\u0001b"] }));
  await appeal(calls);
  const collision = write("+safe", { resources: ["a", "b"] });
  await handler(collision);
  assert.equal(collision.effect, "deny", "旧拼接签名的分隔符碰撞不得复现");
  assert.equal(calls.generate.length, 3);
});

test("blocker 3：对象键顺序不影响同义指纹，数组顺序仍影响", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY, ALLOW, DENY] });
  await handler(write());
  await appeal(calls);
  const reordered = write("+safe", { metadata: { mode: "replace", files: [{ patch: "+safe", path: "/workspace/out.txt" }] } });
  await handler(reordered);
  assert.equal(reordered.effect, "allow");
  assert.equal(calls.generate.length, 2);
  const another = await loadHandler({ review: [DENY, ALLOW, DENY] });
  await another.handler(write("+safe", { metadata: { files: [{ path: "a", patch: "+a" }, { path: "b", patch: "+b" }] } }));
  await appeal(another.calls);
  const reversed = write("+safe", { metadata: { files: [{ path: "b", patch: "+b" }, { path: "a", patch: "+a" }] } });
  await another.handler(reversed);
  assert.equal(reversed.effect, "deny");
});

test("blocker 3：指纹覆盖分块 patch 尾部，尾部修改不能消费 grant", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY, ALLOW, ALLOW, DENY] });
  const prefix = "+x".repeat(33000);
  await handler(write(prefix + "safe"));
  assert.match(calls.generate[0].prompt, /第 1\/2 块/);
  await appeal(calls);
  const changed = write(prefix + "unsafe");
  await handler(changed);
  assert.equal(changed.effect, "deny");
  assert.equal(calls.generate.length, 4);
  await handler(write(prefix + "safe"));
  assert.equal(calls.generate.length, 4, "未变更全文才可消费 grant");
});

test("blocker 4：Promise.all 双发复议只签发一次，并发重试只消费一次", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY, ALLOW], reviewDelayMs: 5 });
  await handler(write());
  const results = await Promise.all([appeal(calls, "first"), appeal(calls, "second")]);
  assert.equal(results.filter((out) => out.content.includes("行政复议通过")).length, 1);
  assert.match(results[1].content, /不存在可复议/);
  assert.equal(calls.generate.length, 2);
  await Promise.all([handler(write()), handler(write())]);
  assert.equal(calls.generate.length, 3, "只有一个重试跳过审查");
  const consumed = calls.rpc.emitted.filter(({ data }) => data.rationale === "行政复议通过（一次性放行）");
  assert.equal(consumed.length, 1);
});

test("blocker 4：首个 grant 消费后，慢的并发复议不能将它复活", async () => {
  const gate = deferred();
  let appealCalls = 0;
  const { handler, calls } = await loadCustom({ review: [DENY, ALLOW] }, (ctx) => {
    const generate = ctx.session.generate;
    ctx.session.generate = async (input) => {
      if (input.prompt.startsWith("You are the appeal reviewer") && ++appealCalls === 2) await gate.promise;
      return generate(input);
    };
  });
  await handler(write());
  const first = appeal(calls, "first");
  const second = appeal(calls, "second");
  await first;
  const retry = write();
  await handler(retry);
  gate.resolve();
  const results = await Promise.all([first, second]);
  assert.equal(retry.effect, "allow");
  assert.equal(results.filter((out) => out.content.includes("行政复议通过")).length, 1);
  assert.equal(appealCalls, 1, "已消费拒绝不能启动第二次复议审查");
  assert.equal(calls.generate.length, 2);
  await handler(write());
  assert.equal(calls.generate.length, 3, "不能再次零审查执行");
});

test("blocker 4：并发驳回 strikes 精确递增，到第三次后不再审查", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY], reviewDelayMs: 5 });
  await handler(write());
  const pair = await Promise.all([appeal(calls, "first"), appeal(calls, "second")]);
  assert.match(pair[0].content, /1\/3/);
  assert.match(pair[1].content, /2\/3/);
  const rest = await Promise.all([appeal(calls, "third"), appeal(calls, "fourth")]);
  assert.match(rest[0].content, /连续第 3 次/);
  assert.match(rest[1].content, /本会话不再受理/);
  assert.equal(calls.generate.length, 4, "原始拒绝 + 三次复议，没有丢失 strikes");
});

test("blocker 4：排队申请绑定拒绝代次，不能复议被替换的新动作", async () => {
  const started = deferred();
  const release = deferred();
  const { handler, calls } = await loadCustom({ review: [DENY, ALLOW, DENY, ALLOW] }, (ctx) => {
    const generate = ctx.session.generate;
    ctx.session.generate = async (input) => {
      if (input.prompt.startsWith("You are the appeal reviewer")) {
        started.resolve();
        await release.promise;
      }
      return generate(input);
    };
  });
  await handler(write());
  const first = appeal(calls, "first");
  await started.promise;
  const replacement = handler(write("+new operation"));
  const stale = appeal(calls, "still appealing old operation");
  release.resolve();
  const [, , result] = await Promise.all([first, replacement, stale]);
  assert.match(result.content, /已过期/);
  assert.equal(calls.generate.length, 3, "新拒绝需要新的复议申请");
});

test("blocker 4：复议与普通模型审查共享单一在途状态", async () => {
  let active = 0;
  let maximum = 0;
  const { handler, calls } = await loadCustom({ review: [DENY, ALLOW], reviewDelayMs: 5 }, (ctx) => {
    const generate = ctx.session.generate;
    ctx.session.generate = async (input) => {
      active += 1;
      maximum = Math.max(maximum, active);
      try { return await generate(input); } finally { active -= 1; }
    };
  });
  await handler(write());
  await Promise.all([appeal(calls), handler(write("+other", { sessionID: "another" }))]);
  assert.equal(maximum, 1);
});

test("blocker 4：过期 grant 销毁，不能重签或在时钟回退后复活", async () => {
  const { handler, calls } = await loadHandler({ review: [DENY, ALLOW] });
  await handler(write());
  await appeal(calls);
  const now = Date.now;
  try {
    Date.now = () => now() + 11 * 60_000;
    await handler(write());
  } finally { Date.now = now; }
  assert.equal(calls.generate.length, 3);
  assert.match((await appeal(calls)).content, /不存在可复议/);
  await handler(write());
  assert.equal(calls.generate.length, 4);
});

test("minor 16：README 配置示例能 setup，所有谓词规则报错列出完整清单", async () => {
  const readme = fs.readFileSync(new URL("../README.md", import.meta.url), "utf8");
  const example = [...readme.matchAll(/```jsonc\n([\s\S]*?)```/g)].find((match) => match[1].includes('"disabledRules"'))[1];
  const options = JSON.parse(example.replace(/\/\/[^\n]*/g, ""));
  const { cleanup } = await loadHandler({ options });
  await cleanup();
  const predicates = ["write-sensitive-path", "git-force-push-main", "shutdown-reboot-halt"];
  for (const name of predicates) {
    await assert.rejects(() => loadHandler({ options: { ruleOverrides: { [name]: { regex: "x" } } } }), (error) => {
      assert.match(error.message, /谓词规则，不支持正则覆盖/);
      for (const predicate of predicates) assert.ok(error.message.includes(predicate));
      assert.match(error.message, /enabled: false.*extraDeny/);
      return true;
    });
  }
});

test("发行元数据：package.json 与 default.nix 同步为 0.7.9", () => {
  const pkg = JSON.parse(fs.readFileSync(new URL("../plugin/package.json", import.meta.url), "utf8"));
  const nix = fs.readFileSync(new URL("../default.nix", import.meta.url), "utf8");
  assert.equal(pkg.version, "0.7.9");
  assert.match(nix, /version = "0\.7\.9";/);
});

// tests/regression-072.test.mjs —— 0.7.2 复核遗留回归：
// N1 层序分域 / N2 git 短形态 / major 5 shutdown 谓词 / major 6 授权撤回 /
// major 7 超长动作 fail-closed / major 8 deadline 覆盖准备 / major 9 超时取消与 usage 归属。
// 所有危险命令仅作为 permission 输入字符串（mock），绝不真实执行。

import assert from "node:assert/strict";
import { test } from "node:test";

import { buildActionView, isHardAllowCommand } from "../plugin/index.js";
import { baseInput, deferred, loadCustom, loadHandler } from "./helpers.mjs";

const ALLOW = JSON.stringify({ risk_level: "medium", outcome: "allow", rationale: "reviewed" });
const DENY = JSON.stringify({ risk_level: "high", outcome: "deny", rationale: "not authorized" });
const user = (text) => ({ type: "user", text });

// ---------- N1：硬规则按动作类别分域 ----------

test("N1：只读查询动作不做硬规则文本扫描（grep/websearch/read/glob/subagent 带危险词仍放行）", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  const cases = [
    ["grep", "mkfs"],
    ["grep", "reboot|shutdown|halt"],
    ["websearch", "reboot stuck after kernel update"],
    ["websearch", "mkfs.xfs /dev/sda fails"],
    ["read", "/var/log/shutdown.log"],
    ["read", "/usr/sbin/mkfs"],
    ["glob", "**/halt*.ts"],
    ["glob", "scripts/reboot*"],
    ["list", "mkfs reboot halt"],
    ["subagent", "reboot-helper"],
    ["question", "shutdown now?"],
    ["skill", "reboot-target"],
  ];
  for (const [action, resource] of cases) {
    const input = baseInput({ action, resources: [resource] });
    await handler(input);
    assert.equal(input.effect, "allow", `${action}: ${resource}`);
    assert.doesNotMatch(String(input.message ?? ""), /hard rule/, `${action}: ${resource}`);
  }
  assert.equal(calls.generate.length, 0, "只读查询回到 0.7.0 行为（fastpath 放行），纯可用性倒退必须消失");
});

test("N1：命令类硬拒绝不变，fastpathExtra 扩白与 allow-all 都不能绕过", async () => {
  for (const mode of ["review", "ask", "allow-all"]) {
    const { handler, calls } = await loadHandler({
      options: { mode, fastpathExtra: ["bash"] },
      review: [ALLOW],
    });
    for (const command of ["mkfs.xfs /dev/sda", "rm -rf /", "git push --force origin main"]) {
      const input = baseInput({ resources: [command] });
      await handler(input);
      assert.equal(input.effect, "deny", `${mode}: ${command}`);
      assert.match(input.message, /hard rule/);
    }
    assert.equal(calls.generate.length, 0, `${mode}: 硬拒绝仍先于一切放行`);
  }
});

test("N1：写/改动作的路径字段仍拦敏感路径与裸设备路径", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  const sensitive = baseInput({
    action: "edit",
    resources: ["/home/u/.ssh/authorized_keys"],
    metadata: { files: [{ path: "/home/u/.ssh/authorized_keys", patch: "+ssh-rsa AAAA" }] },
  });
  await handler(sensitive);
  assert.equal(sensitive.effect, "deny");
  assert.match(sensitive.message, /hard rule: write-sensitive-path/);
  const device = baseInput({
    action: "write",
    resources: ["/dev/nvme0n1"],
    metadata: { files: [{ path: "/dev/nvme0n1", patch: "garbage" }] },
  });
  await handler(device);
  assert.equal(device.effect, "deny");
  assert.match(device.message, /hard rule: overwrite-disk-device/);
  // patch 内容里的危险字样不参与硬规则（编辑"描述危险命令的文档"不该被误伤）
  const doc = baseInput({
    action: "edit",
    resources: ["README.md"],
    metadata: { files: [{ path: "README.md", patch: "+rm -rf / and mkfs.ext4 /dev/sda" }] },
  });
  await handler(doc);
  assert.equal(doc.effect, "allow");
  assert.equal(calls.generate.length, 1, "仅文档 patch 命中危险字样 → 模型层审查");
});

test("N1：extraDeny 默认只作用于命令/写动作，actions 字段显式扩域", async () => {
  const { handler, calls } = await loadHandler({
    options: {
      extraDeny: ["deploy-to-prod", { name: "grep-guard", regex: "forbidden-pattern", actions: ["grep"] }],
    },
    review: [ALLOW],
  });
  const cmd = baseInput({ resources: ["./deploy.sh deploy-to-prod"] });
  await handler(cmd);
  assert.equal(cmd.effect, "deny", "默认域（命令）仍然生效");
  const grepDefault = baseInput({ action: "grep", resources: ["deploy-to-prod"] });
  await handler(grepDefault);
  assert.equal(grepDefault.effect, "allow", "默认不对只读查询文本扫描");
  const grepHit = baseInput({ action: "grep", resources: ["forbidden-pattern"] });
  await handler(grepHit);
  assert.equal(grepHit.effect, "deny", "actions 扩域到 grep");
  assert.match(grepHit.message, /hard rule: grep-guard/);
  assert.equal(calls.generate.length, 0);
});

test("N1：query 分域的 extraDeny 仍先于 fastpath 放行", async () => {
  const { handler, calls } = await loadHandler({
    options: { extraDeny: [{ name: "read-guard", regex: "top-secret", actions: ["read"] }] },
    review: [ALLOW],
  });
  const hit = baseInput({ action: "read", resources: ["/etc/top-secret"] });
  await handler(hit);
  assert.equal(hit.effect, "deny");
  assert.equal(calls.generate.length, 0, "扩域拒绝必须先于 fastpath");
});

// ---------- N2：git 只读短形态 ----------

test("N2：git 只读短形态零模型调用（branch 裸/-r、log -n1/-n 1 等）", async () => {
  const safe = [
    "git branch",
    "git branch -r",
    "git branch -a",
    "git branch -vv",
    "git branch -l",
    "git branch --list",
    "git branch --list main",
    "git branch -l main",
    "git log -n1",
    "git log -n 1",
    "git log -n 3 --oneline",
    "git log -3",
    "git remote get-url --all --push origin",
  ];
  const { handler, calls } = await loadHandler({ review: [DENY] });
  for (const command of safe) {
    assert.equal(isHardAllowCommand(command), true, command);
    const input = baseInput({ resources: [command] });
    await handler(input);
    assert.equal(input.effect, "allow", command);
  }
  assert.equal(calls.generate.length, 0);
  const writes = [
    "git branch new-branch",
    "git branch -d old",
    "git branch -D old",
    "git branch -m a b",
    "git branch -- --list",
    "git log -n1 --output=out",
  ];
  for (const command of writes) {
    assert.equal(isHardAllowCommand(command), false, command);
    await handler(baseInput({ resources: [command] }));
  }
  assert.equal(calls.generate.length, writes.length, "写形态一律进模型层");
});

// ---------- major 5：shutdown 谓词 ----------

test("major 5：shutdown 漏拦修复（sudo [-u user]、绝对路径、sh -c 内层）", async () => {
  const denied = [
    "sudo -u root reboot",
    "sudo --user=root poweroff",
    "sudo --user root halt",
    "doas -u root /sbin/reboot",
    "/usr/bin/systemctl reboot",
    "FOO=1 sudo -n systemctl reboot",
    "bash -c 'reboot'",
    'sh -c "echo x; reboot"',
    "/sbin/halt -f",
  ];
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  for (const command of denied) {
    const input = baseInput({ resources: [command] });
    await handler(input);
    assert.equal(input.effect, "deny", command);
    assert.match(input.message, /hard rule: shutdown-reboot-halt/, command);
  }
  assert.equal(calls.generate.length, 0);
});

test("major 5：引号内文本与远端执行不再误伤", async () => {
  const fine = [
    'echo "notes; reboot"',
    "rg '(reboot|halt)' notes.log",
    "grep shutdown README.md",
    "cat reboot-notes.log",
    "command -v reboot",
    'ssh root@target "sudo reboot"',
    "ssh root@target reboot",
    "awk '{print \"reboot\"}' /etc/hosts",
  ];
  const { handler } = await loadHandler({ review: [ALLOW] });
  for (const command of fine) {
    const input = baseInput({ resources: [command] });
    await handler(input);
    assert.equal(input.effect, "allow", command);
    assert.doesNotMatch(String(input.message ?? ""), /hard rule/, command);
  }
});

// ---------- major 6：授权撤回及时性 ----------

test("major 6：消息事件立即失效上下文缓存（撤回授权进入下一次审查 prompt）", async () => {
  const messages = [user("请修复 TUI 加载失败")];
  const { handler, calls } = await loadHandler({
    // 关掉会话版本信号：这一条只验证事件订阅本身
    sessionSignal: false,
    review: [ALLOW, ALLOW],
    sessionMessages: { ses_test: messages },
  });
  await handler(baseInput({ resources: ["git push origin a"] }));
  assert.match(calls.generate[0].prompt, /请修复 TUI 加载失败/);
  messages.push(user("撤回授权：只读，禁止写入、禁止发布"));
  calls.emitEvent({ type: "session.inbox.delivered", data: { sessionID: "ses_test", inboxID: "ib1" } });
  await handler(baseInput({ resources: ["git push origin b"] }));
  assert.equal(calls.sessionContext.length, 2, "事件到达后必须重取上下文");
  assert.match(calls.generate[1].prompt, /撤回授权：只读，禁止写入、禁止发布/);
});

test("major 6：无事件流时会话版本/消息计数纳入缓存键（追加消息立即重取）", async () => {
  const messages = [user("请修复")];
  const { handler, calls } = await loadHandler({
    events: false,
    review: [ALLOW, ALLOW],
    sessionMessages: { ses_test: messages },
  });
  assert.equal(calls.eventSubscribe, 0, "无事件流时走版本键路径");
  await handler(baseInput({ resources: ["git push origin a"] }));
  messages.push(user("撤回授权：只读"));
  await handler(baseInput({ resources: ["git push origin b"] }));
  assert.equal(calls.sessionContext.length, 2);
  assert.match(calls.generate[1].prompt, /撤回授权：只读/);
});

test("major 6：无任何版本信号时 TTL 显著缩短（缓存仍生效，但远短于 30s）", async () => {
  const { handler, calls } = await loadCustom({ events: false, review: [ALLOW, ALLOW, ALLOW] }, (ctx) => {
    ctx.session.get = async ({ sessionID }) => ({ id: sessionID }); // 无 time/tokens/cost
  });
  await handler(baseInput({ resources: ["git push origin a"] }));
  await handler(baseInput({ resources: ["git push origin b"] }));
  assert.equal(calls.sessionContext.length, 1, "短时间内仍命中缓存");
  const realNow = Date.now;
  try {
    Date.now = () => realNow() + 3_500;
    await handler(baseInput({ resources: ["git push origin c"] }));
  } finally {
    Date.now = realNow;
  }
  assert.equal(calls.sessionContext.length, 2, "降级 TTL（3s）过期后重取，不再是 30s");
});

// ---------- major 7：超长动作 fail-closed ----------

const bigPatch = (middle, total = 4400) => {
  const half = Math.floor((total - middle.length) / 2);
  return "a".repeat(half) + middle + "b".repeat(half);
};

test("major 7：尾部恶意载荷保留在压缩视图里并被审查（不得静默丢弃）", async () => {
  const payload = "rm -rf / # malicious payload";
  const patch = "safe line\n".repeat(500) + payload;
  const { handler, calls } = await loadHandler({ review: [DENY] });
  const input = baseInput({
    action: "write",
    resources: ["/workspace/big.patch"],
    metadata: { files: [{ path: "/workspace/big.patch", patch }] },
  });
  await handler(input);
  const prompt = calls.generate[0].prompt;
  assert.doesNotMatch(prompt, /\[truncated\]/);
  assert.ok(prompt.includes(payload), "尾部载荷必须可见");
  const actionPart = prompt.slice(prompt.indexOf("ACTION:\n") + "ACTION:\n".length);
  assert.ok(actionPart.length <= 60_000);
  assert.equal(JSON.parse(actionPart).metadata.files[0].patch, patch);
  assert.equal(input.effect, "deny", "载荷被审查到并拒绝");
});

test("major 7：预算内中段全文进入审查，不再省略", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  const input = baseInput({
    action: "write",
    resources: ["/workspace/mid.patch"],
    metadata: { files: [{ path: "/workspace/mid.patch", patch: bigPatch("DROP ALL TABLES;") }] },
  });
  await handler(input);
  assert.equal(calls.generate.length, 1);
  const reviewed = JSON.parse(calls.generate[0].prompt.split("ACTION:\n")[1]);
  assert.deepEqual(reviewed.metadata, input.metadata);
  assert.equal(input.effect, "allow", "决定性全文已交模型审查");
});

test("major 7：未超限动作不受压缩/兜底影响", async () => {
  const { handler, calls } = await loadHandler({ review: [ALLOW] });
  const input = baseInput({
    action: "write",
    resources: ["/workspace/out.txt"],
    metadata: { files: [{ path: "/workspace/out.txt", patch: "+ok" }] },
  });
  await handler(input);
  assert.equal(input.effect, "allow");
  assert.equal(calls.generate.length, 1);
  const actionPart = calls.generate[0].prompt.split("ACTION:\n")[1];
  assert.doesNotMatch(actionPart, /\[truncated\]/);
});

test("major 7：buildActionView 覆盖全文指纹，压缩只是展示视图", () => {
  const patch = "x".repeat(6000);
  const snapshot = {
    fingerprint: "f".repeat(64),
    action: "write",
    resources: ["/workspace/out.txt"],
    metadata: { files: [{ path: "/workspace/out.txt", patch }] },
  };
  const view = buildActionView(snapshot);
  assert.ok(view.json.length <= 60_000);
  assert.equal(view.elidedCritical, false);
  assert.ok(!view.json.includes("[truncated]"));
  const parsed = JSON.parse(view.json);
  assert.equal(parsed.fingerprint, snapshot.fingerprint, "指纹仍绑定原始全文");
  assert.equal(parsed.metadata.files[0].patch, patch);
  assert.ok(patch.length > 4000);
});

// ---------- major 8：deadline 覆盖准备阶段 ----------

test("major 8：价格目录查询挂起被限时，不堵死审查队列也不影响裁决", async () => {
  let listCalls = 0;
  const { handler, calls } = await loadCustom(
    {
      options: { priceTimeoutMs: 60 },
      review: [ALLOW, ALLOW],
      reviewUsage: { prompt_tokens: 10, completion_tokens: 5 },
    },
    (ctx) => {
      ctx.model.list = async () => {
        listCalls += 1;
        await new Promise(() => {}); // 永不返回
      };
    },
  );
  const started = Date.now();
  await handler(baseInput({ resources: ["git push origin a"] }));
  await handler(baseInput({ resources: ["git push origin b"] }));
  const elapsed = Date.now() - started;
  assert.ok(elapsed < 2_000, `价格查询限时（${elapsed}ms）`);
  assert.equal(calls.generate.length, 2, "两次审查都完成，队列没被堵死");
  assert.ok(listCalls >= 1);
});

test("major 8：上下文准备受 deadline 封顶，预算耗尽 fail-closed", async () => {
  const { handler } = await loadHandler({
    options: { deadlineMs: 40 },
    review: [ALLOW],
    contextDelayMs: 500,
  });
  const started = Date.now();
  const input = baseInput({ resources: ["git push origin a"] });
  await handler(input);
  const elapsed = Date.now() - started;
  assert.ok(elapsed < 300, `准备阶段纳入 deadline（${elapsed}ms）`);
  assert.equal(input.effect, "deny", "准备耗尽预算 → fail-closed");
});

test("major 8：切模型等准备步骤同样受 deadline 封顶", async () => {
  const { handler } = await loadCustom({ options: { deadlineMs: 40 }, review: [ALLOW] }, (ctx) => {
    ctx.session.switchModel = async () => {
      await new Promise((resolve) => setTimeout(resolve, 500));
    };
  });
  const started = Date.now();
  const input = baseInput({ resources: ["git push origin a"] });
  await handler(input);
  const elapsed = Date.now() - started;
  assert.ok(elapsed < 300, `switchModel 超时（${elapsed}ms）`);
  assert.equal(input.effect, "deny");
});

// ---------- major 9：超时取消 + usage 归属代次 ----------

test("major 9：超时触发取消（session.interrupt），不让旧请求继续存活", async () => {
  const { handler, calls } = await loadCustom({ options: { deadlineMs: 30 }, review: [ALLOW] }, (ctx) => {
    ctx.session.generate = async () => {
      await new Promise((resolve) => setTimeout(resolve, 500));
      return { text: ALLOW };
    };
  });
  const input = baseInput({ resources: ["git push origin a"] });
  await handler(input);
  assert.equal(input.effect, "deny");
  assert.ok(calls.sessionInterrupt.length >= 1, "超时必须请求取消");
  assert.equal(calls.sessionInterrupt[0].sessionID, "ses_approval_internal");
});

test("major 9：迟到的旧请求 usage 不污染新裁决（按请求代次隔离）", async () => {
  const model = { providerID: "xiaomi-token-plan-cn", id: "mimo-v2.6-pro" };
  let attempt = 0;
  const { handler, calls } = await loadCustom({ review: [ALLOW, ALLOW] }, (ctx) => {
    ctx.session.generate = async ({ sessionID }) => {
      attempt += 1;
      if (attempt === 1) {
        // 旧请求：很快失败并被放弃，但底层请求仍存活，稍后迟到上报巨大 usage
        setTimeout(() => {
          void calls.fireUsage(model, sessionID, { prompt_tokens: 900_000, completion_tokens: 900_000 });
        }, 25);
        throw new Error("provider exploded");
      }
      await new Promise((resolve) => setTimeout(resolve, 45));
      await calls.fireUsage(model, sessionID, { prompt_tokens: 10, completion_tokens: 5 });
      return { text: ALLOW };
    };
  });
  const first = baseInput({ sessionID: "ses_pollute", resources: ["git push origin a"] });
  await handler(first);
  assert.equal(first.effect, "deny", "第一次审查失败 fail-closed");
  const second = baseInput({ sessionID: "ses_pollute", resources: ["git push origin b"] });
  await handler(second);
  assert.equal(second.effect, "allow");
  const decision = calls.rpc.emitted.filter((item) => item.name === "decision").at(-1).data;
  assert.equal(decision.input_tokens, 10, "旧请求 usage 不得记到新裁决");
  assert.equal(decision.output_tokens, 5);
});

test("major 9：同一尝试的 usage 仍然正常记录（不因代次隔离丢失）", async () => {
  const { handler, calls } = await loadHandler({
    review: [ALLOW],
    reviewUsage: { prompt_tokens: 1200, completion_tokens: 80 },
  });
  await handler(baseInput({ resources: ["git push origin a"] }));
  const decision = calls.rpc.emitted.filter((item) => item.name === "decision").at(-1).data;
  assert.equal(decision.input_tokens, 1200);
  assert.equal(decision.output_tokens, 80);
});

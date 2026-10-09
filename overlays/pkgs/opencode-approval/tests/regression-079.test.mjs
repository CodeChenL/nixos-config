// 0.7.9：共享模式状态、setup 可见性与 evaluate 最外层 fail-closed。
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";
import plugin from "../plugin/index.js";
import { baseInput, invokeRpc, makeCtx } from "./helpers.mjs";

const ALLOW = JSON.stringify({ risk_level: "low", outcome: "allow", rationale: "fine" });
const mode = (calls, arg = "", sessionID = "ses_mode") => invokeRpc(calls, "mode", { arg, sessionID });
const status = (calls) => invokeRpc(calls, "status", {});
const entries = (ctx) => fs.readFileSync(ctx.options.auditPath, "utf8").trim().split("\n").map(JSON.parse);
const saved = (mode) => ({ mode, setBy: "/approval-mode", sessionID: "ses_saved", ts: new Date().toISOString() });

async function start(t, fixture = {}, configure, implementation = plugin) {
  const { ctx, calls } = makeCtx({ review: [ALLOW], ...fixture });
  const directory = path.dirname(ctx.options.auditPath);
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  if (configure) configure(ctx, calls);
  const cleanup = await implementation.setup(ctx);
  t.after(cleanup);
  return { ctx, calls, handler: calls.hooks[0].handler, cleanup };
}

test("statePath 默认是 home 下 approval-state.json，查询展示路径且读取不创建状态", async (t) => {
  const instance = await start(t, {}, (ctx) => {
    const home = path.dirname(ctx.options.auditPath);
    t.mock.method(os, "homedir", () => home);
    delete ctx.options.statePath;
  });
  const expected = path.join(os.homedir(), ".local/share/opencode/approval-state.json");
  const result = await status(instance.calls);
  assert.equal(result.statePath, expected);
  assert.equal(result.modeSource, "config");
  assert.ok((await mode(instance.calls)).text.includes(expected));
  assert.equal(fs.existsSync(expected), false);
  await mode(instance.calls, "ask");
  assert.equal(JSON.parse(fs.readFileSync(expected, "utf8")).mode, "ask");
});

test("模式写入仅四个状态字段、0600；同目录临时文件+rename 原子替换而非原地截断", async (t) => {
  const { ctx, calls } = await start(t);
  await mode(calls, "ask");
  const before = fs.readFileSync(ctx.options.statePath, "utf8");
  fs.chmodSync(ctx.options.statePath, 0o644);
  const oldHandle = fs.openSync(ctx.options.statePath, "r");
  t.after(() => fs.closeSync(oldHandle));
  const rename = fs.renameSync;
  let observed = false;
  t.mock.method(fs, "renameSync", (temporary, destination) => {
    assert.equal(destination, ctx.options.statePath);
    assert.equal(path.dirname(temporary), path.dirname(destination));
    assert.equal(fs.readFileSync(destination, "utf8"), before);
    assert.equal(fs.statSync(temporary).mode & 0o777, 0o600);
    assert.equal(JSON.parse(fs.readFileSync(temporary, "utf8")).mode, "allow-all");
    observed = true;
    return rename(temporary, destination);
  });
  await mode(calls, "allow", "ses_writer");
  assert.ok(observed);
  const record = JSON.parse(fs.readFileSync(ctx.options.statePath, "utf8"));
  assert.deepEqual(Object.keys(record).sort(), ["mode", "sessionID", "setBy", "ts"]);
  assert.equal(record.mode, "allow-all");
  assert.equal(record.sessionID, "ses_writer");
  assert.equal(record.setBy, "/approval-mode");
  assert.ok(Number.isFinite(Date.parse(record.ts)));
  assert.equal(fs.statSync(ctx.options.statePath).mode & 0o777, 0o600);
  assert.equal(fs.readFileSync(oldHandle, "utf8"), before);
  assert.equal(fs.readdirSync(path.dirname(ctx.options.statePath)).some((name) => name.endsWith(".tmp")), false);
});

for (const selected of ["review", "ask", "allow-all"]) {
  test(`两个独立 setup 共享状态：重启继承 ${selected}，来源与实际裁决一致`, async (t) => {
    const first = await start(t);
    await mode(first.calls, selected);
    assert.match((await mode(first.calls)).text, /本节点覆盖（已持久化）/);
    await first.cleanup();
    const next = await start(t, { options: { statePath: first.ctx.options.statePath, mode: selected === "review" ? "ask" : "review" } });
    assert.equal((await status(next.calls)).mode, selected);
    assert.equal((await status(next.calls)).modeSource, "persisted");
    assert.match((await mode(next.calls)).text, /持久化状态/);
    const input = baseInput({ resources: ["npm run build"] });
    await next.handler(input);
    assert.equal(input.effect, selected === "ask" ? "ask" : "allow");
    assert.equal(next.calls.generate.length, selected === "review" ? 1 : 0);
    assert.equal(entries(next.ctx)[0].rationale, `plugin active, mode=${selected}, source=persisted`);
  });
}

test("已加载节点也同步切换/default，清除旧 runtime 覆盖并恢复各自配置", async (t) => {
  const a = await start(t, { options: { mode: "ask" } });
  const b = await start(t, { options: { statePath: a.ctx.options.statePath } });
  await mode(a.calls, "allow-all");
  const input = baseInput({ resources: ["npm run build"] });
  await b.handler(input); // 无需先查询状态，也不需要重新 setup
  assert.equal(input.effect, "allow");
  assert.equal(b.calls.generate.length, 0);
  assert.equal((await status(b.calls)).modeSource, "persisted");
  await mode(b.calls, "review");
  const reviewed = baseInput({ resources: ["npm run build"] });
  await a.handler(reviewed);
  assert.equal(a.calls.generate.length, 1);
  assert.equal((await status(a.calls)).modeSource, "persisted");
  await mode(a.calls, "default");
  assert.equal(fs.existsSync(a.ctx.options.statePath), false);
  assert.equal((await status(a.calls)).mode, "ask");
  assert.equal((await status(b.calls)).mode, "review");
  assert.equal((await status(b.calls)).modeSource, "config");
  const restarted = await start(t, { options: { statePath: a.ctx.options.statePath } });
  assert.equal((await status(restarted.calls)).modeSource, "config");
});

test("default/reset 幂等且仍接受 allowAll 配置默认", async (t) => {
  const { calls, ctx } = await start(t, { options: { allowAll: true } });
  await mode(calls, "review");
  for (const arg of ["default", "reset"]) {
    assert.match((await mode(calls, arg)).text, /已恢复配置默认模式：allow-all/);
    assert.equal(fs.existsSync(ctx.options.statePath), false);
    assert.equal((await status(calls)).modeSource, "config");
  }
});

test("缺失/损坏/非法状态回退配置，不能把错误值归一成允许模式", async (t) => {
  const invalid = ["{", "null", "[]", "true", "{}", JSON.stringify(saved("ALLOW-ALL")),
    JSON.stringify(saved(true)), JSON.stringify({ ...saved("allow-all"), ts: "broken" }),
    JSON.stringify({ ...saved("allow-all"), sessionID: null }), JSON.stringify({ mode: "allow-all" })];
  for (const content of invalid) {
    const { ctx, calls } = await start(t, { options: { mode: "ask" } }, (ctx) => {
      fs.writeFileSync(ctx.options.statePath, content);
    });
    assert.equal((await status(calls)).mode, "ask", content);
    assert.equal((await status(calls)).modeSource, "config", content);
    assert.equal(entries(ctx)[0].rationale, "plugin active, mode=ask, source=config");
  }
});

test("读取 EACCES 不抛错，setup/后续审批均回退配置", async (t) => {
  const read = fs.readFileSync;
  const { calls, handler } = await start(t, { options: { mode: "ask" } }, (ctx) => {
    fs.writeFileSync(ctx.options.statePath, JSON.stringify(saved("allow-all")));
    t.mock.method(fs, "readFileSync", (file, ...args) => {
      if (file === ctx.options.statePath) throw Object.assign(new Error("denied"), { code: "EACCES" });
      return read(file, ...args);
    });
  });
  assert.equal((await status(calls)).modeSource, "config");
  const input = baseInput({ resources: ["npm run build"] });
  await handler(input);
  assert.equal(input.effect, "ask");
});

test("状态后来损坏时清除本节点 allow-all 覆盖，不沿用陈旧值", async (t) => {
  const { ctx, calls, handler } = await start(t);
  await mode(calls, "allow-all");
  fs.writeFileSync(ctx.options.statePath, "{");
  const input = baseInput({ resources: ["npm run build"] });
  await handler(input);
  assert.equal(calls.generate.length, 1);
  assert.equal((await status(calls)).modeSource, "config");
});

test("rename 失败不切换、不破坏旧状态，清理临时文件并报告失败", async (t) => {
  const { ctx, calls } = await start(t);
  await mode(calls, "review");
  const before = fs.readFileSync(ctx.options.statePath, "utf8");
  t.mock.method(fs, "renameSync", () => { throw new Error("rename unavailable"); });
  assert.match((await mode(calls, "allow-all")).text, /模式未切换.*rename unavailable/);
  assert.equal(fs.readFileSync(ctx.options.statePath, "utf8"), before);
  assert.equal((await status(calls)).mode, "review");
  assert.equal(entries(ctx).at(-1).effect, "deny");
  assert.equal(fs.readdirSync(path.dirname(ctx.options.statePath)).some((name) => name.endsWith(".tmp")), false);
});

test("无法创建状态目录时明确报错且不放松内存模式", async (t) => {
  const { ctx, calls } = await start(t, {}, (ctx) => {
    fs.writeFileSync(ctx.options.statePath, "not a directory");
    ctx.options.statePath = path.join(ctx.options.statePath, "nested.json");
  });
  assert.match((await mode(calls, "allow-all")).text, /模式未切换/);
  assert.equal((await status(calls)).mode, "review");
  assert.equal(entries(ctx).at(-1).effect, "deny");
});

test("删除失败不能谎报已恢复默认，状态与内存保持原模式", async (t) => {
  const { ctx, calls } = await start(t);
  await mode(calls, "ask");
  const unlink = fs.unlinkSync;
  const mocked = t.mock.method(fs, "unlinkSync", (file) => {
    if (file === ctx.options.statePath) throw Object.assign(new Error("read only"), { code: "EROFS" });
    return unlink(file);
  });
  assert.match((await mode(calls, "default")).text, /模式未切换.*read only/);
  assert.equal((await status(calls)).mode, "ask");
  assert.equal(JSON.parse(fs.readFileSync(ctx.options.statePath, "utf8")).mode, "ask");
  mocked.mock.restore();
});

test("三个独立进程并发切换：读取始终完整 JSON、0600、最后写入覆盖且无临时残留", async (t) => {
  const { ctx, calls } = await start(t);
  await mode(calls, "review");
  const script = `
    import plugin from ${JSON.stringify(new URL("../plugin/index.js", import.meta.url).href)};
    import { makeCtx, invokeRpc } from ${JSON.stringify(new URL("./helpers.mjs", import.meta.url).href)};
    import fs from 'node:fs';
    import path from 'node:path';
    const { ctx, calls } = makeCtx({ options: { statePath: process.argv[1] }, events: false });
    const cleanup = await plugin.setup(ctx);
    process.send('ready');
    await new Promise(resolve => process.once('message', resolve));
    for (let i = 0; i < 40; i++) {
      const result = await invokeRpc(calls, 'mode', { arg: ['ask', 'review', 'allow-all'][i % 3], sessionID: 'ses_' + process.pid });
      if (!result.text.includes('已切换为')) throw new Error(result.text);
    }
    await cleanup();
    fs.rmSync(path.dirname(ctx.options.auditPath), { recursive: true, force: true });
    process.disconnect();
  `;
  const children = Array.from({ length: 3 }, () => spawn(process.execPath,
    ["--input-type=module", "-e", script, ctx.options.statePath], { stdio: ["ignore", "ignore", "pipe", "ipc"] }));
  t.after(() => children.forEach((child) => { if (child.exitCode === null) child.kill(); }));
  let stderr = "";
  for (const child of children) child.stderr.on("data", (chunk) => { stderr += chunk; });
  const finished = Promise.all(children.map(async (child) => {
    const [code] = await once(child, "exit");
    assert.equal(code, 0, stderr);
  }));
  await Promise.all(children.map((child) => once(child, "message")));
  let active = true;
  const completion = finished.finally(() => { active = false; });
  for (const child of children) child.send("go");
  let reads = 0;
  while (active) {
    const record = JSON.parse(await fs.promises.readFile(ctx.options.statePath, "utf8"));
    assert.ok(["ask", "review", "allow-all"].includes(record.mode));
    assert.equal(fs.statSync(ctx.options.statePath).mode & 0o777, 0o600);
    reads++;
  }
  await completion;
  assert.ok(reads > 0);
  await mode(calls, "review", "ses_last_writer");
  assert.equal(JSON.parse(fs.readFileSync(ctx.options.statePath, "utf8")).sessionID, "ses_last_writer");
  assert.equal(fs.readdirSync(path.dirname(ctx.options.statePath)).some((name) => name.endsWith(".tmp")), false);
});

test("setup 心跳包含模式来源与节点目录，RPC 不可用也记录，不混入面板裁决", async (t) => {
  for (const rpcError of [null, new Error("rpc unsupported")]) {
    const { ctx, calls } = await start(t, { rpcError }, (ctx) => {
      ctx.location = { directory: "/workspace/test-location" };
    });
    const [entry] = entries(ctx);
    assert.equal(entries(ctx).length, 1);
    assert.equal(entry.layer, "setup");
    assert.equal(entry.effect, "allow");
    assert.equal(entry.rationale, "plugin active, mode=review, source=config");
    assert.deepEqual(entry.resources, ["/workspace/test-location"]);
    assert.equal(calls.rpc.emitted.length, 0);
    if (!rpcError) assert.deepEqual((await status(calls)).decisions, []);
  }
});

test("同步未预期异常即使 onFailure=ask 也 deny，损坏输入不妨碍 failure 审计", async (t) => {
  const { handler, ctx, calls } = await start(t, { options: { onFailure: "ask" } });
  for (const property of ["action", "resources"]) {
    const input = baseInput();
    Object.defineProperty(input, property, { get() { throw new Error(`${property} broken`); } });
    await assert.doesNotReject(handler(input));
    assert.equal(input.effect, "deny");
    assert.match(input.message, new RegExp(`plugin internal error: ${property} broken`));
    assert.equal(entries(ctx).at(-1).layer, "failure");
    assert.equal(entries(ctx).at(-1).effect, "deny");
    assert.equal(entries(ctx).at(-1).rationale, `plugin internal error: ${property} broken`);
    assert.equal(calls.rpc.emitted.at(-1).data.layer, "failure");
  }
  assert.equal(calls.generate.length, 0);
});

test("异步审批队列中抛错被最外层捕获，队列不被污染，后续正常审查可继续", async (t) => {
  const { handler, ctx, calls } = await start(t, { options: { onFailure: "ask" } });
  const input = baseInput({ resources: ["npm run build"] });
  Object.defineProperty(input, "message", { get() { throw new Error("message broken"); } });
  await assert.doesNotReject(handler(input));
  assert.equal(input.effect, "deny");
  assert.equal(entries(ctx).at(-1).rationale, "plugin internal error: message broken");
  const next = baseInput({ resources: ["npm run build"] });
  await handler(next);
  assert.equal(next.effect, "allow");
  assert.equal(calls.generate.length, 1);
});

test("异常对象也不可读时仍 deny 并记录 unknown error", async (t) => {
  const { handler, ctx } = await start(t);
  const input = baseInput();
  const error = { get message() { throw new Error("nested exception"); } };
  Object.defineProperty(input, "action", { get() { throw error; } });
  await assert.doesNotReject(handler(input));
  assert.equal(input.effect, "deny");
  assert.equal(entries(ctx).at(-1).rationale, "plugin internal error: unknown error");
});

test("审计存储失效不能让内部异常逃逸或恢复 ask", async (t) => {
  const { handler, calls } = await start(t);
  t.mock.method(fs, "appendFileSync", () => { throw new Error("disk full"); });
  const input = baseInput({ resources: 123 });
  await assert.doesNotReject(handler(input));
  assert.equal(input.effect, "deny");
  assert.equal(calls.rpc.emitted.at(-1).data.layer, "failure");
});

test("故障注入漏裁决分支：宿主初值 ask/allow/undefined 都不能被当作已裁决", async (t) => {
  // 只变异测试加载的模块，不添加生产测试开关；模拟后续回归跳过模型而忘记设置 effect。
  const source = fs.readFileSync(new URL("../plugin/index.js", import.meta.url), "utf8");
  const needle = "await modelReview(input);";
  assert.equal(source.split(needle).length, 2);
  const mutated = source.replace(needle, "return; // injected undecided branch");
  const implementation = (await import(`data:text/javascript;base64,${Buffer.from(mutated).toString("base64")}`)).default;
  const { handler, ctx } = await start(t, { options: { onFailure: "ask" } }, null, implementation);
  for (const effect of ["ask", "allow", undefined]) {
    const input = baseInput({ effect, resources: ["npm run build"] });
    await handler(input);
    assert.equal(input.effect, "deny");
    assert.equal(entries(ctx).at(-1).rationale, "evaluate returned undecided");
    assert.equal(entries(ctx).at(-1).layer, "failure");
  }
});

test("显式 ask 必须明确赋值并有 ask 审计，不能被未决策防御误拒或继承 allow", async (t) => {
  const { handler, ctx } = await start(t, { options: { mode: "ask" } });
  for (const effect of ["ask", "allow", undefined]) {
    const input = baseInput({ effect, resources: ["npm run build"] });
    await handler(input);
    assert.equal(input.effect, "ask");
    assert.equal(entries(ctx).at(-1).layer, "ask");
    assert.equal(entries(ctx).at(-1).effect, "ask");
  }
});

test("发行版本与状态/异常语义文档一致：0.7.9，零依赖", () => {
  const pkg = JSON.parse(fs.readFileSync(new URL("../plugin/package.json", import.meta.url), "utf8"));
  const nix = fs.readFileSync(new URL("../default.nix", import.meta.url), "utf8");
  const readme = fs.readFileSync(new URL("../README.md", import.meta.url), "utf8");
  assert.equal(pkg.version, "0.7.9");
  assert.equal(pkg.dependencies, undefined);
  assert.match(nix, /version = "0\.7\.9"/);
  for (const term of ["statePath", "0600", "plugin internal error", "evaluate returned undecided", "plugin active"])
    assert.ok(readme.includes(term), term);
});

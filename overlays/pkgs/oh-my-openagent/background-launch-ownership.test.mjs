import assert from "node:assert/strict";
import { test } from "node:test";
import { context } from "./background-lifecycle.fixture.mjs";
import { launchFixture, settleLaunch } from "./background-launch.fixture.mjs";

for (const message of ["HTTP 400 old launch A", "Agent not found: fixture", "HTTP 429 rate limit A"]) {
  test(`initial launch: stale ${message} cannot enter any fallback or interrupt B`, async (suite) => {
    const fixture = launchFixture(suite);
    fixture.task.fallbackChain = [{ providers: ["fixture"], model: "fallback" }];
    await fixture.start(); await settleLaunch();
    assert.equal(fixture.sdk.length, 1);
    assert.equal(fixture.sdk[0].query.directory, "/isolated-project");
    assert.equal(fixture.sdk[0].body.agent, "fixture");
    assert.equal(fixture.task.status, "running");
    await fixture.next();
    assert.equal(fixture.task.currentAttemptID, "same-attempt");
    const before = fixture.snapshot();
    fixture.initial.reject(new Error(message)); await settleLaunch(); await fixture.release();
    assert.deepEqual(fixture.snapshot(), before);
  });
}
for (const changed of ["cancel", "identity", "session", "attempt"]) {
  test(`initial launch: ${changed} invalidates captured launch owner`, async (suite) => {
    const fixture = launchFixture(suite);
    await fixture.start(); await settleLaunch();
    const { manager, task } = fixture;
    if (changed === "cancel") await manager.cancelTask(task.id, { skipNotification: true });
    if (changed === "identity") manager.tasks.set(task.id, structuredClone(task));
    if (changed === "session") task.sessionId = "different-session";
    if (changed === "attempt") task.currentAttemptID = "different-attempt";
    await fixture.occupy();
    const before = fixture.snapshot();
    fixture.initial.reject(new Error("HTTP 400 old A")); await settleLaunch(); await fixture.release();
    assert.deepEqual(fixture.snapshot(), before);
    if (changed === "identity") assert.equal(manager.tasks.get(task.id).status, "running");
  });
}
test("initial launch: stale retry helper cannot release B's newer same-source reservation before catch", async (suite) => {
  const fixture = launchFixture(suite);
  await fixture.start(); await settleLaunch(); await fixture.next(); await fixture.occupy();
  assert.equal(context.promptAsyncReservations.get("child").source, "model-suggestion-retry");
  const before = fixture.snapshot();
  fixture.initial.reject(new Error("Agent not found: fixture")); await settleLaunch();
  assert.deepEqual(fixture.snapshot(), before);
});
for (const outcome of ["resolve", "reject"]) {
  test(`initial launch: agent retry ${outcome} after resume cannot change agent or finalize B`, async (suite) => {
    const fixture = launchFixture(suite);
    await fixture.start(); await settleLaunch();
    fixture.initial.reject(new Error("Agent not found: fixture")); await settleLaunch();
    assert.equal(fixture.sdk.length, 2);
    assert.equal(fixture.sdk[1].body.agent, "general");
    await fixture.next();
    const before = fixture.snapshot();
    if (outcome === "resolve") fixture.retry.resolve({ response: { status: 204 } });
    else fixture.retry.reject(new Error("Agent not found: general"));
    await settleLaunch(); await fixture.release();
    assert.deepEqual(fixture.snapshot(), before);
    assert.equal(fixture.task.agent, "fixture");
  });
}
for (const phase of ["parent", "create", "callback"]) {
  test(`initial launch: ${phase} await cannot rebind same-session/attempt resumed B`, async (suite) => {
    const fixture = launchFixture(suite, phase);
    const operation = fixture.start(); await settleLaunch();
    assert.ok(fixture.effects.setup.includes(phase));
    await fixture.next();
    const before = fixture.snapshot();
    fixture.setup.resolve(); await operation; await settleLaunch();
    const after = fixture.snapshot();
    assert.equal(after.releases, before.releases + 1, "release only abandoned pre-bind A permit");
    after.releases = before.releases;
    assert.deepEqual(after, before);
    assert.equal(fixture.sdk.length, 1, "only B was dispatched");
  });
}
for (const phase of ["create", "callback"]) {
  test(`initial launch: stale ${phase} rejection cannot escape into processKey error cleanup`, async (suite) => {
    const fixture = launchFixture(suite, phase);
    const operation = fixture.start(); await settleLaunch();
    await fixture.next();
    const before = fixture.snapshot();
    fixture.setup.reject(new Error(`old ${phase} failure`)); await operation; await settleLaunch();
    const after = fixture.snapshot();
    assert.equal(after.releases, before.releases + 1);
    after.releases = before.releases;
    assert.deepEqual(after, before);
  });
}
for (const phase of ["gate", "agent-gate"]) {
  test(`initial launch: actual ${phase} revalidation must not send A after B resumes`, async (suite) => {
    const fixture = launchFixture(suite, phase);
    await fixture.start(); await settleLaunch();
    if (phase === "agent-gate") {
      fixture.initial.reject(new Error("Agent not found: fixture")); await settleLaunch();
      assert.equal(fixture.sdk.length, 1);
    } else assert.equal(fixture.sdk.length, 0);
    assert.ok(fixture.effects.setup.includes(phase));
    await fixture.next();
    const before = fixture.snapshot();
    fixture.setup.resolve(); await settleLaunch();
    assert.deepEqual(fixture.snapshot(), before);
  });
}
test("initial launch: actual nonretryable fallback returning false late cannot terminalize B", async (suite) => {
  const fixture = launchFixture(suite);
  const fallback = fixture.manager.tryFallbackRetry;
  fixture.manager.tryFallbackRetry = async (...args) => {
    const result = await fallback.apply(fixture.manager, args);
    assert.equal(result, false); await fixture.setup.promise; return result;
  };
  await fixture.start(); await settleLaunch();
  fixture.initial.reject(new Error("HTTP 400 old A")); await settleLaunch();
  await fixture.next();
  const before = fixture.snapshot();
  fixture.setup.resolve(); await settleLaunch(); await fixture.release();
  assert.deepEqual(fixture.snapshot(), before);
});
for (const phase of ["abort", "context"]) {
  test(`initial launch: real model fallback ${phase} await cannot queue or notify resumed B`, async (suite) => {
    const fixture = launchFixture(suite);
    fixture.task.fallbackChain = [{ providers: ["fixture"], model: "fallback" }];
    await fixture.start(); await settleLaunch();
    const originalResolve = fixture.manager.resolveParentWakePromptContext.bind(fixture.manager);
    if (phase === "context") fixture.manager.resolveParentWakePromptContext = async (...args) => {
      await fixture.setup.promise; return originalResolve(...args);
    };
    else fixture.setup.resolve();
    fixture.initial.reject(new Error("HTTP 429 rate limit A")); await settleLaunch();
    assert.equal(fixture.task.status, "pending");
    assert.equal(fixture.task.attempts.length, 2, "actual fallback advances attempt before abort await");
    assert.equal(fixture.effects.aborts, 1);
    if (phase === "context") { fixture.abort.resolve(); await settleLaunch(); }
    const attempt = context.bindAttemptSession(fixture.task, fixture.task.currentAttemptID, "child");
    assert.ok(attempt);
    await fixture.next();
    const before = fixture.snapshot();
    fixture.abort.resolve(); fixture.setup.resolve(); await settleLaunch();
    assert.deepEqual(fixture.snapshot(), before);
  });
}
test("initial launch: current HTTP 400 interrupts once and sends one genuine failure notice", async (suite) => {
  const fixture = launchFixture(suite);
  await fixture.start(); await settleLaunch();
  fixture.initial.reject(new Error("HTTP 400 current launch")); await settleLaunch(); await fixture.release();
  assert.equal(fixture.task.status, "interrupt");
  assert.equal(fixture.task.error, "HTTP 400 current launch");
  assert.equal(fixture.effects.aborts, 1);
  assert.equal(fixture.effects.releases, 1);
  assert.equal(fixture.effects.wakes.length, 1);
  assert.equal(fixture.effects.wakes[0].shouldReply, true);
  assert.equal(fixture.manager.pendingByParent.size, 0);
});
test("initial launch: current agent fallback still dispatches and records general", async (suite) => {
  const fixture = launchFixture(suite);
  await fixture.start(); await settleLaunch();
  fixture.initial.reject(new Error("Agent not found: fixture")); await settleLaunch();
  assert.equal(fixture.sdk[1].body.agent, "general");
  fixture.retry.resolve({ response: { status: 204 } }); await settleLaunch();
  assert.equal(fixture.task.agent, "general");
  assert.equal(fixture.task.status, "running");
  assert.equal(fixture.effects.wakes.length, 0);
});
test("initial launch: current model fallback advances attempt, queues retry and sends retry notice", async (suite) => {
  const fixture = launchFixture(suite);
  fixture.task.fallbackChain = [{ providers: ["fixture"], model: "fallback" }];
  await fixture.start(); await settleLaunch();
  fixture.initial.reject(new Error("HTTP 429 rate limit A")); await settleLaunch();
  fixture.abort.resolve(); await settleLaunch();
  assert.equal(fixture.task.status, "pending");
  assert.equal(fixture.task.attempts.length, 2);
  assert.equal(fixture.task.model.modelID, "fallback");
  assert.equal(fixture.manager.queuesByKey.get("fixture/fallback").length, 1);
  assert.equal(fixture.effects.processed.length, 1);
  assert.equal(fixture.effects.wakes.length, 1);
  assert.match(fixture.effects.wakes[0].text, /BACKGROUND TASK RETRYING/);
  assert.equal(fixture.effects.releases, 1);
});
test("initial launch: real processKey can bind the legitimate retry before fallback await returns", async (suite) => {
  const fixture = launchFixture(suite);
  fixture.manager.processKey = context.Manager.prototype.processKey;
  fixture.task.fallbackChain = [{ providers: ["fixture"], model: "fallback" }];
  await fixture.start(); await settleLaunch();
  fixture.manager.client.session.create = async () => ({ data: { id: "child-retry" } });
  const resolveContext = fixture.manager.resolveParentWakePromptContext.bind(fixture.manager);
  fixture.manager.resolveParentWakePromptContext = async (...args) => {
    if (fixture.task.status === "pending") await fixture.setup.promise;
    return resolveContext(...args);
  };
  fixture.initial.reject(new Error("HTTP 429 rate limit A")); await settleLaunch();
  fixture.abort.resolve(); await settleLaunch(); await settleLaunch();
  assert.equal(fixture.task.status, "running");
  assert.equal(fixture.task.sessionId, "child-retry");
  assert.equal(fixture.sdk.at(-1).path.id, "child-retry");
  assert.equal(fixture.sdk.at(-1).body.model.modelID, "fallback");
  fixture.setup.resolve(); await settleLaunch();
  assert.ok(fixture.effects.wakes.some((wake) => wake.text.includes("BACKGROUND TASK RETRYING")));
  assert.ok(fixture.effects.wakes.some((wake) => wake.text.includes("BACKGROUND TASK RETRY SESSION READY")));
  assert.equal(fixture.effects.aborts, 1);
  assert.equal(fixture.effects.releases, 1);
});

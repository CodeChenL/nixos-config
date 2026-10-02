import assert from "node:assert/strict";
import { test } from "node:test";
import { context, final, user } from "./background-lifecycle.fixture.mjs";
import { continuationFixture, deferred, flushDispatch, oldReplies } from "./background-continuation.fixture.mjs";

for (const [kind, oldReply] of Object.entries(oldReplies)) {
  for (const phase of ["pending status read", "204 before user persistence"]) {
    test(`continuation ignores old ${kind} during ${phase}`, async () => {
      const { manager, task, effects, resume } = continuationFixture(oldReply);
      const status = deferred();
      let statusReads = 0;
      manager.client.session.status = () => ++statusReads === 1 && phase === "pending status read"
        ? status.promise : Promise.resolve({ data: { child: { type: "idle" } } });
      try {
        await resume();
        await flushDispatch();
        assert.equal(effects.dispatches.length, phase === "pending status read" ? 0 : 1);
        await manager.pollRunningTasks();
        assert.equal(task.status, "running");
        assert.equal(effects.aborts, 0);
        assert.equal(effects.releases, 0);
        assert.deepEqual(effects.notifications, []);
      } finally {
        status.resolve({ data: { child: { type: "idle" } } });
        await flushDispatch();
      }
    });
  }
}

test("continuation requires its persisted prompt, then completes exactly once", async () => {
  const { manager, task, effects, history, resume, persistPrompt, appendFinal } = continuationFixture();
  await resume();
  await flushDispatch();
  const memory = { info: { id: "memory-user", role: "user" }, parts: [{ type: "text", synthetic: true, text: "Memory" }] };
  history.push(memory);
  appendFinal(memory, "memory-assistant");
  await manager.tryCompleteTask(task, "polling");
  assert.equal(task.status, "running", "unrelated newer messages cannot establish continuation ownership");
  const continuationUser = persistPrompt();
  appendFinal(user, "late-old-assistant");
  await manager.tryCompleteTask(task, "polling");
  assert.equal(task.status, "running", "new assistant identity with old parent is still old work");
  appendFinal(continuationUser);
  await Promise.all([manager.tryCompleteTask(task, "polling"), manager.tryCompleteTask(task, "session.idle")]);
  assert.equal(task.status, "completed");
  assert.equal(effects.aborts, 1);
  assert.equal(effects.releases, 1);
  assert.deepEqual(effects.notifications, ["completed"]);
});

for (const activity of ["memory", "compaction"]) {
  test(`continuation permits completion after newer ${activity} activity`, async () => {
    const { manager, task, effects, history, resume, persistPrompt, appendFinal } = continuationFixture();
    await resume();
    await flushDispatch();
    const continuationUser = persistPrompt();
    history.push({ info: { id: "summary", role: "assistant", parentID: continuationUser.info.id,
      summary: true, mode: "compaction", finish: "stop", time: { completed: 3 } }, parts: final.parts });
    await manager.tryCompleteTask(task, "polling");
    assert.equal(task.status, "running");
    const newerUser = { info: { id: `${activity}-user`, role: "user" },
      parts: [{ type: "text", synthetic: true, text: activity }] };
    history.push(newerUser);
    await manager.tryCompleteTask(task, "polling");
    assert.equal(task.status, "running");
    appendFinal(newerUser);
    await manager.pollRunningTasks();
    assert.equal(task.status, "completed");
    assert.deepEqual(effects.notifications, ["completed"]);
  });
}

test("skipped continuation restores snapshot and releases its concurrency slot", async () => {
  const { manager, task, effects, resume } = continuationFixture();
  const snapshot = manager.captureResumeTaskSnapshot(task);
  manager.client.session.status = async () => ({ data: { child: { type: "busy" } } });
  await resume();
  await flushDispatch();
  assert.deepEqual(manager.captureResumeTaskSnapshot(task), snapshot);
  assert.equal(manager.pendingByParent.size, 0);
  assert.equal(effects.dispatches.length, 0);
  assert.equal(effects.releases, 1);
  assert.equal(effects.removals, 1);
});

test("failed continuation releases state and permits a later continuation", async () => {
  const { manager, task, effects, resume } = continuationFixture();
  manager.client.session.promptAsync = async () => { throw new Error("HTTP 400"); };
  await resume();
  await flushDispatch();
  assert.equal(task.status, "interrupt");
  assert.equal(manager.pendingByParent.size, 0);
  assert.equal(effects.releases, 1);
  assert.deepEqual(effects.notifications, ["interrupt"]);
  context.promptAsyncReservations.get("child").expiresAt = 0;
  manager.client.session.promptAsync = async () => ({ response: { status: 204 } });
  await resume();
  await flushDispatch();
  assert.equal(task.status, "running");
  assert.equal(effects.acquisitions, 2);
});

test("rejected concurrency acquisition restores the completed snapshot without releasing a slot", async () => {
  const { manager, task, effects, resume } = continuationFixture();
  const snapshot = manager.captureResumeTaskSnapshot(task);
  manager.concurrencyManager.acquire = async () => { throw new Error("acquisition cancelled"); };
  await assert.rejects(resume(), /acquisition cancelled/);
  assert.deepEqual(manager.captureResumeTaskSnapshot(task), snapshot);
  assert.equal(effects.dispatches.length, 0);
  assert.equal(effects.releases, 0);
});

for (const kind of ["error", "truncated"]) {
  test(`continuation still reports its own ${kind} assistant as failure`, async () => {
    const { manager, task, effects, history, resume, persistPrompt } = continuationFixture();
    await resume();
    await flushDispatch();
    const prompt = persistPrompt();
    const reply = structuredClone(oldReplies[kind]);
    reply.info.id = "new-error";
    reply.info.parentID = prompt.info.id;
    history.push(reply);
    await manager.tryCompleteTask(task, "polling");
    assert.equal(task.status, "error");
    assert.equal(effects.releases, 1);
    assert.deepEqual(effects.notifications, ["error"]);
  });
}

test("ambiguous post-dispatch failure retains ownership until its real response arrives", async () => {
  const { manager, task, effects, resume, persistPrompt, appendFinal } = continuationFixture();
  manager.client.session.promptAsync = async (input) => {
    effects.dispatches.push(input);
    throw new Error("Unexpected EOF");
  };
  await resume();
  await flushDispatch();
  await manager.pollRunningTasks();
  assert.equal(task.status, "running");
  appendFinal(persistPrompt());
  await manager.pollRunningTasks();
  assert.equal(task.status, "completed");
  assert.deepEqual(effects.notifications, ["completed"]);
});

test("skipped later continuation restores the previous continuation boundary", async () => {
  const { manager, task, effects, resume, persistPrompt, appendFinal } = continuationFixture();
  await resume();
  await flushDispatch();
  appendFinal(persistPrompt());
  await manager.tryCompleteTask(task, "polling");
  const snapshot = manager.captureResumeTaskSnapshot(task);
  await resume();
  await flushDispatch();
  assert.deepEqual(manager.captureResumeTaskSnapshot(task), snapshot);
  assert.equal(effects.dispatches.length, 1, "the real reservation gate must skip the later dispatch");
  assert.equal(effects.releases, 2);
  assert.deepEqual(effects.notifications, ["completed"]);
});

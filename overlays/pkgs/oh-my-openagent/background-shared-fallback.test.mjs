import assert from "node:assert/strict";
import { test } from "node:test";
import { context } from "./background-lifecycle.fixture.mjs";
import { settleLaunch } from "./background-launch.fixture.mjs";
import { sharedFallbackFixture } from "./background-shared-fallback.fixture.mjs";

for (const entry of ["wrapper", "resume", "session.error", "message.updated", "session.status", "poll"]) {
  for (const phase of ["abort", "context"]) {
    test(`shared fallback: actual ${entry} ${phase} await cannot mutate resumed C`, async (suite) => {
      const fixture = sharedFallbackFixture(suite);
      await fixture.begin(entry, phase);
      await fixture.resumeNext();
      const before = fixture.snapshot();
      assert.equal(fixture.task.status, "running");
      await fixture.releaseRetry();
      assert.deepEqual(fixture.snapshot(), before,
        "old retry must not queue/process/wake or clear C's registry and observations");
    });
  }
}

for (const phase of ["abort", "context"]) {
  for (const changed of ["identity", "continuation", "attempt", "status", "session"]) {
    test(`shared fallback: three-argument wrapper rejects ${changed} changes during ${phase}`, async (suite) => {
      const fixture = sharedFallbackFixture(suite);
      await fixture.begin("wrapper", phase);
      const { manager, task } = fixture;
      if (changed === "identity") manager.tasks.set(task.id, structuredClone(task));
      if (changed === "continuation") task.continuation = { partID: "new-owner" };
      if (changed === "attempt") task.currentAttemptID = "new-attempt";
      if (changed === "status") task.status = "cancelled";
      if (changed === "session") task.sessionId = "unbound-session";
      fixture.seedObservations();
      const before = fixture.snapshot();
      await fixture.releaseRetry();
      assert.deepEqual(fixture.snapshot(), before);
    });
  }
}

for (const changed of ["identity", "status"]) {
  test(`shared fallback: stale ${changed} at wrapper entry cannot even schedule a retry`, async (suite) => {
    const fixture = sharedFallbackFixture(suite);
    await fixture.start(); await settleLaunch();
    fixture.initial.resolve({ response: { status: 204 } }); await settleLaunch();
    fixture.task.fallbackChain = [{ providers: ["fixture"], model: "fallback" }];
    if (changed === "identity") fixture.manager.tasks.set(fixture.task.id, structuredClone(fixture.task));
    else fixture.task.status = "cancelled";
    const before = fixture.snapshot();
    fixture.abort.resolve();
    const result = await fixture.manager.tryFallbackRetry(fixture.task,
      { name: "APIError", message: "HTTP 429 obsolete owner", statusCode: 429 }, "shared.fixture");
    assert.equal(result, false);
    assert.deepEqual(fixture.snapshot(), before);
  });
}

test("shared fallback: current three-argument retry still queues, processes, notifies and cleans old child", async (suite) => {
  const fixture = sharedFallbackFixture(suite);
  await fixture.begin(); fixture.seedObservations();
  await fixture.releaseRetry();
  assert.deepEqual(fixture.observe(), { status: "pending", queued: 1, processed: 1, wakes: 1 });
  assert.equal(fixture.effects.wakes[0].shouldReply, false);
  assert.equal(fixture.effects.registry.length, 1);
  assert.equal(fixture.manager.observedOutputSessions.has("child"), false);
  assert.equal(fixture.manager.observedIncompleteTodosBySession.has("child"), false);
  assert.equal(context.subagentSessions.has("child"), false);
});

for (const entry of ["wrapper", "resume"]) {
  test(`shared fallback: actual ${entry} processKey binding preserves both legitimate notices`, async (suite) => {
    const fixture = sharedFallbackFixture(suite);
    await fixture.begin(entry);
    fixture.manager.client.session.create = async () => ({ data: { id: "healthy-retry-child" } });
    fixture.manager.processKey = context.Manager.prototype.processKey;
    fixture.seedObservations();
    await fixture.releaseRetry();
    assert.equal(fixture.task.status, "running");
    assert.equal(fixture.task.sessionId, "healthy-retry-child");
    assert.equal(fixture.task.currentAttemptID, fixture.task.attempts[1].attemptId);
    assert.equal(fixture.sdk.at(-1).path.id, "healthy-retry-child");
    assert.equal(fixture.sdk.at(-1).body.model.modelID, "fallback");
    assert.equal(fixture.manager.queuesByKey.get("fixture/fallback").length, 0);
    assert.equal(fixture.manager.processingKeys.size, 0);
    assert.equal(fixture.effects.wakes.length, 2);
    assert.ok(fixture.effects.wakes.some(({ text }) => text.includes("[BACKGROUND TASK RETRYING]")));
    assert.ok(fixture.effects.wakes.some(({ text }) => text.includes("[BACKGROUND TASK RETRY SESSION READY]")));
    assert.equal(fixture.manager.observedOutputSessions.has("child"), false);
    assert.equal(fixture.manager.observedIncompleteTodosBySession.has("child"), false);
  });
}

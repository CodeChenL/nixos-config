import assert from "node:assert/strict";
import { test } from "node:test";
import { producers, terminalFixture, terminalSnapshot } from "./background-terminal.fixture.mjs";

for (const [entry, status] of Object.entries(producers)) {
  for (const active of [false, true]) {
    test(`${entry}: current ${status} notice still reaches an ${active ? "active" : "idle"} parent`, async (suite) => {
      const fixture = terminalFixture(entry, "queued", active);
      suite.after(fixture.dispose);
      await fixture.begin();
      await fixture.release();
      const { manager, task, effects } = fixture;
      assert.equal(task.status, status);
      assert.equal(manager.pendingByParent.size, 0);
      assert.equal(effects.wakes.length, 1);
      assert.equal(effects.wakes[0].id, "parent");
      assert.equal(effects.wakes[0].shouldReply, true);
      assert.equal(effects.wakes[0].promptContext.agent, "fixture-parent");
      assert.equal(effects.wakes[0].promptContext.model.modelID, "local");
      assert.equal(effects.wakes[0].debounce, 100);
      assert.equal(manager.completionTimers.size, 1);
    });
  }
  for (const result of ["running", "completed", "error", "cancelled", "interrupt"]) {
    test(`${entry}: queued A cannot steal newer same-session/attempt ${result} B`, async (suite) => {
      const fixture = terminalFixture(entry);
      suite.after(fixture.dispose);
      const { manager, task, effects } = fixture;
      await fixture.begin();
      const old = task.continuation;
      await fixture.resumeNext();
      assert.notEqual(task.continuation, old);
      assert.equal(task.sessionId, "child");
      assert.equal(task.currentAttemptID, "same-attempt");
      assert.ok(manager.pendingByParent.get("parent").has(task.id));
      if (result === "completed") {
        fixture.appendFinal(fixture.persistPrompt());
        await manager.tryCompleteTask(task, "polling");
      } else if (result === "error") {
        await manager.failCrashedTask(task, "new error B");
      } else if (result === "cancelled") {
        await manager.cancelTask(task.id);
      } else if (result === "interrupt") {
        await manager.interruptTaskFromAsyncPromptFailure(task, "new interrupt B", "fixture B");
      }
      await Promise.all(effects.notificationJobs.slice(1));
      assert.equal(effects.wakes.length, result === "running" ? 0 : 1);
      const before = terminalSnapshot(fixture);
      await fixture.release();
      assert.deepEqual(terminalSnapshot(fixture), before,
        "obsolete A must not touch B state/pending/summaries/notices/wakes/removal timers");
    });
  }
  for (const changed of ["session", "attempt", "status", "task identity"]) {
    test(`${entry}: queued terminal loses ownership when ${changed} changes`, async (suite) => {
      const fixture = terminalFixture(entry);
      suite.after(fixture.dispose);
      await fixture.begin();
      const { manager, task, effects } = fixture;
      if (changed === "session") task.sessionId = "different-child";
      if (changed === "attempt") task.currentAttemptID = "different-attempt";
      if (changed === "status") task.status = "completed";
      if (changed === "task identity") manager.tasks.set(task.id, structuredClone(task));
      manager.pendingByParent.set("parent", new Set([task.id]));
      const before = terminalSnapshot(fixture);
      await fixture.release();
      assert.deepEqual(terminalSnapshot(fixture), before);
      assert.equal(effects.parentReads, 0);
    });
  }
  test(`${entry}: obsolete queued notice cannot append to newer sibling summaries`, async (suite) => {
    const fixture = terminalFixture(entry);
    suite.after(fixture.dispose);
    await fixture.begin();
    await fixture.resumeNext();
    const { manager, task } = fixture;
    manager.tasks.set("sibling", { id: "sibling", parentSessionId: "parent", status: "running" });
    manager.pendingByParent.get("parent").add("sibling");
    manager.completedTaskSummaries.set("parent", [{ id: "finished-sibling", status: "completed" }]);
    const before = terminalSnapshot(fixture);
    await fixture.release();
    assert.deepEqual(terminalSnapshot(fixture), before);
    assert.ok(manager.pendingByParent.get("parent").has(task.id));
  });
}

for (const entry of ["processKey", "startTask", "interruptTaskFromAsyncPromptFailure", "cancelTask", "checkAndInterruptStaleTasks"]) {
  test(`${entry}: cleanup await cannot enqueue or finalize a newer continuation`, async (suite) => {
    const fixture = terminalFixture(entry, "cleanup");
    suite.after(fixture.dispose);
    await fixture.begin();
    if (fixture.task.status === "running") {
      await fixture.manager.cancelTask(fixture.task.id, { abortSession: false, skipNotification: true });
    }
    await fixture.resumeNext();
    const before = terminalSnapshot(fixture);
    await fixture.release();
    assert.deepEqual(terminalSnapshot(fixture), before);
    assert.equal(fixture.effects.notificationJobs.length, 0);
  });
}

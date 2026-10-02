import assert from "node:assert/strict";
import { test } from "node:test";
import { context } from "./background-lifecycle.fixture.mjs";
import { failureNotificationFixture } from "./background-failure-notification.fixture.mjs";

function snapshot(manager, task, effects) {
  return {
    task: structuredClone(task),
    pending: [...manager.pendingByParent].map(([id, tasks]) => [id, [...tasks]]),
    summaries: structuredClone([...manager.completedTaskSummaries]),
    timers: [...manager.completionTimers], removals: effects.removals,
    wakes: structuredClone(effects.wakes),
  };
}

for (const entry of ["failCrashedTask", "handleSessionErrorEvent"]) {
  for (const active of [false, true]) {
    test(`${entry}: current failure notifies an ${active ? "active" : "idle"} parent normally`, async (suite) => {
      const fixture = failureNotificationFixture(entry, "queued", active);
      suite.after(fixture.dispose);
      const { manager, task, effects, fail, release } = fixture;
      await fail();
      await release();
      assert.equal(effects.wakes.length, 1);
      const wake = effects.wakes[0];
      assert.match(wake.text, /ALL BACKGROUND TASKS FINISHED - 1 FAILED/);
      assert.match(wake.text, /\[ERROR\] - old error/);
      assert.equal(wake.id, "parent");
      assert.equal(wake.shouldReply, true);
      assert.equal(wake.promptContext.agent, "fixture-parent");
      assert.equal(wake.promptContext.model.modelID, "local");
      assert.equal(wake.promptContext.variant, "low");
      assert.equal(wake.debounce, 100);
      assert.equal(manager.pendingByParent.size, 0);
      assert.equal(task.status, "error");
      assert.equal(effects.removals, 2, "real entry and notifier both schedule removal");
    });
  }

  for (const result of ["running", "completed", "error"]) {
    test(`${entry}: queued A failure cannot mutate newer same-session/attempt ${result} B`, async (suite) => {
      const fixture = failureNotificationFixture(entry);
      suite.after(fixture.dispose);
      const { manager, task, effects, fail, resumeNext, release, persistPrompt, appendFinal } = fixture;
      await fail();
      const oldContinuation = task.continuation;
      await resumeNext();
      assert.notEqual(task.continuation, oldContinuation);
      assert.equal(task.sessionId, "child");
      assert.equal(task.currentAttemptID, "same-attempt");
      assert.ok(manager.pendingByParent.get("parent").has(task.id));
      if (result === "completed") {
        appendFinal(persistPrompt());
        await manager.tryCompleteTask(task, "polling");
      } else if (result === "error") {
        context.finalizeAttempt(task, task.currentAttemptID, "error", "new error B");
      }
      const before = snapshot(manager, task, effects);
      await release();
      if (result === "completed") {
        assert.equal(effects.wakes.length, 1, "only B's current completion can wake the parent");
        assert.match(effects.wakes[0].text, /ALL BACKGROUND TASKS COMPLETE/);
        assert.doesNotMatch(effects.wakes[0].text, /FAILED|old error|CANCELLED/);
      }
      assert.deepEqual(snapshot(manager, task, effects), before,
        "obsolete failure must not touch B's state, pending, summaries, removal or wake");
    });
  }

  for (const changed of ["session", "attempt", "status", "task identity"]) {
    test(`${entry}: queued failure loses ownership when ${changed} changes`, async (suite) => {
      const fixture = failureNotificationFixture(entry);
      suite.after(fixture.dispose);
      const { manager, task, effects, fail, release } = fixture;
      await fail();
      if (changed === "session") task.sessionId = "different-child";
      if (changed === "attempt") task.currentAttemptID = "different-attempt";
      if (changed === "status") task.status = "completed";
      if (changed === "task identity") manager.tasks.set(task.id, structuredClone(task));
      manager.pendingByParent.set("parent", new Set([task.id]));
      const before = snapshot(manager, task, effects);
      await release();
      assert.deepEqual(snapshot(manager, task, effects), before,
        "ownership loss must be checked before the actual notifier's side effects");
      assert.equal(effects.parentReads, 0, "obsolete callback never enters notifier context lookup");
    });
  }

  for (const phase of ["context", "status"]) {
    for (const result of ["running", "completed"]) {
      test(`${entry}: resume during notifier ${phase} await preserves newer ${result} B`, async (suite) => {
        const fixture = failureNotificationFixture(entry, phase);
        suite.after(fixture.dispose);
        const { manager, task, effects, fail, resumeNext, release, persistPrompt, appendFinal } = fixture;
        await fail();
        await resumeNext();
        assert.equal(task.sessionId, "child");
        assert.equal(task.currentAttemptID, "same-attempt");
        assert.ok(manager.pendingByParent.get("parent").has(task.id));
        if (result === "completed") {
          appendFinal(persistPrompt());
          manager.enableParentSessionNotifications = false;
          await manager.tryCompleteTask(task, "polling");
        }
        const before = snapshot(manager, task, effects);
        await release();
        assert.deepEqual(snapshot(manager, task, effects), before,
          "old notifier must not queue a failure wake or reschedule B's removal after await");
        assert.equal(effects.wakes.length, 0);
        assert.equal(effects.parentReads, 1, "uses actual parent prompt context through SDK");
      });
    }
  }
}

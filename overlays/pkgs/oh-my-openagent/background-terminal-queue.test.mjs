import assert from "node:assert/strict";
import { test } from "node:test";
import { deferred, flushDispatch } from "./background-continuation.fixture.mjs";
import { failureNotificationFixture } from "./background-failure-notification.fixture.mjs";

for (const result of ["running", "completed", "error", "cancelled", "interrupt"]) {
  test(`real parent queue: obsolete cancellation cannot consume newer ${result} result`, async (suite) => {
    const fixture = failureNotificationFixture("failCrashedTask");
    const { manager, task, effects } = fixture;
    const previous = deferred();
    const operations = [];
    delete manager.enqueueNotificationForParent;
    manager.notificationQueueByParent = new Map([["parent", previous.promise]]);
    suite.after(async () => {
      previous.resolve();
      await Promise.all(operations);
      await fixture.dispose();
    });
    await fixture.resume();
    await flushDispatch();
    fixture.appendFinal(fixture.persistPrompt());
    operations.push(manager.cancelTask(task.id));
    await flushDispatch();
    assert.equal(task.status, "cancelled");
    assert.equal(effects.wakes.length, 0);
    await fixture.resumeNext();
    if (result === "completed") {
      fixture.appendFinal(fixture.persistPrompt());
      operations.push(manager.tryCompleteTask(task, "polling"));
    } else if (result === "error") {
      operations.push(manager.failCrashedTask(task, "new error B"));
    } else if (result === "cancelled") {
      operations.push(manager.cancelTask(task.id));
    } else if (result === "interrupt") {
      operations.push(manager.interruptTaskFromAsyncPromptFailure(task, "new interrupt B", "fixture B"));
    }
    await flushDispatch();
    const current = manager.notificationQueueByParent.get("parent");
    previous.resolve();
    await current;
    await Promise.all(operations);
    assert.equal(task.status, result);
    assert.equal(effects.wakes.length, result === "running" ? 0 : 1);
    assert.equal(manager.pendingByParent.get("parent")?.has(task.id) ?? false, result === "running");
    assert.equal(manager.completionTimers.size, result === "running" ? 0 : 1);
    assert.equal(manager.completedTaskSummaries.size, 0);
    assert.equal(manager.notificationQueueByParent.size, 0);
    assert.equal(effects.dispatches.length, 2);
  });
}

import assert from "node:assert/strict";
import { test } from "node:test";
import { context } from "./background-lifecycle.fixture.mjs";
import { continuationFixture, deferred, flushDispatch } from "./background-continuation.fixture.mjs";

test("cancelled continuation is not dispatched when the SDK status read resolves", async () => {
  const { manager, task, effects, resume } = continuationFixture();
  const status = deferred();
  manager.client.session.status = () => status.promise;
  await resume();
  await manager.cancelTask(task.id, { skipNotification: true });
  status.resolve({ data: { child: { type: "idle" } } });
  await flushDispatch();
  assert.equal(task.status, "cancelled");
  assert.equal(effects.dispatches.length, 0);
  assert.equal(effects.releases, 1);
});

test("skipped dispatch after cancellation cannot restore the old completed snapshot", async () => {
  const { manager, task, effects, resume } = continuationFixture();
  const status = deferred();
  manager.client.session.status = () => status.promise;
  await resume();
  await manager.cancelTask(task.id, { skipNotification: true });
  status.resolve({ data: { child: { type: "busy" } } });
  await flushDispatch();
  assert.equal(task.status, "cancelled");
  assert.equal(effects.releases, 1);
  assert.equal(effects.notifications.length, 0);
});

test("failed dispatch after cancellation cannot interrupt or notify the task", async () => {
  const { manager, task, effects, resume } = continuationFixture();
  const dispatch = deferred();
  manager.client.session.promptAsync = () => dispatch.promise;
  await resume();
  await flushDispatch();
  await manager.cancelTask(task.id, { skipNotification: true });
  dispatch.reject(new Error("HTTP 400"));
  await flushDispatch();
  assert.equal(task.status, "cancelled");
  assert.equal(effects.aborts, 1);
  assert.equal(effects.releases, 1);
  assert.deepEqual(effects.notifications, []);
});

test("same-session completion read cannot outlive cancel and resume with the same attempt", async () => {
  const { manager, task, effects, history, resume, persistPrompt, appendFinal } = continuationFixture();
  await resume();
  await flushDispatch();
  appendFinal(persistPrompt());
  const oldMessages = structuredClone(history);
  const read = deferred();
  manager.client.session.messages = () => read.promise;
  const completion = manager.tryCompleteTask(task, "polling");
  await manager.cancelTask(task.id, { skipNotification: true });
  manager.client.session.messages = async () => ({ data: history });
  context.promptAsyncReservations.get("child").expiresAt = 0;
  await resume();
  await flushDispatch();
  read.resolve({ data: oldMessages });
  await completion;
  assert.equal(task.currentAttemptID, "same-attempt");
  assert.equal(task.status, "running");
  assert.equal(effects.aborts, 1);
  assert.deepEqual(effects.notifications, []);
});

test("failed dispatch fallback callback cannot interrupt a later resume", async () => {
  const { manager, task, effects, resume } = continuationFixture();
  const fallback = deferred();
  manager.tryFallbackRetry = () => fallback.promise;
  manager.client.session.promptAsync = async () => { throw new Error("HTTP 400"); };
  await resume();
  await flushDispatch();
  await manager.cancelTask(task.id, { skipNotification: true });
  context.promptAsyncReservations.get("child").expiresAt = 0;
  manager.client.session.promptAsync = async () => ({ response: { status: 204 } });
  await resume();
  await flushDispatch();
  fallback.resolve(false);
  await flushDispatch();
  assert.equal(task.status, "running");
  assert.equal(effects.aborts, 1);
  assert.equal(effects.releases, 1);
  assert.deepEqual(effects.notifications, []);
});

test("pending concurrency acquisition is owned before asynchronous resume setup", async () => {
  const { manager, task, effects, resume } = continuationFixture();
  const acquisition = deferred();
  manager.concurrencyManager.acquire = () => acquisition.promise;
  const first = resume();
  try {
    assert.equal(task.status, "running");
    await assert.rejects(resume(), /currently running/);
    await manager.cancelTask(task.id, { skipNotification: true });
  } finally {
    acquisition.resolve();
    await first;
    await flushDispatch();
  }
  assert.equal(task.status, "cancelled");
  assert.equal(effects.dispatches.length, 0);
  assert.equal(effects.releases, 1);
});

test("old session-error fallback callback cannot fail a later continuation", async () => {
  const { manager, task, effects, resume } = continuationFixture();
  await resume();
  await flushDispatch();
  const fallback = deferred();
  manager.tryFallbackRetry = () => fallback.promise;
  const oldError = manager.handleSessionErrorEvent({ task,
    errorInfo: { name: "APIError", message: "old failure" }, errorMessage: "old failure", errorName: "APIError" });
  await manager.cancelTask(task.id, { skipNotification: true });
  context.promptAsyncReservations.get("child").expiresAt = 0;
  await resume();
  await flushDispatch();
  fallback.resolve(false);
  await oldError;
  assert.equal(task.status, "running");
  assert.equal(effects.releases, 1);
  assert.deepEqual(effects.notifications, []);
});

test("completion cleanup cannot clear or notify a newer continuation", async () => {
  const { manager, task, effects, resume, persistPrompt, appendFinal } = continuationFixture();
  await resume();
  await flushDispatch();
  appendFinal(persistPrompt());
  const abort = deferred();
  let deletions = 0;
  manager.abortSessionWithLogging = () => abort.promise;
  manager.onSubagentSessionDeleted = async () => { deletions++; };
  const completion = manager.tryCompleteTask(task, "polling");
  await flushDispatch();
  assert.equal(task.status, "completed");
  context.promptAsyncReservations.get("child").expiresAt = 0;
  await resume();
  await flushDispatch();
  abort.resolve(true);
  await completion;
  assert.equal(task.status, "running");
  assert.equal(deletions, 0);
  assert.deepEqual(effects.notifications, []);
});

test("a queued completion notification cannot report a mutable later continuation", async () => {
  const { manager, task, effects, resume, persistPrompt, appendFinal } = continuationFixture();
  await resume();
  await flushDispatch();
  appendFinal(persistPrompt());
  const notification = deferred();
  manager.enqueueNotificationForParent = async (_id, callback) => {
    await notification.promise;
    return callback();
  };
  const completion = manager.tryCompleteTask(task, "polling");
  await flushDispatch();
  context.promptAsyncReservations.get("child").expiresAt = 0;
  await resume();
  await flushDispatch();
  notification.resolve();
  await completion;
  assert.equal(task.status, "running");
  assert.deepEqual(effects.notifications, []);
});

import assert from "node:assert/strict";
import vm from "node:vm";
import { context, source } from "./background-lifecycle.fixture.mjs";
import { deferred, flushDispatch } from "./background-continuation.fixture.mjs";
import { failureNotificationFixture } from "./background-failure-notification.fixture.mjs";

Object.assign(context, {
  TERMINAL_TASK_STATUSES: new Set(["completed", "error", "cancelled", "interrupt"]),
  TASK_TTL_MS: 1800000, TERMINAL_TASK_TTL_MS: 1800000,
  DEFAULT_STALE_TIMEOUT_MS: 2700000, DEFAULT_SESSION_GONE_TIMEOUT_MS: 60000,
  DEFAULT_MESSAGE_STALENESS_TIMEOUT_MS: 3600000, MIN_RUNTIME_BEFORE_STALE_MS: 30000,
  setSessionAgent() {}, registerDelegatedChildSessionBootstrap() {}, invokeTmuxSessionCreatedCallback() {},
  promptWithRetryInDirectory: async () => { throw new Error("launch failure A"); },
});
for (const name of [
  "toAttemptModel", "isTerminalStatus", "ensureCurrentAttempt", "bindAttemptSession",
  "getAbortResponseError", "abortWithTimeout", "pruneStaleTasksAndNotifications",
  "interruptStaleTask", "checkAndInterruptStaleTasks",
]) {
  const start = source.search(new RegExp(`(?:async )?function ${name}\\(`));
  assert.ok(start >= 0, `missing bundled function ${name}`);
  vm.runInContext(source.slice(start, source.indexOf("\n}", start) + 2), context);
}

export const producers = {
  cancelTask: "cancelled", processKey: "error", startTask: "interrupt",
  interruptTaskFromAsyncPromptFailure: "interrupt",
  pruneStaleTasksAndNotifications: "error", checkAndInterruptStaleTasks: "cancelled",
};

export function terminalSnapshot(fixture) {
  const { manager, task, effects } = fixture;
  return {
    task: structuredClone(task),
    pending: [...manager.pendingByParent].map(([id, tasks]) => [id, [...tasks]]),
    summaries: structuredClone([...manager.completedTaskSummaries]),
    notifications: structuredClone([...manager.notifications]),
    timers: [...manager.completionTimers], removals: effects.removals,
    releases: effects.releases, wakes: structuredClone(effects.wakes),
  };
}

export function terminalFixture(entry, phase = "queued", active = false) {
  const fixture = failureNotificationFixture("failCrashedTask", "queued", active);
  const { manager, task, effects } = fixture;
  const cleanup = deferred();
  const cleanupEntered = deferred();
  let operations = [];
  Object.assign(manager, {
    queuesByKey: new Map(), processingKeys: new Set(), preStartDescendantReservations: new Set(),
  });
  manager.client.session.get = async () => ({ data: { directory: "/isolated-project" } });
  manager.client.session.create = async () => {
    if (entry === "processKey") throw new Error("create failure A");
    return { data: { id: "child" } };
  };
  const abort = async () => {
    effects.aborts++;
    if (phase === "cleanup" && effects.aborts === 1) {
      cleanupEntered.resolve();
      await cleanup.promise;
    }
    return true;
  };
  manager.abortSessionWithLogging = abort;
  manager.client.session.abort = async () => { await abort(); return {}; };
  async function begin() {
    await fixture.resume();
    await flushDispatch();
    fixture.appendFinal(fixture.persistPrompt());
    const input = { agent: "fixture", parentSessionId: "parent", description: "Terminal fixture", prompt: "Work" };
    if (entry === "cancelTask") operations.push(manager.cancelTask(task.id));
    if (entry === "processKey") {
      manager.queuesByKey.set("fixture", [{ task, input }]);
      operations.push(manager.processKey("fixture"));
    }
    if (entry === "startTask") {
      task.attempts[0].status = "running";
      operations.push(manager.startTask({ task, input, attemptID: task.currentAttemptID }));
    }
    if (entry === "interruptTaskFromAsyncPromptFailure") {
      operations.push(manager.interruptTaskFromAsyncPromptFailure(task, "async failure A", "fixture"));
    }
    if (entry === "pruneStaleTasksAndNotifications") {
      delete manager.pruneStaleTasksAndNotifications;
      manager.config.taskTtlMs = 1;
      task.progress.lastUpdate = new Date(Date.now() - 60000);
      manager.pruneStaleTasksAndNotifications({ child: { type: "idle" } });
    }
    if (entry === "checkAndInterruptStaleTasks") {
      delete manager.checkAndInterruptStaleTasks;
      manager.config.staleTimeoutMs = 1;
      task.startedAt = new Date(Date.now() - 60000);
      task.progress.lastUpdate = task.startedAt;
      operations.push(manager.checkAndInterruptStaleTasks({ child: { type: "idle" } }));
    }
    await flushDispatch();
    if (phase === "cleanup") {
      await cleanupEntered.promise;
      assert.equal(effects.notificationJobs.length, 0);
    } else {
      assert.equal(task.status, producers[entry]);
      assert.equal(effects.notificationJobs.length, 1, "actual producer must queue A");
    }
  }
  async function release() {
    cleanup.resolve();
    await flushDispatch();
    await fixture.release();
    await Promise.all(operations);
  }
  async function dispose() {
    await release();
    await fixture.dispose();
    for (const timer of manager.idleDeferralTimers.values()) clearTimeout(timer);
    assert.equal(manager.completionTimers.size, 0);
  }
  return { ...fixture, begin, release, dispose };
}

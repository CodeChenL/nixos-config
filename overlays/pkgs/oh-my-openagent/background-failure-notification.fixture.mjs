import assert from "node:assert/strict";
import vm from "node:vm";
import { context, source } from "./background-lifecycle.fixture.mjs";
import { continuationFixture, deferred, flushDispatch, oldReplies } from "./background-continuation.fixture.mjs";

Object.assign(context, {
  store: new Map(), checkpoints: new Map(), PENDING_PARENT_WAKE_DEBOUNCE_MS: 100,
  resolveDispatchClient2: async (client) => ({ client, route: "in-process" }),
});
for (const name of [
  "formatDuration3", "cloneAttempts2", "formatAttemptModel", "formatAttemptTimeline",
  "formatTaskSummaryLine", "buildBackgroundTaskNotificationText",
  "isCompactionPart", "isCompactionAgent", "hasCompactionPart", "isCompactionMessage",
  "hasFullAgentAndModel", "hasPartialAgentOrModel", "convertSessionMessageToStoredMessage",
  "mergeStoredMessages", "resolvePromptContextFromSessionMessages", "cloneCheckpoint",
  "getCompactionAgentConfigCheckpoint", "getSessionTools", "normalizePromptTools",
  "resolveInheritedPromptTools",
]) {
  const start = source.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `missing bundled function ${name}`);
  const end = source.indexOf("\n}", start) + 2;
  vm.runInContext(source.slice(start, end), context);
}

const parentMessages = [{ info: { role: "user", agent: "fixture-parent",
  model: { providerID: "fixture", modelID: "local", variant: "low" }, tools: { task: true } }, parts: [] }];

export function failureNotificationFixture(entry, phase = "queued", parentActive = false) {
  const result = continuationFixture();
  const { manager, task, history, persistPrompt, resume } = result;
  const effects = Object.assign(result.effects, {
    wakes: [], notificationJobs: [], parentReads: 0, parentStatusReads: 0,
  });
  delete manager.notifyParentSession;
  delete manager.markForNotification;
  delete manager.clearNotificationsForTask;
  Object.assign(manager, {
    notifications: new Map(), completedTaskSummaries: new Map(), enableParentSessionNotifications: true,
    config: { taskCleanupDelayMs: 60000 },
    scheduleTaskRemoval(...args) {
      effects.removals++;
      return context.Manager.prototype.scheduleTaskRemoval.apply(this, args);
    },
  });
  manager.queuePendingParentWake = (id, text, promptContext, shouldReply, debounce) => {
    effects.wakes.push({ id, text, promptContext, shouldReply, debounce });
  };
  const held = deferred();
  const entered = deferred();
  manager.enqueueNotificationForParent = (_id, callback) => {
    const isFirst = effects.notificationJobs.length === 0;
    const job = (async () => {
      if (isFirst && phase === "queued") {
        entered.resolve();
        await held.promise;
      }
      return callback();
    })();
    effects.notificationJobs.push(job);
    return job;
  };
  manager.client.session.messages = async ({ path }) => {
    if (path.id !== "parent") return { data: history };
    effects.parentReads++;
    if (phase === "context") {
      entered.resolve();
      await held.promise;
    }
    return { data: parentMessages };
  };
  manager.client.session.status = async () => {
    effects.parentStatusReads++;
    if (task.status === "error" && phase === "status") {
      entered.resolve();
      await held.promise;
    }
    return { data: { child: { type: "idle" }, parent: { type: parentActive ? "busy" : "idle" } } };
  };
  async function fail() {
    await resume();
    await flushDispatch();
    const prompt = persistPrompt();
    const reply = structuredClone(oldReplies.error);
    reply.info.id = "failed-continuation-A";
    reply.info.parentID = prompt.info.id;
    history.push(reply);
    if (entry === "failCrashedTask") {
      await manager.tryCompleteTask(task, "polling");
    } else {
      await manager.handleSessionErrorEvent({ task, errorInfo: { name: "APIError", message: "old error" },
        errorName: "APIError", errorMessage: "old error" });
    }
    await entered.promise;
    assert.equal(task.status, "error");
    assert.equal(manager.pendingByParent.size, 0, "real failure cleanup removes continuation A");
  }
  async function resumeNext() {
    context.promptAsyncReservations.get("child").expiresAt = 0;
    await resume();
    await flushDispatch();
    assert.equal(effects.dispatches.length, 2);
  }
  async function release() {
    held.resolve();
    await Promise.all(effects.notificationJobs);
  }
  async function dispose() {
    held.resolve();
    await Promise.all(effects.notificationJobs);
    for (const timer of manager.completionTimers.values()) clearTimeout(timer);
    manager.completionTimers.clear();
  }
  return { ...result, effects, fail, resumeNext, release, dispose };
}

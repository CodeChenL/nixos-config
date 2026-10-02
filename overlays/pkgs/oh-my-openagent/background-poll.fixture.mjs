import assert from "node:assert/strict";
import vm from "node:vm";
import { context, final, logs, source } from "./background-lifecycle.fixture.mjs";
import { deferred, flushDispatch } from "./background-continuation.fixture.mjs";
import { failureNotificationFixture } from "./background-failure-notification.fixture.mjs";
import "./background-terminal.fixture.mjs";

Object.assign(context, { MIN_IDLE_TIME_MS: 5000, isTransportUnreachableError: () => false });
for (const name of [
  "getStringField", "resolveSessionEventID", "handleSessionIdleBackgroundEvent", "extractErrorMessage2",
  "extractErrorStatus", "isSessionNotFoundError", "checkSessionExistence", "verifySessionExists",
  "dateFromMillis", "extractSessionActivityDate", "sessionActivityLookupFromInfo",
  "getSessionActivityFromClient", "updateTaskActivityFromLookup", "refreshTaskActivityFromSession",
]) {
  const start = source.search(new RegExp(`(?:async )?function ${name}\\(`));
  assert.ok(start >= 0, `missing bundled function ${name}`);
  vm.runInContext(source.slice(start, source.indexOf("\n}", start) + 2), context);
}

export async function settle(fixture) {
  await flushDispatch();
  await flushDispatch();
  await Promise.all(fixture.effects.notificationJobs);
}

export function pollSnapshot(fixture) {
  const { manager, task, effects } = fixture;
  return {
    task: structuredClone(task), current: structuredClone(manager.tasks.get(task.id)),
    pending: [...manager.pendingByParent].map(([id, tasks]) => [id, [...tasks]]),
    summaries: structuredClone([...manager.completedTaskSummaries]),
    notifications: structuredClone([...manager.notifications]),
    timers: [...manager.completionTimers], idleTimers: [...manager.idleDeferralTimers],
    removals: effects.removals, releases: effects.releases, acquisitions: effects.acquisitions,
    aborts: effects.aborts, wakes: structuredClone(effects.wakes),
    observed: [...manager.observedOutputSessions], todos: [...manager.observedIncompleteTodosBySession],
    dispatches: effects.dispatches.length,
  };
}

export async function pollFixture() {
  const logStart = logs.length;
  const fixture = failureNotificationFixture("failCrashedTask", "immediate");
  const { manager, task, effects, history } = fixture;
  delete manager.verifySessionExists;
  delete manager.checkSessionTodos;
  delete manager.checkAndInterruptStaleTasks;
  delete manager.pruneStaleTasksAndNotifications;
  manager.flushPendingParentWake = async () => {};
  Object.assign(effects, { todoReads: 0, getReads: 0, idleEvents: 0 });
  manager.client.session.todo = async () => { effects.todoReads++; return { data: [] }; };
  manager.client.session.get = async () => { effects.getReads++; return { data: { id: "child" } }; };
  manager.client.session.abort = async () => { effects.aborts++; return {}; };
  await fixture.resume();
  await flushDispatch();
  const prompt = fixture.persistPrompt();
  fixture.appendFinal(prompt);
  task.startedAt = new Date(Date.now() - 10000);
  task.progress.lastUpdate = task.startedAt;
  const originalMessages = manager.client.session.messages;
  let childMessages = history;
  manager.client.session.messages = (input) => input.path.id === "parent"
    ? originalMessages(input) : Promise.resolve({ data: childMessages });
  const setMessages = (messages) => { childMessages = messages; };
  const idle = () => {
    effects.idleEvents++;
    manager.handleEvent({ type: "session.idle", properties: { sessionID: task.sessionId } });
  };
  async function drive(entry) {
    if (entry === "poll") await manager.pollRunningTasks();
    else idle();
    await settle(fixture);
  }
  function hold(kind, response, occurrence = 1) {
    const held = deferred();
    const entered = deferred();
    const method = kind === "fallback" ? manager : manager.client.session;
    const key = kind === "fallback" ? "tryFallbackRetry" : kind;
    const original = method[key];
    let calls = 0;
    method[key] = (...args) => {
      if (kind === "messages" && args[0].path.id === "parent") return original(...args);
      if (++calls !== occurrence) return original(...args);
      entered.resolve();
      return held.promise;
    };
    return {
      entered: entered.promise,
      restore: () => { method[key] = original; },
      release: () => { method[key] = original; held.resolve(response); },
    };
  }
  async function change(changed) {
    if (changed === "resume") {
      setMessages(history);
      await manager.cancelTask(task.id, { skipNotification: true });
      await fixture.resumeNext();
      assert.equal(task.sessionId, "child");
      assert.equal(task.currentAttemptID, "same-attempt");
      assert.equal(effects.dispatches.length, 2);
    } else if (changed === "session") task.sessionId = "other-child";
    else if (changed === "attempt") task.currentAttemptID = "other-attempt";
    else if (changed === "identity") manager.tasks.set(task.id, structuredClone(task));
    else if (changed === "cancel") await manager.cancelTask(task.id, { skipNotification: true });
    manager.observedOutputSessions.clear();
    manager.observedIncompleteTodosBySession.set("child", true);
    task.consecutiveMissedPolls = 7;
  }
  async function dispose() {
    await fixture.dispose();
    for (const timer of manager.idleDeferralTimers.values()) clearTimeout(timer);
    manager.idleDeferralTimers.clear();
    assert.equal(logs.slice(logStart).some(([message]) => /Poll error for task|Error in session.idle handler/.test(message)), false,
      "actual entry must not hide fixture or classifier exceptions");
  }
  return { ...fixture, prompt, setMessages, drive, idle, hold, change, dispose };
}

export function reply(fixture, info = {}, parts = []) {
  return { info: { ...final.info, id: "own-response", parentID: fixture.prompt.info.id, ...info }, parts };
}

export function fakeIdleTimers() {
  const timers = [];
  const original = context.setTimeout;
  context.setTimeout = (callback, delay) => {
    assert.ok(delay <= 5000);
    const timer = { callback, delay };
    timers.push(timer);
    return timer;
  };
  return { timers, restore: () => { context.setTimeout = original; } };
}

export { context, final, logs };

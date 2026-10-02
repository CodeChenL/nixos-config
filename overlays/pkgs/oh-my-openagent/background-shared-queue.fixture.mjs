import assert from "node:assert/strict";
import { context } from "./background-lifecycle.fixture.mjs";
import { deferred } from "./background-continuation.fixture.mjs";
import { launchFixture, settleLaunch } from "./background-launch.fixture.mjs";

export function sharedQueueFixture(suite, existing = false) {
  const fixture = launchFixture(suite);
  const { manager, effects } = fixture;
  const key = "fixture/fallback";
  const tasks = [fixture.task, structuredClone(fixture.task)];
  const aborts = tasks.map(() => deferred()), permits = tasks.map(() => deferred());
  const acquired = [], aborted = [], created = [], callbacks = [], sdk = [], operations = [];
  tasks.forEach((task, index) => {
    Object.assign(task, { id: `bg-${index}`, description: `Request ${index}`, prompt: `Work for task ${index}`,
      attempts: [], currentAttemptID: undefined, attemptCount: 0, sessionId: undefined,
      parentMessageId: `parent-message-${index}`, cwd: `/isolated-project/task-${index}`,
      skillContent: `Skill ${index}`, fallbackChain: [{ providers: ["fixture"], model: "fallback" }],
      onSessionCreated: (sessionID) => callbacks.push([task.id, sessionID]),
    });
    const attempt = context.startAttempt(task, { providerID: "fixture", modelID: "primary" });
    assert.ok(context.bindAttemptSession(task, attempt.attemptId, `old-${index}`));
  });
  manager.tasks = new Map(tasks.map((task) => [task.id, task]));
  manager.pendingByParent.set("parent", new Set(tasks.map((task) => task.id)));
  manager.tasksByParentSession.set("parent", new Set(tasks.map((task) => task.id)));
  manager.processKey = context.Manager.prototype.processKey;
  manager.concurrencyManager.acquire = async (rawKey, taskID) => {
    acquired.push([rawKey, taskID]);
    await permits[tasks.findIndex((task) => task.id === taskID)].promise;
  };
  manager.client.session.abort = async ({ path }) => {
    const index = tasks.findIndex((_task, taskIndex) => path.id === `old-${taskIndex}`);
    aborted.push(path.id); await aborts[index].promise; return {};
  };
  manager.client.session.create = async (input) => {
    const taskID = acquired.at(-1)[1], sessionID = `retry-${taskID}`;
    created.push({ taskID, sessionID, input }); return { data: { id: sessionID } };
  };
  manager.client.session.promptAsync = async (input) => {
    sdk.push(input); return { response: { status: 204 } };
  };
  const initialQueue = [];
  if (existing) manager.queuesByKey.set(key, initialQueue);
  async function begin() {
    for (const task of tasks) operations.push(manager.tryFallbackRetry(task,
      { name: "APIError", message: "HTTP 429 shared queue", statusCode: 429 }, "queue.fixture"));
    await settleLaunch();
    assert.deepEqual(aborted, ["old-0", "old-1"]);
    assert.deepEqual(tasks.map((task) => task.status), ["pending", "pending"]);
    assert.equal(acquired.length, 0);
    assert.equal(manager.queuesByKey.has(key), existing);
    assert.equal(manager.processKey, context.Manager.prototype.processKey);
    assert.equal(manager.startTask, context.Manager.prototype.startTask);
  }
  async function release() {
    aborts.forEach((barrier) => barrier.resolve()); permits.forEach((barrier) => barrier.resolve());
    await settleLaunch(); await Promise.all(operations); await settleLaunch();
  }
  suite.after(release);
  const observe = () => ({ statuses: tasks.map((task) => task.status),
    sessions: tasks.map((task) => task.sessionId), created: created.map(({ taskID }) => taskID),
    prompts: sdk.map((input) => [input.path.id, input.body.parts[0].text]),
    queue: (manager.queuesByKey.get(key) ?? []).map((item) => item.task.id),
    processing: [...manager.processingKeys],
  });
  return { manager, tasks, effects, key, aborts, permits, acquired, created, callbacks, sdk,
    initialQueue, begin, release, observe };
}

export function assertQueueHealthy(fixture, indices = [0, 1]) {
  const { manager, tasks, key, created, callbacks, sdk, effects } = fixture;
  assert.equal(created.length, indices.length);
  assert.equal(sdk.length, indices.length);
  for (const index of indices) {
    const task = tasks[index], sessionID = `retry-${task.id}`;
    assert.equal(task.status, "running");
    assert.equal(task.sessionId, sessionID);
    assert.equal(task.currentAttemptID, task.attempts[1].attemptId);
    assert.equal(task.attempts[1].sessionId, sessionID);
    assert.equal(created.filter((item) => item.taskID === task.id).length, 1);
    assert.equal(callbacks.filter(([taskID, id]) => taskID === task.id && id === sessionID).length, 1);
    const requests = sdk.filter((input) => input.path.id === sessionID);
    assert.equal(requests.length, 1);
    assert.equal(requests[0].body.parts[0].text, task.prompt);
    assert.equal(requests[0].body.system, task.skillContent);
    assert.equal(requests[0].body.model.modelID, "fallback");
    assert.equal(requests[0].query.directory, task.cwd);
    const bootstrap = effects.bootstraps.filter((input) => input.sessionID === sessionID);
    assert.equal(bootstrap.length, 1);
    assert.equal(bootstrap[0].promptText, task.prompt);
  }
  assert.equal(manager.queuesByKey.get(key).length, 0);
  assert.equal(manager.processingKeys.size, 0);
}

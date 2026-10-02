import assert from "node:assert/strict";
import { context } from "./background-lifecycle.fixture.mjs";
import { deferred } from "./background-continuation.fixture.mjs";
import { launchFixture, settleLaunch } from "./background-launch.fixture.mjs";

export function resumePromptFixture(suite) {
  const fixture = launchFixture(suite);
  const { manager, task, effects, sdk } = fixture;
  const original = task.prompt;
  const permit = deferred(), queued = [], created = [];
  const prompt = manager.client.session.promptAsync;
  let nextFailure;
  manager.client.session.promptAsync = async (input) => {
    if (nextFailure) {
      const error = nextFailure; nextFailure = undefined;
      sdk.push(input); throw error;
    }
    return prompt(input);
  };
  manager.processKey = context.Manager.prototype.processKey;
  const acquire = manager.concurrencyManager.acquire;
  manager.concurrencyManager.acquire = async (key, taskID) => {
    if (taskID) await permit.promise;
    return acquire(key, taskID);
  };
  const queueSet = manager.queuesByKey.set.bind(manager.queuesByKey);
  manager.queuesByKey.set = (key, queue) => {
    for (const item of queue) queued.push({ key, task: item.task, input: item.input, attemptID: item.attemptID });
    return queueSet(key, queue);
  };
  manager.client.session.create = async () => {
    const sessionID = created.length === 0 ? "child" : `prompt-retry-${created.length}`;
    created.push(sessionID); return { data: { id: sessionID } };
  };
  task.fallbackChain = [{ providers: ["fixture"], model: "fallback" }];
  async function ready(launchFailure = false) {
    await fixture.start(); await settleLaunch();
    if (launchFailure) fixture.initial.reject(new Error("HTTP 429 initial request"));
    else fixture.initial.resolve({ response: { status: 204 } });
    await settleLaunch();
  }
  async function stop(expire = true) {
    assert.equal(await manager.cancelTask(task.id, { skipNotification: true }), true);
    if (expire) {
      const reservation = context.promptAsyncReservations.get(task.sessionId);
      if (reservation) reservation.expiresAt = 0;
    }
  }
  const resume = (current) => manager.resume({ sessionId: task.sessionId, parentSessionId: "parent", prompt: current });
  const failNext = (message = "HTTP 429 continuation request") => { nextFailure = new Error(message); };
  async function retryStored() {
    const sessionID = task.sessionId;
    const attempt = context.startAttempt(task, task.model);
    assert.ok(context.bindAttemptSession(task, attempt.attemptId, sessionID));
    const operation = manager.tryFallbackRetry(task,
      { name: "APIError", message: "HTTP 429 future retry", statusCode: 429 }, "prompt.fixture");
    await settleLaunch();
    return operation;
  }
  async function assertRetry(current) {
    assert.equal(task.status, "pending", "real resume/launch failure must reach the actual retry helper");
    fixture.abort.resolve(); await settleLaunch();
    assert.equal(queued.length, 1);
    assert.equal(queued[0].task, task);
    assert.equal(queued[0].attemptID, task.currentAttemptID);
    assert.equal(created.length, 1, "real processor is held at acquisition");
    permit.resolve(); await settleLaunch();
    assert.equal(task.status, "running");
    assert.equal(task.sessionId, "prompt-retry-1");
    assert.equal(created.length, 2);
    const requests = sdk.filter((input) => input.path.id === task.sessionId);
    assert.equal(requests.length, 1);
    assert.equal(requests[0].body.parts[0].text, current, "new session SDK body must use current input, not initial work");
    assert.equal(task.prompt, current);
    assert.equal(queued[0].input.prompt, current, "actual helper queue must retain the accepted request");
    assert.notEqual(queued[0].input.prompt, current === original ? "Unaccepted work" : original);
    assert.equal(requests[0].body.model.modelID, "fallback");
    const bootstraps = effects.bootstraps.filter((input) => input.sessionID === task.sessionId);
    assert.equal(bootstraps.length, 1);
    assert.equal(bootstraps[0].promptText, current);
    assert.equal(manager.queuesByKey.get("fixture/fallback").length, 0);
    assert.equal(manager.processingKeys.size, 0);
  }
  suite.after(async () => { fixture.abort.resolve(); permit.resolve(); await settleLaunch(); });
  return { ...fixture, original, queued, created, permit, ready, stop, resume, failNext, retryStored, assertRetry };
}

import assert from "node:assert/strict";
import vm from "node:vm";
import { context, source } from "./background-lifecycle.fixture.mjs";
import { launchFixture, settleLaunch } from "./background-launch.fixture.mjs";

for (const name of ["getStringField", "resolveSessionEventID", "isEmptyNoProgressAssistantTurnInfo",
  "messageUpdatedInfoHasParentWakeOutput"]) {
  const start = source.search(new RegExp(`(?:async )?function ${name}\\(`));
  assert.ok(start >= 0, `missing bundled function ${name}`);
  vm.runInContext(source.slice(start, source.indexOf("\n}", start) + 2), context);
}

export function sharedFallbackFixture(suite) {
  const fixture = launchFixture(suite);
  const { manager, task, effects } = fixture;
  const operations = [];
  effects.registry = [];
  effects.contextAwaits = 0;
  const clearBootstrap = context.clearDelegatedChildSessionBootstrap;
  context.clearDelegatedChildSessionBootstrap = (sessionID) => effects.registry.push(sessionID);
  context.subagentSessions.clear();
  const seedObservations = () => {
    manager.observedOutputSessions.add("child");
    manager.observedIncompleteTodosBySession.set("child", false);
    context.subagentSessions.add("child");
  };
  const snapshot = () => ({ ...fixture.snapshot(),
    registered: structuredClone(manager.tasks.get(task.id)),
    registry: [...effects.registry], subagents: [...context.subagentSessions],
    observed: [...manager.observedOutputSessions], todos: [...manager.observedIncompleteTodosBySession],
  });
  const observe = () => ({ status: task.status,
    queued: [...manager.queuesByKey.values()].reduce((count, queue) => count + queue.length, 0),
    processed: effects.processed.length, wakes: effects.wakes.length,
  });
  async function begin(entry = "wrapper", phase = "abort") {
    await fixture.start(); await settleLaunch();
    fixture.initial.resolve({ response: { status: 204 } }); await settleLaunch();
    task.fallbackChain = [{ providers: ["fixture"], model: "fallback" }];
    if (phase === "context") {
      const messages = manager.client.session.messages;
      manager.client.session.messages = async (input) => {
        if (input.path.id === "parent" && task.status === "pending") {
          effects.contextAwaits++; await fixture.setup.promise;
        }
        return messages(input);
      };
    }
    const errorInfo = { name: "APIError", message: "HTTP 429 shared retry", statusCode: 429 };
    if (entry === "resume") {
      assert.equal(await manager.cancelTask(task.id, { skipNotification: true }), true);
      context.promptAsyncReservations.get("child").expiresAt = 0;
      const prompt = manager.client.session.promptAsync;
      let rejectResume = true;
      manager.client.session.promptAsync = async (input) => {
        if (rejectResume) {
          rejectResume = false; fixture.sdk.push(input); throw new Error(errorInfo.message);
        }
        return prompt(input);
      };
      await fixture.resume();
    } else if (entry === "session.error") {
      operations.push(manager.handleSessionErrorEvent({ task, errorInfo, errorMessage: errorInfo.message }));
    } else if (entry === "message.updated") {
      manager.handleEvent({ type: entry, properties: { sessionID: "child",
        info: { role: "assistant", error: { name: "APIError", data: { message: errorInfo.message } } } } });
    } else if (entry === "session.status") {
      manager.handleEvent({ type: entry, properties: { sessionID: "child",
        status: { type: "retry", message: errorInfo.message } } });
    } else if (entry === "poll") {
      const status = manager.client.session.status;
      manager.client.session.status = async () => ({ data: { child: { type: "retry", message: errorInfo.message } } });
      operations.push(manager.pollRunningTasks());
      await settleLaunch(); manager.client.session.status = status;
    } else {
      operations.push(manager.tryFallbackRetry(task, errorInfo, "shared.fixture"));
    }
    await settleLaunch();
    assert.equal(task.status, "pending", "actual shared helper must schedule the new attempt");
    assert.equal(task.attempts.length, 2);
    assert.equal(task.attemptCount, 1);
    assert.equal(observe().queued, 0, "abort is still held");
    if (phase === "context") {
      fixture.abort.resolve(); await settleLaunch();
      assert.equal(effects.contextAwaits, 1, "actual parent context resolver is awaiting SDK messages");
      assert.equal(observe().queued, 1);
      assert.equal(observe().wakes, 0);
    }
  }
  async function resumeNext() {
    assert.ok(context.bindAttemptSession(task, task.currentAttemptID, "child"));
    await fixture.next(); seedObservations();
  }
  async function releaseRetry() {
    fixture.abort.resolve(); fixture.setup.resolve(); await settleLaunch();
    await Promise.all(operations); await fixture.release(); await settleLaunch();
  }
  suite.after(async () => {
    await Promise.all(operations);
    context.clearDelegatedChildSessionBootstrap = clearBootstrap;
    context.subagentSessions.clear();
  });
  return { ...fixture, begin, resumeNext, releaseRetry, seedObservations, snapshot, observe };
}

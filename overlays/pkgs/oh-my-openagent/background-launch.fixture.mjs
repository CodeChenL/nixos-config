import assert from "node:assert/strict";
import vm from "node:vm";
import { context, source } from "./background-lifecycle.fixture.mjs";
import { deferred, flushDispatch } from "./background-continuation.fixture.mjs";
import { terminalFixture, terminalSnapshot } from "./background-terminal.fixture.mjs";

Object.assign(context, {
  AbortController, PROMPT_TIMEOUT_MS: 5000, FALLBACK_AGENT: "general",
  TRANSIENT_RETRY_RESERVATION_OWNER: "model-suggestion-retry",
  deleteRecentPromptDispatch() {}, releaseInFlightPromptMatchingDedupe() {}, schedulePromptQueueDrain() {},
  applySessionPromptParams() {}, buildLocalSessionUrl: () => "http://fixture/session",
});
vm.runInContext(source.slice(source.indexOf("var RETRYABLE_ERROR_NAMES ="),
  source.indexOf("function hasProviderAutoRetrySignal(")), context);
for (const name of [
  "routePromptRetry", "promptWithRetryInDirectory", "promptWithModelSuggestionRetry",
  "createPromptTimeoutContext", "isInternalPromptDispatchAccepted", "extractMessage2",
  "isAgentResolutionError", "shouldReleaseReservationAfterFailedAsyncPrompt",
  "readProperty", "extractMessage", "parseModelSuggestion", "getErrorMessage6",
  "isAgentNotFoundError", "buildFallbackBody", "getPromptReservation", "deletePromptReservation",
  "isTransientRetryReservationOwner", "reservationSourceMatches", "releasePromptAsyncReservation",
  "hasProviderAutoRetrySignal", "isRetryableModelError", "shouldRetryError", "getNextFallback",
  "hasMoreFallbacks", "canonicalizeModelID2", "startAttempt", "scheduleRetryAttempt",
  "tryFallbackRetry", "formatAttemptModelSummary", "getPreviousAttempt", "setSessionTools",
]) {
  const start = source.search(new RegExp(`(?:async )?function ${name}\\(`));
  assert.ok(start >= 0, `missing bundled function ${name}`);
  vm.runInContext(source.slice(start, source.indexOf("\n}", start) + 2), context);
}
context.defaultFallbackRetryHandlerDeps = {
  log: context.log2, shouldRetryError: context.shouldRetryError,
  getNextFallback: context.getNextFallback, hasMoreFallbacks: context.hasMoreFallbacks,
  readProviderModelsCache: () => ({ connected: ["fixture"] }),
  readConnectedProvidersCache: () => ["fixture"], selectFallbackProvider: (providers) => providers[0],
  transformModelForProvider: (_provider, model) => model, isProviderExhaustionFallbackEligible: () => false,
};

export const settleLaunch = async () => { await flushDispatch(); await flushDispatch(); };
export function launchFixture(suite, phase = "prompt") {
  const result = terminalFixture("startTask");
  const { manager, task, effects } = result;
  const initial = deferred(), retry = deferred(), setup = deferred(), abort = deferred();
  const sdk = [];
  Object.assign(effects, { setup: [], bootstraps: [], agents: [], processed: [] });
  context.store.clear();
  context.setSessionAgent = (...args) => effects.agents.push(args);
  context.updateSessionAgent = context.setSessionAgent;
  context.registerDelegatedChildSessionBootstrap = (input) => effects.bootstraps.push(input);
  delete manager.tryFallbackRetry;
  manager.processKey = (key) => effects.processed.push(key);
  manager.concurrencyManager.cancelWaiter = () => {};
  Object.assign(task, { status: "pending", prompt: "Initial work A", attemptCount: 0 });
  task.attempts[0].status = "pending";
  manager.pendingByParent.set("parent", new Set([task.id]));
  manager.client.session.get = async () => {
    effects.setup.push("parent");
    if (phase === "parent") await setup.promise;
    return { data: { directory: "/isolated-project" } };
  };
  manager.client.session.create = async () => {
    effects.setup.push("create");
    if (phase === "create") await setup.promise;
    return { data: { id: "child" } };
  };
  if (phase.endsWith("gate")) manager.client.session.status = async () => {
    if (!task.continuation && (phase === "gate" || effects.agents.at(-1)?.[1] === "general")) {
      effects.setup.push(phase); await setup.promise;
    }
    return { data: { child: { type: "idle" }, parent: { type: "idle" } } };
  };
  manager.client.session.promptAsync = async (input) => {
    sdk.push(input);
    if (input.body.parts[0].text === "Initial work A" && input.body.model?.modelID !== "fallback") {
      return input.body.agent === "general" ? retry.promise : initial.promise;
    }
    effects.dispatches.push(input);
    return { response: { status: 204 } };
  };
  manager.client.session.abort = async () => { effects.aborts++; await abort.promise; return {}; };
  const start = () => manager.startTask({ task, attemptID: task.currentAttemptID, input: {
    agent: "fixture", parentSessionId: "parent", description: "Initial launch A", prompt: task.prompt,
    model: task.model, onSessionCreated: async () => {
      effects.setup.push("callback");
      if (phase === "callback") await setup.promise;
    },
  } });
  const next = async () => {
    const old = task.continuation;
    assert.equal(await manager.cancelTask(task.id, { skipNotification: true }), true);
    const reservation = context.promptAsyncReservations.get("child");
    if (reservation) reservation.expiresAt = 0;
    await result.resume();
    await settleLaunch();
    assert.equal(task.status, "running");
    assert.notEqual(task.continuation, old);
    assert.equal(task.sessionId, "child");
    assert.ok(manager.pendingByParent.get("parent").has(task.id));
    assert.equal(effects.dispatches.at(-1).body.parts[0].id, task.continuation.partID);
  };
  const occupy = async () => {
    context.promptAsyncReservations.get("child").expiresAt = 0;
    await context.promptWithRetryInDirectory(manager.client, {
      path: { id: "child" }, body: { agent: "fixture", parts: [{ type: "text", text: "Replacement owner" }] },
    }, manager.directory);
    assert.equal(sdk.at(-1).body.parts[0].text, "Replacement owner");
  };
  const snapshot = () => ({ ...terminalSnapshot(result), aborts: effects.aborts,
    sdk: sdk.map((input) => [input.path, input.body.agent, input.query]),
    tools: structuredClone([...context.store]), agents: structuredClone(effects.agents),
    bootstraps: structuredClone(effects.bootstraps), processed: [...effects.processed],
    queues: structuredClone([...manager.queuesByKey]),
    reservation: context.promptAsyncReservations.get("child"),
  });
  suite.after(async () => {
    initial.resolve({}); retry.resolve({}); setup.resolve(); abort.resolve();
    await settleLaunch(); await result.dispose(); context.promptAsyncReservations.clear();
  });
  return { ...result, initial, retry, setup, abort, sdk, start, next, occupy, snapshot };
}

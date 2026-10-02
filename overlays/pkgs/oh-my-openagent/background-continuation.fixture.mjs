import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import vm from "node:vm";
import { context, final, fixture, logs, source, user } from "./background-lifecycle.fixture.mjs";

Object.assign(context, {
  crypto: webcrypto, Error, setTimeout, clearTimeout,
  log: (...args) => logs.push(args),
  ACTIVE_SESSION_STATUSES: new Set(["busy", "retry", "running"]),
  DEFAULT_SESSION_STATUS_TIMEOUT_MS: 5000,
  DEFAULT_PROMPT_ASYNC_POST_DISPATCH_HOLD_MS: 2000,
  DEFAULT_PROMPT_SEMANTIC_DEDUPE_HOLD_MS: 15000,
  DEFAULT_PROMPT_DISPATCH_TIMEOUT_MS: 30000,
  DEFAULT_PROMPT_QUEUE_RETRY_MS: 250,
  promptAsyncReservations: new Map(),
  expiredReservationHandler: undefined,
  getAgentToolRestrictions: () => ({}),
  setSessionTools() {},
  createInternalAgentTextPart: (text) => ({ type: "text", text }),
  createSemanticPromptDedupeKey: (input) => input.body.parts[0].text,
  tryResolveDispatchClientSync: (client) => ({ client, route: "in-process" }),
  getQueuedPromptBlocker: () => undefined,
  isPromptQueueDraining: () => false,
  coalesceRecentSemanticPromptDispatch: () => undefined,
  getPromptGateMessagesFetchTimeoutMs: () => 5000,
  rememberRecentPromptDispatch() {},
  QUESTION_TOOL_NAMES: new Set(["question"]),
});
for (const name of [
  "withStatusTimeout", "getSessionStatusPayload", "isActiveSessionStatusType", "isSessionActive",
  "withDispatchTimeout", "dispatchAfterSessionIdle", "hasObjectSessionPath", "isObjectPathTypeError",
  "dispatchWithPathCompatibility", "dispatchInternalPrompt", "extractPromptFailureMessage",
  "isAmbiguousPromptDispatchFailure", "isAmbiguousPostDispatchPromptFailure",
  "notifyExpiredReservation", "pruneExpiredReservations", "getActiveReservation",
  "setPromptReservation", "finishPromptReservation",
  "getMessagesData", "getPromptQuery", "messageRole", "messageFinish", "messageCompleted",
  "messageHasTerminalError", "partToolName", "partIsToolCall", "partIsQuestionTool",
  "partIsUnansweredQuestionTool", "partIsWaitingOnTool", "partIsUnresolvedTool",
  "partHasSubstantiveAssistantOutput", "messageHasQuestionTool", "messageHasWaitingTool",
  "messageHasUnresolvedTool", "messageHasSubstantiveAssistantOutput",
  "latestAssistantTurnBlocksInternalPrompt", "sessionLatestAssistantBlocksInternalPrompt",
  "isPromptMessageInspectionAborted", "extractErrorName2", "extractErrorMessage", "extractErrorStatusCode",
  "toTaskModel", "getAttemptIndex", "getAttempt", "getCurrentAttempt",
  "projectTaskFromCurrentAttempt", "finalizeAttempt", "findAttemptBySession",
]) {
  const start = source.search(new RegExp(`(?:async )?function ${name}\\(`));
  assert.ok(start >= 0, `missing bundled function ${name}`);
  const end = source.indexOf("\n}", start) + 2;
  vm.runInContext(source.slice(start, end), context);
}

export function deferred() {
  return Promise.withResolvers();
}

export const flushDispatch = () => new Promise((resolve) => setImmediate(resolve));

export function continuationFixture(oldReply = final) {
  context.promptAsyncReservations.clear();
  const history = [user, structuredClone(oldReply)];
  history[1].info.parentID = user.info.id;
  const result = fixture(history, { child: { type: "idle" } });
  const { manager, task, effects } = result;
  const oldTime = new Date(Date.now() - 60000);
  Object.assign(task, {
    status: "completed", agent: "fixture", description: "Continuation test",
    startedAt: oldTime, completedAt: oldTime, currentAttemptID: "same-attempt",
    attempts: [{ attemptId: "same-attempt", sessionId: "child", status: "completed",
      startedAt: oldTime, completedAt: oldTime }],
  });
  Object.assign(effects, { dispatches: [], acquisitions: 0, releases: 0, removals: 0 });
  delete manager.resolveTaskAttemptBySession;
  delete manager.cleanupPendingByParent;
  Object.assign(manager, {
    pendingByParent: new Map(), tasksByParentSession: new Map([["parent", new Set([task.id])]]),
    observedIncompleteTodosBySession: new Map(),
    concurrencyManager: {
      getConcurrencyKey: (key) => key,
      acquire: async () => { effects.acquisitions++; },
      release: () => { effects.releases++; },
    },
    startPolling() {}, stopPolling() {},
    scheduleTaskRemoval: () => { effects.removals++; },
  });
  manager.client.session.promptAsync = async (input) => {
    effects.dispatches.push(input);
    return { response: { status: 204 } };
  };
  function persistPrompt(index = effects.dispatches.length - 1) {
    const input = effects.dispatches[index];
    assert.ok(input, "the real dispatcher must have sent the continuation");
    const message = {
      info: { id: `user-resume-${index}`, role: "user" },
      parts: input.body.parts.map((part) => ({ ...part })),
    };
    history.push(message);
    return message;
  }
  function appendFinal(parent, id = "assistant-resume") {
    history.push({ ...structuredClone(final), info: { ...final.info, id, parentID: parent.info.id } });
  }
  const resume = () => manager.resume({ sessionId: "child", parentSessionId: "parent", prompt: "Continue work" });
  return { ...result, history, persistPrompt, appendFinal, resume };
}

export const oldReplies = {
  final,
  error: { ...final, info: { ...final.info, error: { name: "APIError", data: { message: "old error" } } } },
  truncated: { ...final, info: { ...final.info, finish: "length" } },
};

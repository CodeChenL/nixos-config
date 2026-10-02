import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const bundle = process.env.OMO_BUNDLE;
assert.equal(typeof bundle, "string", "OMO_BUNDLE must name the built plugin");
export const source = String(readFileSync(bundle, "utf8"));
export const logs = [];
export const context = vm.createContext({
  log2: (...args) => logs.push(args),
  normalizeSDKResponse: (response) => response.data ?? response,
  messagesInDirectory: (client, input) => client.session.messages(input),
  removeTaskToastTracking() {},
  getTaskToastManager: () => undefined,
  clearSessionAgent() {},
  clearDelegatedChildSessionBootstrap() {},
  SessionCategoryRegistry: { remove() {} },
  subagentSessions: new Set(),
  ACTIVE_SESSION_STATUSES3: new Set(["busy", "retry", "running"]),
  KNOWN_TERMINAL_STATUSES: new Set(["idle", "interrupted"]),
  SESSION_NEXT_EVENT_PREFIX: "session.next.",
  SESSION_NEXT_EVENT_PREFIX2: "session.next.",
  MIN_SESSION_GONE_POLLS: 3,
  isAgentNotFoundError: () => false,
  shouldRetryError: () => true,
  hasMoreFallbacks: () => false,
  isTerminalSessionError: () => false,
  isMessagePartForSession: (part, id) => !part?.sessionID || part.sessionID === id,
  resolveMessageEventSessionID: (props) => props?.sessionID ?? props?.part?.sessionID,
  INTERNAL_INITIATOR_MARKER_DETECT_PATTERN: /<!--\s*OMO_INTERNAL_INITIATOR\s*-->/,
});

for (const name of [
  "isRecord", "getStringField3", "getRecordField", "getBooleanField", "getDateField",
  "resolveState", "buildPartInfo", "resolveMessagePartInfo", "hasOutputSignalFromPart",
  "hasInternalInitiatorMarker", "isInternalInitiatorTextPart",
  "isActiveSessionStatus2", "isTerminalSessionStatus", "observeEventForWatchdog",
]) {
  const start = source.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `missing bundled function ${name}`);
  const end = source.indexOf("\n}", start) + 2;
  vm.runInContext(source.slice(start, end), context);
}
const start = source.indexOf("class BackgroundManager {");
assert.ok(start >= 0);
const end = source.indexOf("\n}\n// packages/", start) + 2;
vm.runInContext(source.slice(start, end) + "\nthis.Manager = BackgroundManager;", context);

export const user = { info: { id: "user-1", role: "user" }, parts: [] };
export const final = {
  info: { id: "assistant-1", role: "assistant", finish: "stop", time: { completed: 2 } },
  parts: [{ type: "text", text: "Done", synthetic: false }],
};

export function fixture(messages = [user], statuses = {}) {
  const effects = { aborts: 0, notifications: [], reads: 0 };
  const task = { id: "bg-test", sessionId: "child", parentSessionId: "parent", status: "running" };
  const manager = Object.create(context.Manager.prototype);
  Object.assign(manager, {
    tasks: new Map([[task.id, task]]),
    directory: "/isolated-project",
    pollingInFlight: false,
    observedOutputSessions: new Set(),
    parentWakeTextDeltaBuffers: new Map(),
    idleDeferralTimers: new Map(),
    completionTimers: new Map(),
    config: {},
    client: { session: {
      status: async () => ({ data: statuses }),
      messages: async () => { effects.reads++; return { data: messages }; },
    } },
    parentWakeNotifier: {
      getDispatchedParentWakes: () => new Map(),
      recordParentSessionActivity() {},
      reserveNotificationPreparation() {},
      releaseNotificationPreparation() {},
    },
    logger: (...args) => logs.push(args),
    resolveTaskAttemptBySession: () => ({ task, isCurrent: true }),
    shouldHoldDispatchedParentWakeForTextDelta: () => false,
    clearDispatchedParentWake() {},
    pruneStaleTasksAndNotifications() {},
    checkAndInterruptStaleTasks: async () => {},
    verifySessionExists: async () => true,
    checkSessionTodos: async () => false,
    tryFallbackRetry: async () => false,
    taskHistory: { record() {} },
    abortSessionWithLogging: async () => { effects.aborts++; return true; },
    updateBackgroundTaskMarker() {},
    markForNotification() {},
    enqueueNotificationForParent: async (_id, callback) => callback(),
    notifyParentSession: async () => { effects.notifications.push(task.status); },
    cleanupPendingByParent() {},
    clearNotificationsForTask() {},
    scheduleTaskRemoval() {},
    onSubagentSessionDeleted: async () => {},
  });
  return { manager, task, effects };
}

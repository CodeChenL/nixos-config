import assert from "node:assert/strict";
import { test } from "node:test";
import { context, final, fixture, user } from "./background-lifecycle.fixture.mjs";

test("synthetic user memory cannot become observed assistant output", async () => {
  const { manager, task, effects } = fixture();
  manager.handleEvent({ type: "message.part.updated", properties: {
    sessionID: "child", part: { id: "memory", sessionID: "child", type: "text",
      synthetic: true, text: "<memory_context>Remember this</memory_context>" },
  } });
  assert.equal(manager.observedOutputSessions.has("child"), false);
  await manager.pollRunningTasks();
  assert.equal(task.status, "running");
  assert.equal(effects.aborts, 0);
});

test("role-less user text is not proof of assistant output", () => {
  assert.equal(context.hasOutputSignalFromPart({ sessionID: "child", type: "text", text: "Task" }, "child"), false);
});

test("real assistant text and stream deltas remain output signals", () => {
  assert.equal(context.hasOutputSignalFromPart({ sessionID: "child", role: "assistant", type: "text", text: "Done" }, "child"), true);
  assert.equal(context.hasOutputSignalFromPart({ sessionID: "child", field: "text", delta: "Done" }, "child"), true);
});

test("cached progress never completes a session with only a user message", async () => {
  const { manager, task, effects } = fixture();
  manager.observedOutputSessions.add("child");
  await manager.tryCompleteTask(task, "polling (session gone from status)");
  assert.equal(task.status, "running");
  assert.equal(effects.aborts, 0);
  assert.equal(effects.notifications.length, 0);
});

test("starting assistant is not a completed task", async () => {
  const { manager, task, effects } = fixture([user, { info: { role: "assistant" }, parts: [] }]);
  await manager.tryCompleteTask(task, "polling");
  assert.equal(task.status, "running");
  assert.equal(effects.aborts, 0);
});

test("a tool-call step does not stop the remaining agent loop", async () => {
  const { manager, task, effects } = fixture([user, {
    info: { role: "assistant", finish: "tool-calls", time: { completed: 2 } },
    parts: [{ type: "tool", state: { status: "completed" } }],
  }]);
  await manager.tryCompleteTask(task, "polling");
  assert.equal(task.status, "running");
  assert.equal(effects.aborts, 0);
});

test("pending tools prevent completion even with final text", async () => {
  const { manager, task, effects } = fixture([user, {
    ...final, parts: [...final.parts, { type: "tool", state: { status: "running" } }],
  }]);
  await manager.tryCompleteTask(task, "polling");
  assert.equal(task.status, "running");
  assert.equal(effects.aborts, 0);
});

test("successful final reply completes and notifies normally", async () => {
  const { manager, task, effects } = fixture([user, final]);
  await manager.tryCompleteTask(task, "polling");
  assert.equal(task.status, "completed");
  assert.deepEqual(effects.notifications, ["completed"]);
});

test("a new user message invalidates the old completed reply", async () => {
  const { manager, task, effects } = fixture([user, final, user]);
  await manager.tryCompleteTask(task, "polling");
  assert.equal(task.status, "running");
  assert.equal(effects.aborts, 0);
});

test("API error with a live session shell is reported as failure", async () => {
  const { manager, task, effects } = fixture();
  await manager.handleSessionErrorEvent({ task, errorInfo: { name: "APIError", message: "HTTP 502" },
    errorName: "APIError", errorMessage: "HTTP 502" });
  assert.equal(task.status, "error");
  assert.deepEqual(effects.notifications, ["error"]);
});

test("error-marked assistant cannot be completed successfully", async () => {
  const { manager, task, effects } = fixture([user, {
    info: { ...final.info, error: { name: "MessageAbortedError", data: { message: "Aborted" } } },
    parts: [],
  }]);
  await manager.tryCompleteTask(task, "polling");
  assert.equal(task.status, "error");
  assert.deepEqual(effects.notifications, ["error"]);
});

test("session read failure cannot fabricate completed output", async () => {
  const { manager } = fixture();
  manager.client.session.messages = async () => { throw new Error("read failed"); };
  assert.equal(await manager.validateSessionHasOutput("child"), false);
});

test("synthetic memory does not disarm the first response watchdog", () => {
  const calls = [];
  context.observeEventForWatchdog({ type: "message.part.updated", properties: {
    sessionID: "child", part: { type: "text", synthetic: true, text: "<memory_context>" },
  } }, { onAssistantProgress: (id) => calls.push(id) });
  assert.equal(calls.length, 0);
});

test("thinking-only final output is reported as failure", async () => {
  const { manager, task, effects } = fixture([user, {
    info: { ...final.info, finish: "length" },
    parts: [{ type: "reasoning", text: "Plan" }, { type: "text", text: " " }],
  }]);
  await manager.tryCompleteTask(task, "polling");
  assert.equal(task.status, "error");
  assert.deepEqual(effects.notifications, ["error"]);
});

test("truncated final text is not successful completion", async () => {
  const { manager, task, effects } = fixture([user, {
    ...final, info: { ...final.info, finish: "length" },
  }]);
  await manager.tryCompleteTask(task, "polling");
  assert.equal(task.status, "error");
  assert.deepEqual(effects.notifications, ["error"]);
});

test("SDK error response cannot complete a task", async () => {
  const { manager, task, effects } = fixture();
  manager.client.session.messages = async () => ({ error: "unavailable" });
  await manager.tryCompleteTask(task, "polling");
  assert.equal(task.status, "running");
  assert.equal(effects.aborts, 0);
});

test("old completion validation cannot stop a resumed task", async () => {
  const { manager, task, effects } = fixture([user, final]);
  manager.client.session.messages = async () => {
    task.sessionId = "resumed-child";
    return { data: [user, final] };
  };
  await manager.tryCompleteTask(task, "polling");
  assert.equal(task.status, "running");
  assert.equal(effects.aborts, 0);
});

import assert from "node:assert/strict";
import { test } from "node:test";
import { context } from "./background-lifecycle.fixture.mjs";
import { deferred } from "./background-continuation.fixture.mjs";
import { settleLaunch } from "./background-launch.fixture.mjs";
import { resumePromptFixture } from "./background-resume-prompt.fixture.mjs";

for (const previous of [false, true]) {
  test(`resume prompt: actual HTTP429 fallback replays ${previous ? "latest second" : "current"} request into a new SDK session`, async (suite) => {
    const fixture = resumePromptFixture(suite);
    await fixture.ready(); await fixture.stop();
    if (previous) {
      await fixture.resume("Accepted first continuation"); await settleLaunch(); await fixture.stop();
    }
    const current = previous ? "Latest second continuation B" : "Continue current work A";
    fixture.failNext(); await fixture.resume(current); await settleLaunch();
    assert.equal(fixture.sdk.at(-1).body.parts[0].text, current);
    await fixture.assertRetry(current);
  });
}

test("resume prompt: first-launch HTTP429 fallback still sends only the original request", async (suite) => {
  const fixture = resumePromptFixture(suite);
  await fixture.ready(true);
  assert.equal(fixture.sdk[0].body.parts[0].text, fixture.original);
  await fixture.assertRetry(fixture.original);
});

for (const accepted of [false, true]) {
  for (const skipped of ["active", "reserved", "acquire-failed"]) {
    test(`resume prompt: ${skipped} restores ${accepted ? "last accepted continuation" : "initial prompt"} for future fallback`, async (suite) => {
      const fixture = resumePromptFixture(suite);
      const { manager, task, sdk } = fixture;
      await fixture.ready(); await fixture.stop();
      const lastValid = accepted ? "Last accepted continuation" : fixture.original;
      if (accepted) {
        await fixture.resume(lastValid); await settleLaunch();
        await fixture.stop(skipped !== "reserved");
      } else if (skipped === "reserved") {
        context.promptAsyncReservations.get(task.sessionId).expiresAt = Date.now() + 60000;
      }
      const snapshot = manager.captureResumeTaskSnapshot(task), before = sdk.length;
      const status = manager.client.session.status, acquire = manager.concurrencyManager.acquire;
      if (skipped === "active") manager.client.session.status = async () => ({ data: { child: { type: "busy" } } });
      if (skipped === "acquire-failed") manager.concurrencyManager.acquire = async () => { throw new Error("acquisition rejected"); };
      if (skipped === "acquire-failed") await assert.rejects(fixture.resume("Unaccepted work"), /acquisition rejected/);
      else await fixture.resume("Unaccepted work");
      await settleLaunch();
      assert.equal(sdk.length, before, "unaccepted continuation never reaches SDK");
      assert.deepEqual(manager.captureResumeTaskSnapshot(task), snapshot);
      assert.equal(task.prompt, lastValid);
      assert.equal(manager.pendingByParent.size, 0);
      manager.client.session.status = status; manager.concurrencyManager.acquire = acquire;
      const operation = fixture.retryStored(); await settleLaunch();
      await fixture.assertRetry(lastValid); await operation;
    });
  }
}

for (const outcome of ["204", "HTTP 400 obsolete", "HTTP 429 obsolete", "Unexpected EOF", "active"]) {
  test(`resume prompt: obsolete ${outcome} callback cannot overwrite a newer accepted prompt`, async (suite) => {
    const fixture = resumePromptFixture(suite);
    const { manager, task, sdk } = fixture;
    await fixture.ready(); await fixture.stop();
    const held = deferred(); suite.after(() => held.resolve({ response: { status: 204 } }));
    const prompt = manager.client.session.promptAsync, status = manager.client.session.status;
    if (outcome === "active") {
      let first = true;
      manager.client.session.status = (input) => {
        if (first) { first = false; return held.promise; }
        return status(input);
      };
    } else {
      manager.client.session.promptAsync = (input) => {
        if (input.body.parts[0].text === "Obsolete continuation A") { sdk.push(input); return held.promise; }
        return prompt(input);
      };
    }
    await fixture.resume("Obsolete continuation A"); await settleLaunch(); await fixture.stop();
    const current = "Newer accepted continuation C";
    await fixture.resume(current); await settleLaunch();
    const snapshot = structuredClone(task), dispatchCount = sdk.length;
    if (outcome === "204") held.resolve({ response: { status: 204 } });
    else if (outcome === "active") held.resolve({ data: { child: { type: "busy" } } });
    else held.reject(new Error(outcome));
    await settleLaunch();
    assert.equal(task.prompt, current);
    assert.equal(task.status, "running");
    assert.deepEqual(structuredClone(task), snapshot);
    assert.equal(sdk.length, dispatchCount);
    assert.equal(fixture.queued.length, 0);
  });
}

for (const reject of [false, true]) {
  test(`resume prompt: obsolete acquisition ${reject ? "reject" : "resolve"} cannot commit over newer input`, async (suite) => {
    const fixture = resumePromptFixture(suite);
    const { manager, task } = fixture;
    await fixture.ready(); await fixture.stop();
    const held = deferred(), acquire = manager.concurrencyManager.acquire;
    suite.after(() => held.resolve());
    manager.concurrencyManager.acquire = () => held.promise;
    const operation = fixture.resume("Never acquired old request");
    const result = reject ? assert.rejects(operation, /obsolete acquisition/) : operation;
    await settleLaunch();
    assert.equal(task.prompt, fixture.original);
    await fixture.stop(); manager.concurrencyManager.acquire = acquire;
    const current = "Newer acquired continuation";
    await fixture.resume(current); await settleLaunch();
    const snapshot = structuredClone(task);
    if (reject) held.reject(new Error("obsolete acquisition")); else held.resolve();
    await result; await settleLaunch();
    assert.equal(task.prompt, current);
    assert.deepEqual(structuredClone(task), snapshot);
  });
}

test("resume prompt: ambiguous accepted SDK failure retains current request for a later fallback", async (suite) => {
  const fixture = resumePromptFixture(suite);
  await fixture.ready(); await fixture.stop();
  const current = "Possibly accepted current request";
  fixture.failNext("Unexpected EOF"); await fixture.resume(current); await settleLaunch();
  assert.equal(fixture.task.status, "running");
  const operation = fixture.manager.tryFallbackRetry(fixture.task,
    { name: "APIError", message: "HTTP 429 later event", statusCode: 429 }, "prompt.fixture");
  await settleLaunch(); await fixture.assertRetry(current); await operation;
});

test("resume prompt: cancellation after dispatch keeps submitted input without replaying a late failure", async (suite) => {
  const fixture = resumePromptFixture(suite);
  const { manager, task, sdk } = fixture;
  await fixture.ready(); await fixture.stop();
  const held = deferred(); suite.after(() => held.resolve({ response: { status: 204 } }));
  manager.client.session.promptAsync = (input) => { sdk.push(input); return held.promise; };
  const current = "Submitted then cancelled continuation";
  await fixture.resume(current); await settleLaunch(); await fixture.stop();
  const snapshot = structuredClone(task);
  held.reject(new Error("HTTP 429 cancelled request")); await settleLaunch();
  assert.equal(task.status, "cancelled");
  assert.equal(task.prompt, current);
  assert.deepEqual(structuredClone(task), snapshot);
  assert.equal(fixture.queued.length, 0);
  assert.equal(fixture.created.length, 1);
});

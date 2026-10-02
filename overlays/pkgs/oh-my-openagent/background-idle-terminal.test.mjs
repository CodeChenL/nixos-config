import assert from "node:assert/strict";
import { test } from "node:test";
import { fakeIdleTimers, final, pollFixture, pollSnapshot, reply, settle } from "./background-poll.fixture.mjs";

for (const entry of ["poll", "idle"]) {
  for (const kind of ["stop", "length", "whitespace", "error"]) {
    test(`${entry}: own completed ${kind} without body reaches failure classifier once`, async (suite) => {
      const fixture = await pollFixture();
      suite.after(fixture.dispose);
      const info = kind === "length" ? { finish: "length" } : kind === "error"
        ? { error: { data: { message: "Own API failure" } }, finish: undefined, time: {} } : {};
      const parts = kind === "whitespace" ? [{ type: "text", text: " \n\t " }] : [];
      fixture.setMessages([fixture.prompt, reply(fixture, info, parts)]);
      for (let index = 0; index < 3; index++) await fixture.drive(entry);
      assert.equal(fixture.task.status, "error");
      assert.equal(fixture.effects.wakes.length, 1);
      assert.equal(fixture.effects.releases, 1);
      assert.equal(fixture.manager.pendingByParent.size, 0);
      assert.equal(fixture.manager.completionTimers.size, 1);
      assert.equal(fixture.manager.observedOutputSessions.has("child"), false);
      assert.match(fixture.effects.wakes[0].text, kind === "error" ? /Own API failure/ : kind === "length"
        ? /stopped with length/ : /without a final reply/);
    });
  }
  for (const kind of ["starting", "no finish", "tool-calls", "tool_use", "pending tool", "running tool",
    "summary", "compaction", "new synthetic user", "old parent", "missing boundary", "todo", "team"]) {
    test(`${entry}: ${kind} cannot turn empty progress into terminal output`, async (suite) => {
      const fixture = await pollFixture();
      suite.after(fixture.dispose);
      let info = {};
      let parts = [];
      if (kind === "starting") info = { time: {} };
      if (kind === "no finish") info = { finish: undefined };
      if (kind === "tool-calls" || kind === "tool_use") info = { finish: kind };
      if (kind === "pending tool" || kind === "running tool") parts = [{ type: "tool", state: { status: kind.split(" ")[0] } }];
      if (kind === "summary") info = { summary: true };
      if (kind === "compaction") info = { mode: "compaction" };
      if (kind === "old parent") info = { parentID: "user-1" };
      if (kind === "todo") fixture.manager.client.session.todo = async () => ({ data: [{ status: "pending" }] });
      if (kind === "team") {
        if (entry === "poll") fixture.manager.client.session.status = async () => ({ data: { child: { type: "busy" } } });
        fixture.task.teamRunId = "team";
      }
      const messages = [fixture.prompt, reply(fixture, info, parts)];
      if (kind === "missing boundary") messages.shift();
      if (kind === "new synthetic user") messages.push({ info: { role: "user" }, parts: [{ type: "text", synthetic: true, text: "Memory" }] });
      fixture.setMessages(messages);
      await fixture.drive(entry);
      assert.equal(fixture.task.status, "running");
      assert.equal(fixture.effects.wakes.length, 0);
      assert.equal(fixture.effects.aborts, 0);
      assert.equal(fixture.effects.releases, 0);
      if (!kind.endsWith("tool")) assert.equal(fixture.manager.observedOutputSessions.has("child"), false);
    });
  }
  test(`${entry}: normal final reply completes with exactly one actual notice`, async (suite) => {
    const fixture = await pollFixture();
    suite.after(fixture.dispose);
    fixture.setMessages([fixture.prompt, reply(fixture, {}, final.parts)]);
    for (let index = 0; index < 3; index++) await fixture.drive(entry);
    assert.equal(fixture.task.status, "completed");
    assert.equal(fixture.effects.wakes.length, 1);
    assert.match(fixture.effects.wakes[0].text, /ALL BACKGROUND TASKS COMPLETE/);
    assert.equal(fixture.effects.releases, 1);
    assert.equal(fixture.effects.aborts, 1);
  });
}

for (const changed of ["current", "resume", "session", "attempt", "identity"]) {
  test(`actual idle deferral: ${changed} timer fires only for its owning generation`, async (suite) => {
    const fixture = await pollFixture();
    suite.after(fixture.dispose);
    const clock = fakeIdleTimers();
    fixture.task.startedAt = new Date();
    fixture.idle();
    fixture.idle();
    assert.equal(clock.timers.length, 1, "duplicate early events retain one deferral");
    const timer = clock.timers[0];
    clock.restore();
    fixture.manager.idleDeferralTimers.delete(fixture.task.id);
    if (changed !== "current") await fixture.change(changed);
    fixture.task.startedAt = new Date(Date.now() - 10000);
    fixture.setMessages([fixture.prompt, reply(fixture, {}, final.parts)]);
    const before = pollSnapshot(fixture);
    timer.callback();
    await settle(fixture);
    if (changed === "current") {
      assert.equal(fixture.task.status, "completed");
      assert.equal(fixture.effects.wakes.length, 1);
    } else assert.deepEqual(pollSnapshot(fixture), before);
  });
}

for (const changed of ["resume", "session", "attempt", "identity"]) {
  test(`idle: obsolete ${changed} deferral cannot remove a newer timer`, async (suite) => {
    const fixture = await pollFixture();
    suite.after(fixture.dispose);
    const clock = fakeIdleTimers();
    fixture.task.startedAt = new Date();
    fixture.idle();
    const oldTimer = clock.timers[0];
    clock.restore();
    await fixture.change(changed);
    const newTimer = { generation: "B" };
    fixture.manager.idleDeferralTimers.set(fixture.task.id, newTimer);
    const before = pollSnapshot(fixture);
    oldTimer.callback();
    await settle(fixture);
    assert.deepEqual(pollSnapshot(fixture), before);
    assert.equal(fixture.manager.idleDeferralTimers.get(fixture.task.id), newTimer);
  });
}

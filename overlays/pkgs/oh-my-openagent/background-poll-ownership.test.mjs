import assert from "node:assert/strict";
import { test } from "node:test";
import { pollFixture, pollSnapshot, reply, settle } from "./background-poll.fixture.mjs";

for (const entry of ["poll", "idle"]) {
  for (const phase of ["messages", "todo", "classification"]) {
    for (const changed of ["resume", "session", "attempt", "identity", "cancel"]) {
      test(`${entry}: old ${phase} read cannot mutate ${changed} generation`, async (suite) => {
        const fixture = await pollFixture();
        suite.after(fixture.dispose);
        const { manager, task } = fixture;
        const barrier = fixture.hold(phase === "todo" ? "todo" : "messages",
          phase === "todo" ? { data: [] } : { data: [fixture.prompt, reply(fixture, {}, [{ type: "text", text: "Old A" }])] },
          phase === "classification" ? 2 : 1);
        const operation = fixture.drive(entry);
        await barrier.entered;
        barrier.restore();
        await fixture.change(changed);
        const before = pollSnapshot(fixture);
        barrier.release();
        await operation;
        await settle(fixture);
        assert.deepEqual(pollSnapshot(fixture), before);
        assert.equal(manager.pendingByParent.get("parent")?.has(task.id) ?? false, changed !== "cancel");
      });
    }
  }
}

for (const result of ["missing", "exists"]) {
  for (const phase of ["messages", "get"]) {
    for (const changed of ["resume", "session", "attempt", "identity"]) {
      test(`poll: ${phase} old ${result} existence cannot fail/reset ${changed} B`, async (suite) => {
        const fixture = await pollFixture();
        suite.after(fixture.dispose);
        const { manager, task } = fixture;
        fixture.setMessages([fixture.prompt]);
        manager.client.session.status = async () => ({ data: {} });
        task.consecutiveMissedPolls = 3;
        manager.client.session.get = async () => result === "missing" ? { data: null } : { data: { id: "child" } };
        const barrier = fixture.hold(phase, phase === "messages" ? { data: [fixture.prompt] }
          : result === "missing" ? { data: null } : { data: { id: "child" } });
        const operation = manager.pollRunningTasks();
        await barrier.entered;
        barrier.restore();
        manager.client.session.status = async () => ({ data: { child: { type: "idle" } } });
        await fixture.change(changed);
        const before = pollSnapshot(fixture);
        barrier.release();
        await operation;
        await settle(fixture);
        assert.deepEqual(pollSnapshot(fixture), before);
      });
    }
  }
}

for (const phase of ["status", "fallback"]) {
  test(`poll: ${phase} snapshot cannot act on resumed B`, async (suite) => {
    const fixture = await pollFixture();
    suite.after(fixture.dispose);
    const { manager, task } = fixture;
    manager.client.session.status = async () => ({ data: { child: { type: "retry" } } });
    const barrier = fixture.hold(phase, phase === "status" ? { data: {} } : false);
    const operation = manager.pollRunningTasks();
    await barrier.entered;
    barrier.restore();
    manager.client.session.status = async () => ({ data: { child: { type: "idle" } } });
    await fixture.change("resume");
    const before = pollSnapshot(fixture);
    barrier.release();
    await operation;
    await settle(fixture);
    assert.deepEqual(pollSnapshot(fixture), before);
    assert.equal(task.consecutiveMissedPolls, 7);
  });
}

for (const exists of [false, true]) {
  test(`poll: current ${exists ? "existing" : "missing"} session retains legitimate behavior`, async (suite) => {
    const fixture = await pollFixture();
    suite.after(fixture.dispose);
    fixture.setMessages([fixture.prompt]);
    fixture.manager.client.session.status = async () => ({ data: {} });
    fixture.manager.client.session.get = async () => ({ data: exists ? { id: "child" } : null });
    fixture.task.consecutiveMissedPolls = 3;
    await fixture.drive("poll");
    assert.equal(fixture.task.status, exists ? "running" : "error");
    assert.equal(fixture.effects.wakes.length, exists ? 0 : 1);
    assert.equal(fixture.effects.releases, exists ? 0 : 1);
    assert.equal(fixture.manager.pendingByParent.size, exists ? 1 : 0);
    if (exists) assert.equal(fixture.task.consecutiveMissedPolls, 0);
  });
}

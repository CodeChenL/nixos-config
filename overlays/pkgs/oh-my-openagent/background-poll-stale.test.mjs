import assert from "node:assert/strict";
import { test } from "node:test";
import { pollFixture, pollSnapshot, settle } from "./background-poll.fixture.mjs";

for (const progress of [false, true]) {
  for (const exists of [false, true]) {
    for (const changed of ["resume", "session", "attempt", "identity"]) {
      test(`real stale poll: ${progress ? "progress" : "no progress"} old ${exists ? "exists" : "missing"} read preserves ${changed} B`, async (suite) => {
        const fixture = await pollFixture();
        suite.after(fixture.dispose);
        const { manager, task } = fixture;
        task.startedAt = new Date(Date.now() - 60000);
        task.progress = progress ? { toolCalls: 0, lastUpdate: task.startedAt } : undefined;
        task.consecutiveMissedPolls = 3;
        manager.config.sessionGoneTimeoutMs = 1;
        manager.client.session.status = async () => ({ data: {} });
        const barrier = fixture.hold("get", { data: exists ? { id: "child" } : null });
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

for (const progress of [false, true]) {
  for (const activity of ["missing", "future"]) {
    test(`real stale poll: ${progress ? "progress" : "no progress"} old ${activity} activity cannot write/cancel B`, async (suite) => {
      const fixture = await pollFixture();
      suite.after(fixture.dispose);
      const { manager, task } = fixture;
      task.startedAt = new Date(Date.now() - 60000);
      task.progress = progress ? { toolCalls: 0, lastUpdate: task.startedAt } : undefined;
      manager.config.staleTimeoutMs = 1;
      manager.config.messageStalenessTimeoutMs = 1;
      manager.client.session.status = async () => ({ data: { child: { type: "busy" } } });
      const barrier = fixture.hold("get", { data: activity === "future"
        ? { time: { updated: Date.now() + 60000 } } : { id: "child" } });
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
    });
  }
}

test("outer status snapshot cannot prune a later continuation", async (suite) => {
  const fixture = await pollFixture();
  suite.after(fixture.dispose);
  const { manager, task } = fixture;
  const barrier = fixture.hold("status", { data: {} });
  const operation = manager.pollRunningTasks();
  await barrier.entered;
  barrier.restore();
  await fixture.change("resume");
  manager.config.taskTtlMs = 1;
  task.progress.lastUpdate = new Date(Date.now() - 60000);
  const before = pollSnapshot(fixture);
  barrier.release();
  await operation;
  await settle(fixture);
  assert.deepEqual(pollSnapshot(fixture), before);
});

test("current stale missing session still cancels and sends one actual notice", async (suite) => {
  const fixture = await pollFixture();
  suite.after(fixture.dispose);
  const { manager, task, effects } = fixture;
  task.startedAt = new Date(Date.now() - 60000);
  task.progress.lastUpdate = task.startedAt;
  task.consecutiveMissedPolls = 3;
  manager.config.sessionGoneTimeoutMs = 1;
  manager.client.session.status = async () => ({ data: {} });
  manager.client.session.get = async () => ({ data: null });
  manager.client.session.abort = async () => { effects.aborts++; return {}; };
  await fixture.drive("poll");
  assert.equal(task.status, "cancelled");
  assert.equal(effects.wakes.length, 1);
  assert.equal(effects.releases, 1);
  assert.equal(effects.aborts, 1);
  assert.equal(manager.pendingByParent.size, 0);
});

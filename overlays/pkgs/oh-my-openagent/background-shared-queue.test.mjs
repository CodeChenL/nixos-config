import assert from "node:assert/strict";
import { test } from "node:test";
import { context } from "./background-lifecycle.fixture.mjs";
import { settleLaunch } from "./background-launch.fixture.mjs";
import { assertQueueHealthy, sharedQueueFixture } from "./background-shared-queue.fixture.mjs";

for (const order of [[0, 1], [1, 0]]) {
  for (const existing of [false, true]) {
    test(`shared queue: ${order.join("->")} aborts preserve both tasks with ${existing ? "existing" : "absent"} key`, async (suite) => {
      const fixture = sharedQueueFixture(suite, existing);
      const { manager, tasks, key, aborts, permits, acquired } = fixture;
      await fixture.begin();
      const [first, second] = order;
      aborts[first].resolve(); await settleLaunch();
      assert.deepEqual(acquired, [[key, tasks[first].id]]);
      assert.equal(manager.processingKeys.has(key), true);
      assert.equal(fixture.created.length, 0, "real processor must be blocked on first acquisition");
      const processorQueue = manager.queuesByKey.get(key);
      aborts[second].resolve(); await settleLaunch();
      const queued = manager.queuesByKey.get(key);
      assert.equal(queued.length, 1);
      assert.equal(queued[0].task, tasks[second]);
      assert.equal(queued[0].attemptID, tasks[second].currentAttemptID);
      assert.equal(queued[0].rawConcurrencyKey, key);
      for (const field of ["prompt", "parentMessageId", "cwd", "skillContent", "description"]) {
        assert.equal(queued[0].input[field], tasks[second][field]);
      }
      permits[first].resolve(); await settleLaunch();
      permits[second].resolve(); await fixture.release();
      assert.deepEqual(tasks.map((task) => task.status), ["running", "running"], JSON.stringify(fixture.observe()));
      assertQueueHealthy(fixture);
      assert.deepEqual(acquired, order.map((index) => [key, tasks[index].id]));
      assert.equal(manager.queuesByKey.get(key), processorQueue);
      if (existing) assert.equal(processorQueue, fixture.initialQueue);
    });
  }
  test(`shared queue: obsolete task ${order[1]} abort return leaves the other retry healthy`, async (suite) => {
    const fixture = sharedQueueFixture(suite);
    const { manager, tasks, key, aborts, permits } = fixture;
    await fixture.begin();
    const [healthy, obsolete] = order;
    aborts[healthy].resolve(); await settleLaunch();
    const task = tasks[obsolete];
    assert.ok(context.bindAttemptSession(task, task.currentAttemptID, "newer-owner"));
    task.continuation = { partID: "newer-continuation" };
    task.prompt = "Newer accepted work";
    const snapshot = structuredClone({ ...task, onSessionCreated: undefined });
    aborts[obsolete].resolve(); await settleLaunch();
    assert.equal(manager.queuesByKey.get(key).length, 0);
    permits[healthy].resolve(); await fixture.release();
    assertQueueHealthy(fixture, [healthy]);
    assert.deepEqual(structuredClone({ ...task, onSessionCreated: undefined }), snapshot);
    assert.deepEqual(fixture.acquired, [[key, tasks[healthy].id]]);
  });
}

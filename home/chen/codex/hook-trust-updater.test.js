"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { hookHash, updateConfig, collectStates } = require("./hook-trust-updater.js");

test("hook trust updates once and is idempotent", () => {
  const state = {
    key: "test:one",
    trustedHash: hookHash("SessionStart", null, { type: "command", command: "echo ok", timeout: 600 }, "echo ok"),
  };
  const initial = "toplevel = true\n";
  const updated = updateConfig(initial, [state]);
  assert.match(updated, /trusted_hash = "sha256:/u);
  assert.equal(updateConfig(updated, [state]), updated);
});

test("hook collection shares filtering and event labels", () => {
  const raw = { hooks: { SessionStart: [{ hooks: [
    { type: "command", command: "echo skip", async: true },
    { type: "command", command: "echo ok" },
  ] }] } };
  const states = collectStates(raw, (label, group, handler) => label + ":" + group + ":" + handler,
    (handler) => handler.command.endsWith("ok"));
  assert.deepEqual(states.map((state) => state.key), ["session_start:0:1"]);
});

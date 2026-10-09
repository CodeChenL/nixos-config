import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

const bundle = process.env.MEM_BUNDLE;
assert.equal(typeof bundle, "string", "MEM_BUNDLE must name the built plugin");
const source = String(readFileSync(bundle, "utf8"));
const sessionID = "compacted-fixture";
const directory = "/fixture/project";
const model = { providerID: "session-provider", id: "session-model" };
const fallback = {
  agent: "fallback-agent",
  model: { providerID: "fallback-provider", modelID: "fallback-model" },
  variant: "xhigh",
};
const agentMessages = [{ info: { role: "user", ...fallback } }];
const session = { agent: "session-agent", model: { ...model, variant: "default" } };
const memories = [{ memory: "Keep the selected model and variant", tags: [] }];
const functions = [
  "unwrapSdkData", "resolveSessionAgent", "resolveSessionModel",
  "normalizeTagsKey", "stripMatchingEmbeddedTagsFooter", "formatMemoriesForCompaction",
].map((name) => {
  const match = new RegExp(`^(?:export )?(?:async )?function ${name}\\(`, "m").exec(source);
  assert.ok(match, `missing bundled function ${name}`);
  const end = source.indexOf("\n}", match.index);
  assert.ok(end > match.index, `missing closing brace for ${name}`);
  return source.slice(match.index, end + 2).replace(/^export /, "");
}).join("\n");
const eventStart = source.indexOf("        event: async (input) => {");
assert.ok(eventStart >= 0, "missing bundled event hook");
const eventEnd = source.indexOf("\n        },\n    };\n};", eventStart);
assert.ok(eventEnd > eventStart, "missing end of bundled event hook");
const eventHook = `({${source.slice(eventStart, eventEnd + "\n        },".length)}}).event`;

function fixture(current = session, options = {}) {
  const effects = { requests: [], logs: [], searches: [], reads: [], messages: [], toasts: [] };
  const client = { tui: {
    showToast: async (input) => { effects.toasts.push(structuredClone(input)); },
  }, session: {
    get: async (input) => {
      effects.reads.push(structuredClone(input));
      if (options.getError) throw options.getError;
      return options.rawResponse ? current : { data: current };
    },
    messages: async (input) => {
      effects.messages.push(structuredClone(input));
      return { data: options.messages ?? [] };
    },
    prompt: async (input) => { effects.requests.push(structuredClone(input)); },
  } };
  if (options.noGet) delete client.session.get;
  const context = vm.createContext({
    ctx: { client }, directory,
    Date: { now: () => 123 },
    CONFIG: { compaction: { enabled: options.enabled ?? true, memoryLimit: 7 } },
    isConfigured: () => options.configured ?? true,
    getTags: (path) => {
      assert.equal(path, directory);
      return { project: { tag: "fixture-project" } };
    },
    memoryClient: {
      searchMemoriesBySessionID: async (...args) => {
        effects.searches.push(args);
        return options.memoriesResult ?? { success: true, results: memories };
      },
    },
    log: (...args) => effects.logs.push(structuredClone(args)),
  });
  vm.runInContext(`${functions}\nconst EMBEDDED_TAGS_FOOTER_RE = /\\n*Tags: ([^\\n]*)\\s*$/;`, context);
  const event = vm.runInContext(eventHook, context);
  return {
    effects,
    compact: (properties = { sessionID }, type = "session.compacted") => event({ event: { type, properties } }),
  };
}

function injectedBody(effects, agent = session.agent) {
  assert.equal(effects.requests.length, 1);
  const { path, body } = effects.requests[0];
  assert.deepEqual(path, { id: sessionID });
  assert.equal(body.agent, agent);
  assert.equal(body.noReply, true);
  assert.equal(body.parts.length, 1);
  assert.equal(body.parts[0].id, "prt-compaction-123");
  assert.equal(body.parts[0].type, "text");
  assert.equal(body.parts[0].synthetic, true);
  assert.equal(typeof body.parts[0].text, "string");
  assert.ok(body.parts[0].text.trim().length > 0);
  assert.deepEqual(effects.searches, [[sessionID, "fixture-project", 7]]);
  assert.equal(effects.toasts.length, 1);
  assert.equal(effects.toasts[0].body.variant, "success");
  return body;
}

// 上游（PR #326）在模型无法解析时"behaves as before"：仍按 agent 注入但绝不带 model/variant，
// 保证 fallback agent 的模型永远不会顶掉会话模型。
function injectedWithoutModel(effects, agent = fallback.agent) {
  assert.equal(effects.requests.length, 1, "model-less injection still happens (upstream keeps pre-patch behaviour)");
  const { path, body } = effects.requests[0];
  assert.deepEqual(path, { id: sessionID });
  assert.equal(body.agent, agent);
  assert.equal(Object.hasOwn(body, "model"), false, "an unresolved model must never inject the agent's fallback model");
  assert.equal(Object.hasOwn(body, "variant"), false);
  assert.equal(body.noReply, true);
  assert.equal(body.parts.length, 1);
  assert.equal(body.parts[0].id, "prt-compaction-123");
  assert.equal(body.parts[0].type, "text");
  assert.equal(body.parts[0].synthetic, true);
  assert.equal(typeof body.parts[0].text, "string");
  assert.ok(body.parts[0].text.trim().length > 0);
  assert.deepEqual(effects.searches, [[sessionID, "fixture-project", 7]]);
  assert.equal(effects.toasts.length, 1);
  assert.equal(effects.toasts[0].body.variant, "success");
  assert.ok(effects.logs.some(([message, data]) =>
    message === "Compaction memory injected" &&
    data.sessionID === sessionID && data.model === null));
  assert.equal(effects.logs.some(([message]) => message === "Compaction handler error"), false);
}

for (const rawResponse of [false, true]) {
  test(`compaction preserves the session model in the injection request (${rawResponse ? "raw" : "SDK data"})`, async () => {
    const { compact, effects } = fixture(session, { rawResponse });
    await compact();
    const body = injectedBody(effects);
    assert.deepEqual(body.model, { providerID: model.providerID, modelID: model.id });
    assert.notDeepEqual(body.model, fallback.model);
    // 上游（PR #326）按 OpenCode 自身的归一化省略 "default" variant，省略即默认 variant。
    assert.equal(Object.hasOwn(body, "variant"), false);
    assert.notEqual(body.agent, fallback.agent);
    assert.deepEqual(effects.reads, [{ path: { id: sessionID } }, { path: { id: sessionID } }]);
    assert.ok(effects.logs.some(([message]) => message === "Compaction memory injected"));
  });
}

test("compaction keeps a non-default variant", async () => {
  const { compact, effects } = fixture({ ...session, model: { ...model, variant: "medium" } });
  await compact();
  const body = injectedBody(effects);
  assert.deepEqual(body.model, { providerID: model.providerID, modelID: model.id });
  assert.equal(body.variant, "medium");
});

for (const variant of [undefined, "", null, 0, false, {}, []]) {
  test(`compaction omits missing, empty or invalid variant ${JSON.stringify(variant)}`, async () => {
    const currentModel = variant === undefined ? model : { ...model, variant };
    const { compact, effects } = fixture({ ...session, model: currentModel });
    await compact();
    const body = injectedBody(effects);
    assert.deepEqual(body.model, { providerID: model.providerID, modelID: model.id });
    assert.equal(Object.hasOwn(body, "variant"), false);
  });
}

for (const invalidModel of [
  undefined, null, {}, { providerID: model.providerID, modelID: model.id },
  { providerID: 42, id: model.id }, { providerID: model.providerID, id: false },
]) {
  test(`compaction omits an unresolved model ${JSON.stringify(invalidModel)} despite a message agent`, async () => {
    const { compact, effects } = fixture({ model: invalidModel }, { messages: agentMessages });
    await compact();
    injectedWithoutModel(effects);
    assert.deepEqual(effects.messages, [{ path: { id: sessionID } }]);
    assert.deepEqual(effects.reads, [{ path: { id: sessionID } }, { path: { id: sessionID } }]);
  });
}

// 上游 resolveSessionModel 只校验 typeof 为 string，空/空白 providerID 与 id 视为已解析并原样透传。
for (const oddModel of [
  { providerID: "", id: model.id }, { providerID: model.providerID, id: "" },
  { providerID: " \t", id: model.id }, { providerID: model.providerID, id: " \t" },
]) {
  test(`compaction passes the session model through verbatim for ${JSON.stringify(oddModel)}`, async () => {
    const { compact, effects } = fixture({ model: oddModel }, { messages: agentMessages });
    await compact();
    const body = injectedBody(effects, fallback.agent);
    assert.deepEqual(body.model, { providerID: oddModel.providerID, modelID: oddModel.id });
    assert.equal(Object.hasOwn(body, "variant"), false);
  });
}

test("session.get failure falls back to a model-less injection and logs the resolver error", async () => {
  const { compact, effects } = fixture(session, {
    getError: new Error("fixture read failed"),
    messages: agentMessages,
  });
  await compact();
  injectedWithoutModel(effects);
  assert.deepEqual(effects.messages, [{ path: { id: sessionID } }]);
  assert.deepEqual(effects.reads, [{ path: { id: sessionID } }, { path: { id: sessionID } }]);
  assert.ok(effects.logs.some(([message, data]) =>
    message === "resolveSessionModel: session.get failed" &&
    data.sessionID === sessionID && data.error === "Error: fixture read failed"));
});

test("unavailable session.get falls back to a model-less injection", async () => {
  const { compact, effects } = fixture(session, {
    noGet: true, messages: agentMessages,
  });
  await compact();
  injectedWithoutModel(effects);
  assert.deepEqual(effects.reads, []);
  assert.deepEqual(effects.messages, [{ path: { id: sessionID } }]);
});

test("SDK error-only response falls back to a model-less injection", async () => {
  const { compact, effects } = fixture(
    { error: { name: "SessionReadError", message: "fixture SDK read failed" } },
    { rawResponse: true, messages: agentMessages },
  );
  await compact();
  injectedWithoutModel(effects);
  assert.deepEqual(effects.reads, [{ path: { id: sessionID } }, { path: { id: sessionID } }]);
});

test("SDK error with data still resolves the model from the data payload", async () => {
  const { compact, effects } = fixture(
    { data: session, error: { name: "SessionReadError", message: "fixture SDK read failed" } },
    { rawResponse: true, messages: agentMessages },
  );
  await compact();
  const body = injectedBody(effects);
  assert.deepEqual(body.model, { providerID: model.providerID, modelID: model.id });
  assert.equal(Object.hasOwn(body, "variant"), false);
  assert.deepEqual(effects.reads, [{ path: { id: sessionID } }, { path: { id: sessionID } }]);
});

test("unresolved session agent skips injection rather than selecting the fallback agent", async () => {
  const { compact, effects } = fixture({ model: session.model });
  await compact();
  assert.deepEqual(effects.requests, []);
  assert.deepEqual(effects.toasts, []);
  assert.ok(effects.logs.some(([message]) =>
    message === "Compaction: skipped memory injection because session agent could not be resolved"));
});

test("non-compaction events and compaction guards do not inject memory", async () => {
  for (const options of [
    { configured: false }, { enabled: false },
    { memoriesResult: { success: true, results: [] } },
    { memoriesResult: { success: false, results: memories } },
  ]) {
    const { compact, effects } = fixture(session, options);
    await compact();
    assert.deepEqual(effects.requests, []);
    assert.deepEqual(effects.toasts, []);
    assert.deepEqual(effects.reads, []);
  }
  const { compact, effects } = fixture();
  await compact({});
  await compact({ sessionID }, "message.updated");
  assert.deepEqual(effects.requests, []);
  assert.deepEqual(effects.toasts, []);
  assert.deepEqual(effects.searches, []);
});

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const moduleRoot = path.resolve(__dirname, "..");
const helperPath = path.join(moduleRoot, "api-key-ultra-gates.js");
const unlockPath = path.join(moduleRoot, "unlock-api-key-ultra.js");
const customPath = path.join(moduleRoot, "patch-desktop-app.js");

const fixture = `
"use strict";
const AN = () => true;
function catalog(a,t,s,r,i){
  const f=a&&s.some(e=>e.supportedReasoningEfforts.some(({reasoningEffort:e})=>e===\`ultra\`));
  let e=a?r.supportedReasoningEfforts:r.supportedReasoningEfforts.filter(({reasoningEffort:e})=>e!==\`ultra\`);
  const n=e.filter(({reasoningEffort:e})=>AN(e)&&i.has(e));
  return {hasUltra:f,efforts:n.map(({reasoningEffort})=>reasoningEffort)};
}
function ygc(F,{includeUltraInSlider}){
  const candidates=includeUltraInSlider?[\`low\`,\`medium\`,\`high\`,\`xhigh\`,\`ultra\`]:[\`low\`,\`medium\`,\`high\`,\`xhigh\`];
  const supported=new Set(F[0]?.supportedReasoningEfforts.map(({reasoningEffort})=>reasoningEffort)??[]);
  return candidates.filter(e=>supported.has(e));
}
function slider(u,m,F){return ygc(F,{includeUltraInSlider:u})}
module.exports={catalog,slider};
`;

function loadFixture(source) {
  const module = { exports: {} };
  Function("module", "exports", source)(module, module.exports);
  return module.exports;
}

function model(efforts) {
  return {
    model: "gpt-5.6-sol",
    supportedReasoningEfforts: efforts.map((reasoningEffort) => ({ reasoningEffort })),
  };
}

test("production patches do not invent provider efforts", () => {
  const sources = [fs.readFileSync(unlockPath, "utf8"), fs.readFileSync(customPath, "utf8")];
  for (const source of sources) {
    assert.doesNotMatch(source, /Ultra reasoning depth/u);
    assert.doesNotMatch(source, /codexLinuxApiKeyUltraEnabledEffortFilter/u);
    assert.match(source, /CODEX_API_KEY_ULTRA_GATES/u);
  }
  assert.doesNotMatch(sources[1], /\[`low`,`medium`,`high`,`xhigh`,`max`,`ultra`\]/u);
});

test("API-key Efforts follow the OAuth entitlement, catalog, and enabled-set path", () => {
  const { applyApiKeyUltraGates } = require(helperPath);
  const patched = applyApiKeyUltraGates(fixture, "efforts-fixture.js");
  const runtime = loadFixture(patched);

  for (const scenario of [
    { name: "declared", advertised: ["low", "medium", "high", "xhigh", "max", "ultra"], enabled: ["low", "medium", "high", "xhigh", "max", "ultra"] },
    { name: "missing", advertised: ["low", "medium", "high", "xhigh", "max"], enabled: ["low", "medium", "high", "xhigh", "max", "ultra"] },
    { name: "disabled", advertised: ["low", "medium", "high", "xhigh", "max", "ultra"], enabled: ["low", "medium", "high", "xhigh", "max"] },
  ]) {
    const providerModel = model(scenario.advertised);
    const enabled = new Set(scenario.enabled);
    const oauthCatalog = runtime.catalog(true, "chatgpt", [providerModel], providerModel, enabled);
    const apiKeyCatalog = runtime.catalog(false, "apikey", [providerModel], providerModel, enabled);
    assert.deepEqual(apiKeyCatalog, oauthCatalog, `${scenario.name}: catalog differs`);

    const oauthModels = [model(oauthCatalog.efforts)];
    const apiKeyModels = [model(apiKeyCatalog.efforts)];
    assert.deepEqual(
      runtime.slider(false, { authMethod: "apikey" }, apiKeyModels),
      runtime.slider(true, { authMethod: "chatgpt" }, oauthModels),
      `${scenario.name}: compact slider differs`,
    );
  }

  assert.equal(applyApiKeyUltraGates(patched, "efforts-fixture.js"), patched);
});

test("Ultra gate anchors remain fail-closed", () => {
  const { applyApiKeyUltraGates } = require(helperPath);
  assert.throws(
    () => applyApiKeyUltraGates(fixture.replace("f=a&&", "f=false&&"), "missing-anchor.js"),
    /Expected one codexLinuxApiKeyUltraCatalogFlag anchor/u,
  );
  assert.throws(
    () => applyApiKeyUltraGates(`${fixture}\n${fixture}`, "duplicate-anchor.js"),
    /Expected one codexLinuxApiKeyUltraCatalogFlag anchor/u,
  );
});

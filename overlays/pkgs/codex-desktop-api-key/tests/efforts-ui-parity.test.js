"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const os = require("node:os");
const { spawnSync } = require("node:child_process");
const { applyApiKeyUltraGates, applyApiKeyUltraAssets } = require("../api-key-ultra-gates.js");

const moduleRoot = path.resolve(__dirname, "..");
const helperPath = path.join(moduleRoot, "api-key-ultra-gates.js");
const unlockPath = path.join(moduleRoot, "unlock-api-key-ultra.js");

const fixture = `
"use strict";
const AN = () => true;
function catalog(o,t,c,r,i,s){
  const p=o&&c.some(e=>e.supportedReasoningEfforts.some(({reasoningEffort:e})=>e===\`ultra\`));
  let e=o?r.supportedReasoningEfforts:r.supportedReasoningEfforts.filter(({reasoningEffort:e})=>e!==\`ultra\`);
  const n=e.filter(({reasoningEffort:e})=>AN(e)&&i.has(e));
  return {hasUltra:p,efforts:n.map(({reasoningEffort})=>reasoningEffort)};
}
function _Ho(Ee,{includeUltraInSlider}){
  const candidates=includeUltraInSlider?[\`low\`,\`medium\`,\`high\`,\`xhigh\`,\`ultra\`]:[\`low\`,\`medium\`,\`high\`,\`xhigh\`];
  const supported=new Set(Ee[0]?.supportedReasoningEfforts.map(({reasoningEffort})=>reasoningEffort)??[]);
  return candidates.filter(e=>supported.has(e));
}
function featureGate(i,t,a){const rS=false,l=value=>value;let m=i&&l(rS,\`1186680773\`);return m}
function providerGate(s,r){const tS=value=>value;return {includeUltraReasoningEffort:tS(r,\`1186680773\`)}}
function slider(f,_,Ee){return _Ho(Ee,{includeUltraInSlider:f})}
function fastGate(u=false,a=true,c={requirements:{featureRequirements:{fast_mode:true}}},o=\`chatgpt\`){let d=!u&&(a?c!=null&&c?.requirements?.featureRequirements?.fast_mode!==!1:o===\`apikey\`);return d}
function fastModel(t,s){return {codexLinuxApiKeyServiceTierModel:t===\`apikey\`}}
module.exports={catalog,slider,fastGate,fastModel,featureGate,providerGate};
`;

function loadFixture(source) {
  const module = { exports: {} };
  Function("module", "exports", source)(module, module.exports);
  return module.exports;
}

function runtimeCatalog(patched, o, t, model, enabled) {
  return loadFixture(patched).catalog(o, t, [model], model, enabled, false);
}

function runtimeSlider(patched, includeUltra, authMethod, models) {
  return loadFixture(patched).slider(includeUltra, authMethod, models);
}

function model(efforts) {
  return {
    model: "gpt-5.6-sol",
    supportedReasoningEfforts: efforts.map((reasoningEffort) => ({ reasoningEffort })),
  };
}

test("production patches do not invent provider efforts", () => {
  const source = fs.readFileSync(unlockPath, "utf8");
  assert.doesNotMatch(source, /Ultra reasoning depth/u);
  assert.doesNotMatch(source, /codexLinuxApiKeyUltraEnabledEffortFilter/u);
  assert.match(source, /CODEX_API_KEY_ULTRA_GATES/u);
});

test("API-key Efforts follow the OAuth entitlement, catalog, and enabled-set path", () => {
  const { applyApiKeyUltraGates } = require(helperPath);
  const patched = applyApiKeyUltraGates(fixture, "efforts-fixture.js");
  const runtime = loadFixture(patched.source);
  assert.equal(runtime.fastGate(), true);
  for (const auth of ["chatgpt", "apikey", "copilot", null]) {
    for (const custom of [false, true]) {
      for (const entitled of [false, true]) {
        assert.equal(runtime.featureGate(entitled, auth, custom), entitled || auth === "apikey" || custom);
        assert.equal(runtime.providerGate({authMethod: auth}, entitled).includeUltraReasoningEffort, auth === "apikey" || entitled);
        assert.equal(runtime.fastModel(auth, custom).codexLinuxApiKeyServiceTierModel, auth === "apikey" || custom);
        const providerModel = model(["high", "ultra"]);
        const actual = runtime.catalog(entitled, auth, [providerModel], providerModel, new Set(["high", "ultra"]), custom);
        assert.equal(actual.hasUltra, entitled || auth === "apikey" || custom);
        assert.deepEqual(actual.efforts, entitled || auth === "apikey" || custom ? ["high", "ultra"] : ["high"]);
      }
    }
    for (const loading of [false, true]) {
      assert.equal(runtime.fastGate(loading, auth === "chatgpt", null, auth), !loading);
    }
  }

  for (const scenario of [
    { name: "declared", advertised: ["low", "medium", "high", "xhigh", "max", "ultra"], enabled: ["low", "medium", "high", "xhigh", "max", "ultra"] },
    { name: "missing", advertised: ["low", "medium", "high", "xhigh", "max"], enabled: ["low", "medium", "high", "xhigh", "max", "ultra"] },
    { name: "disabled", advertised: ["low", "medium", "high", "xhigh", "max", "ultra"], enabled: ["low", "medium", "high", "xhigh", "max"] },
  ]) {
    const providerModel = model(scenario.advertised);
    const enabled = new Set(scenario.enabled);
    const oauthCatalog = runtimeCatalog(patched.source, true, "chatgpt", providerModel, enabled);
    const apiKeyCatalog = runtimeCatalog(patched.source, false, "apikey", providerModel, enabled);
    assert.deepEqual(apiKeyCatalog, oauthCatalog, `${scenario.name}: catalog differs`);

    const oauthModels = [model(oauthCatalog.efforts)];
    const apiKeyModels = [model(apiKeyCatalog.efforts)];
    assert.deepEqual(
      runtimeSlider(patched.source, false, "apikey", apiKeyModels),
      runtimeSlider(patched.source, true, "chatgpt", oauthModels),
      `${scenario.name}: compact slider differs`,
    );
  }

  const reapplied = applyApiKeyUltraGates(patched.source, "efforts-fixture.js");
  assert.equal(reapplied.source, patched.source);
  assert.deepEqual(reapplied.patches, []);
});

test("required gates fail closed on missing, duplicate, or damaged postconditions", () => {
  assert.throws(() => applyApiKeyUltraGates("function modelPicker(){return []}", "unknown.js"), /Expected|Required/);
  assert.throws(() => applyApiKeyUltraGates(fixture + fixture), /Expected|Required/);
  const patched = applyApiKeyUltraGates(fixture);
  assert.equal(patched.validated.length, 7);
  for (const marker of patched.validated) {
    assert.throws(() => applyApiKeyUltraGates(patched.source.replace(`/*${marker}*/`, `&&false/*${marker}*/`)), /Expected|Required/, marker);
    assert.throws(() => applyApiKeyUltraGates(`/*${marker}*/` + fixture), /Expected|Required/, marker);
  }
  assert.throws(() => applyApiKeyUltraGates(fixture.replace("p=o&&", "p=false&&")), /Expected|Required/);
});

function continuedGates(source) {
  const corruptions = [];
  for (const {0: marker} of source.matchAll(/\/\*codexLinuxApiKey\w+\*\//g)) {
    for (const suffix of ["&&false", "||false", "?false:true", "===false", ".missing", "[0]", "(false)", " /*continued*/ &&false"]) {
      corruptions.push({name: marker + suffix, source: source.replace(marker, marker + suffix)});
    }
  }
  for (const [needle, replacement] of [
    ["let m=(", "let xm=("],
    ["let d=!", "let xd=!"],
    ["const p=(", "const xp=("],
    ["let m=(", "let holder={};holder.m=("],
    ["includeUltraReasoningEffort:s.authMethod", "notincludeUltraReasoningEffort:s.authMethod"],
    ["codexLinuxApiKeyServiceTierModel:t===", "notcodexLinuxApiKeyServiceTierModel:t==="],
    ["return _Ho(", "return false&&_Ho("],
    ["/*codexLinuxApiKeyUltraSlider*/})", "/*codexLinuxApiKeyUltraSlider*/})&&false"],
  ]) {
    assert.ok(source.includes(needle), needle);
    corruptions.push({name: replacement, source: source.replace(needle, replacement)});
  }
  return corruptions;
}

test("complete gate expressions reject suffix operators and misleading prefixes", () => {
  const patched = applyApiKeyUltraGates(fixture).source;
  for (const corruption of continuedGates(patched)) {
    assert.doesNotThrow(() => loadFixture(corruption.source), corruption.name);
    assert.throws(() => applyApiKeyUltraGates(corruption.source), /Required/, corruption.name);
  }
});

test("CLI rejects continued gates without writing assets, maps, or a success report", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codex-ultra-test-"));
  const assets = path.join(root, "webview", "assets");
  fs.mkdirSync(assets, {recursive:true});
  const asset = path.join(assets, "app-initial-fixture.js");
  try {
    for (const corruption of continuedGates(applyApiKeyUltraGates(fixture).source)) {
      fs.writeFileSync(asset, corruption.source);
      const result = spawnSync(process.execPath, [unlockPath, root], {encoding:"utf8", env:{PATH:process.env.PATH}});
      assert.notEqual(result.status, 0, corruption.name);
      assert.match(result.stderr, /Required/, corruption.name);
      assert.equal(fs.readFileSync(asset, "utf8"), corruption.source);
      assert.deepEqual(fs.readdirSync(assets), [path.basename(asset)]);
      assert.equal(fs.existsSync(path.join(root, ".codex-linux")), false);
    }
  } finally {
    fs.rmSync(root, {recursive:true, force:true});
  }
});

test("renamed helper anchors and split current slider gates validate and execute", () => {
  const initial = fixture.replace("l(rS,", "l(scope,").replace("rS=false", "scope=false")
    .replaceAll("tS", "checkFeature")
    .replace("_Ho(Ee,{includeUltraInSlider:f})", "_Ho(Ee,{sliderModelsConfig:_,includeUltraInSlider:f.data.ultraEffortEnabled===!0})");
  const primary = "function compact(models,enabled,config,strip){return build(models,{includeUltraInSlider:enabled,sliderModelsConfig:config,stripGptPrefix:!strip})}";
  const patched = applyApiKeyUltraAssets([{asset: "app-initial-fixture.js", source: initial}, {asset: "app-primary-fixture.js", source: primary}]);
  assert.equal(patched.flatMap(entry => entry.validated).length, 8);
  assert.deepEqual(loadFixture(patched[0].source).slider({data:{ultraEffortEnabled:false}}, null, [model(["ultra"])]), ["ultra"]);
  const compact = Function("build", patched[1].source + ";return compact")((_models, options) => options);
  assert.equal(compact([], false, null, false).includeUltraInSlider, true);
  assert.deepEqual(applyApiKeyUltraAssets(patched).map(entry => entry.source), patched.map(entry => entry.source));
  for (const entry of patched) {
    for (const marker of entry.validated) {
      const corrupted = patched.map(candidate => candidate === entry
        ? {...entry, source: entry.source.replace(`/*${marker}*/`, `/*${marker}*/&&false`)} : candidate);
      assert.throws(() => applyApiKeyUltraAssets(corrupted), /Required/, marker);
    }
    for (const continuation of ["&&false", ".missing", "[0]", "(false)"]) {
      const corrupted = patched.map(candidate => candidate === entry
        ? {...entry, source: entry.source.replace(/(\/\*codexLinuxApiKeyUltraSlider(?:Selection)?\*\/[^{}]*\}\))/, "$1" + continuation)} : candidate);
      assert.throws(() => applyApiKeyUltraAssets(corrupted), /Required/, continuation);
    }
  }
  assert.throws(() => applyApiKeyUltraAssets([patched[0]]), /Expected|Required/);
  assert.throws(() => applyApiKeyUltraAssets([patched[1]]), /Expected|Required/);
});

test("package CLI validates before writing and accepts a valid zero-patch rerun", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codex-ultra-test-"));
  const assets = path.join(root, "webview", "assets");
  fs.mkdirSync(assets, {recursive:true});
  const run = () => spawnSync(process.execPath, [unlockPath, root], {encoding:"utf8", env:{PATH:process.env.PATH}});
  try {
    assert.notEqual(run().status, 0);
    const asset = path.join(assets, "app-initial-fixture.js");
    fs.writeFileSync(asset, "function unknown(){}");
    assert.notEqual(run().status, 0);
    assert.equal(fs.existsSync(path.join(root, ".codex-linux")), false);
    fs.writeFileSync(asset, fixture);
    fs.writeFileSync(path.join(assets, "app-initial-duplicate.js"), fixture);
    assert.notEqual(run().status, 0);
    assert.equal(fs.readFileSync(asset, "utf8"), fixture);
    fs.unlinkSync(path.join(assets, "app-initial-duplicate.js"));
    assert.equal(run().status, 0);
    const first = fs.readFileSync(asset, "utf8");
    assert.equal(run().status, 0);
    assert.equal(fs.readFileSync(asset, "utf8"), first);
    const report = JSON.parse(fs.readFileSync(path.join(root, ".codex-linux", "api-key-ultra-patch.json")));
    assert.deepEqual(report.patches, []);
    assert.equal(report.validated.length, 7);
  } finally {
    fs.rmSync(root, {recursive:true, force:true});
  }
});

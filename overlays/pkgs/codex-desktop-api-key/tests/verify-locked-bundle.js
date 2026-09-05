"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const [archive, upstream, asarModule] = process.argv.slice(2);
if (!archive || !upstream || !asarModule) {
  throw new Error("Usage: node verify-locked-bundle.js APP_ASAR LOCKED_UPSTREAM ASAR_MODULE");
}
const asar = require(path.resolve(asarModule));
const version = JSON.parse(asar.extractFile(archive, "package.json").toString()).version;
const lockedVersion = JSON.parse(fs.readFileSync(path.join(upstream, "nix/upstream-linux-packages.json"), "utf8")).version;
assert.equal(version, lockedVersion);
const { applyApiKeyServiceTierPatch } = require(path.join(upstream, "linux-features/api-key-service-tier/patch.js"));
const { applyApiKeyModelVisibilityPatch } = require(path.join(upstream, "linux-features/api-key-model-visibility/patch.js"));
const { applyApiKeyUltraAssets } = require("../api-key-ultra-gates.js");
const root = fs.mkdtempSync(path.join(os.tmpdir(), "codex-ultra-locked-"));
const assetsDir = path.join(root, "webview", "assets");
const unlock = path.resolve(__dirname, "../unlock-api-key-ultra.js");
const run = () => spawnSync(process.execPath, [unlock, root], {encoding:"utf8", env:{PATH:process.env.PATH}});

function declaration(source, prefix) {
  const start = source.search(prefix);
  assert.notEqual(start, -1, `Missing function ${prefix}`);
  const end = source.indexOf("function ", start + "function ".length);
  const candidate = source.slice(start, end < 0 ? undefined : end);
  const closing = candidate.indexOf("}var ");
  return closing < 0 ? candidate : candidate.slice(0, closing + 1);
}

function evaluate(expression, bindings) {
  return Function(...Object.keys(bindings), `"use strict";return (${expression})`)(...Object.values(bindings));
}

try {
  fs.mkdirSync(assetsDir, {recursive:true});
  const names = asar.listPackage(archive).filter(name => /\/webview\/assets\/app-(?:initial|primary)-[^.]+\.js$/.test(name));
  assert.equal(names.length, 2);
  const inputs = names.map(name => {
    const original = asar.extractFile(archive, name.replace(/^\//, "")).toString();
    const source = applyApiKeyServiceTierPatch(applyApiKeyModelVisibilityPatch(original));
    const asset = path.basename(name);
    fs.writeFileSync(path.join(assetsDir, asset), source);
    return {asset, source};
  });
  const first = run();
  assert.equal(first.status, 0, first.stderr);
  const outputs = inputs.map(({asset}) => ({asset, source:fs.readFileSync(path.join(assetsDir, asset), "utf8")}));
  for (const entry of outputs) {
    const syntax = spawnSync(process.execPath, ["--check", "--input-type=module"], {input:entry.source, encoding:"utf8", maxBuffer:2 ** 20});
    assert.equal(syntax.status, 0, syntax.stderr.slice(-4000));
  }
  const reportPath = path.join(root, ".codex-linux", "api-key-ultra-patch.json");
  const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
  assert.equal(report.patches.length, 8);
  assert.equal(report.validated.length, 8);
  assert.equal(run().status, 0);
  assert.deepEqual(JSON.parse(fs.readFileSync(reportPath, "utf8")).patches, []);
  for (const entry of outputs) assert.equal(fs.readFileSync(path.join(assetsDir, entry.asset), "utf8"), entry.source);
  const initial = outputs.find(entry => entry.asset.startsWith("app-initial-")).source;
  const catalogSource = declaration(initial, /function [\w$]+\(\{additionalAvailableModels:e,authMethod:t,availableModels:n,defaultModel:/);
  const visibilityName = catalogSource.match(/if\(([\w$]+)\(\{additionalAvailableModels:/)[1];
  const visibilitySource = declaration(initial, new RegExp(`function ${visibilityName}\\(`));
  const effortPredicate = catalogSource.match(/=>(([\w$]+)\(e\)&&i\.has\(e\))/)[2];
  const catalogName = catalogSource.match(/function ([\w$]+)/)[1];
  const catalog = Function(effortPredicate, `${visibilitySource}${catalogSource};return ${catalogName}`)(() => true);
  const callback = initial.match(/\(\{additionalAvailableModels:e,authMethod:t,hasConfiguredModelCatalog:n,hostId:r,includeUltraReasoningEffort:i,isCustomModelProvider:a,limit:o,modelCatalogPath:s,modelProvider:c\},\{get:l,queryClient:u,scope:d\}\)=>\{let f=[\s\S]+?useHiddenModels:p\.useHiddenModels\}\)\}\}/)?.[0];
  assert.ok(callback, "Missing actual query callback scope");
  const dependencies = callback.match(/let f=l\(([\w$]+)\),p=l\(([\w$]+)\)/);
  const queryKey = callback.match(/queryKey:\[\.\.\.([\w$]+)\(/)[1];
  const hosts = callback.match(/enabled:l\(([\w$]+)\)/)[1];
  const staleTime = callback.match(/staleTime:([\w$]+)\.FIVE_MINUTES/)[1];
  const query = evaluate(callback, {[catalogName]:catalog, [dependencies[1]]:"efforts", [dependencies[2]]:"models", [queryKey]:() => [], [hosts]:"hosts", [staleTime]:{FIVE_MINUTES:300000}});
  let cases = 0;
  for (const authMethod of ["chatgpt", "apikey", "copilot", null]) {
    for (const custom of [false, true]) {
      for (const entitled of [false, true]) {
        for (const advertised of [false, true]) {
          for (const enabled of [false, true]) {
            const efforts = new Set(["medium", ...(enabled ? ["ultra"] : [])]);
            const model = {model:"test", hidden:false, isDefault:true, supportedReasoningEfforts:[{reasoningEffort:"medium"}, ...(advertised ? [{reasoningEffort:"ultra"}] : [])]};
            const modelConfig = {availableModels:new Set(["test"]), defaultModel:"test", useHiddenModels:false};
            const result = query({additionalAvailableModels:[], authMethod, hostId:"offline", includeUltraReasoningEffort:entitled, isCustomModelProvider:custom, limit:100, modelCatalogPath:null}, {get:key => ({efforts, models:modelConfig, hosts:["offline"]})[key], queryClient:{}, scope:{}}).select({data:[model]});
            const allowed = entitled || authMethod === "apikey" || custom;
            assert.equal(result.hasModelSupportingUltraReasoningEffort, allowed && advertised);
            assert.equal(result.models[0].supportedReasoningEfforts.some(entry => entry.reasoningEffort === "ultra"), authMethod !== "copilot" && allowed && advertised && enabled);
            assert.equal(result.models[0].codexLinuxApiKeyServiceTierModel, authMethod === "apikey" || custom);
            cases++;
          }
        }
      }
    }
  }
  const provider = initial.match(/includeUltraReasoningEffort:(s\.authMethod===`apikey`\|\|([\w$]+)\(r,`1186680773`\))\/\*codexLinuxApiKeyUltraProviderGate\*\//);
  assert.ok(provider);
  for (const authMethod of ["chatgpt", "apikey", null]) {
    for (const flag of [false, true]) assert.equal(evaluate(provider[1], {s:{authMethod}, r:{}, [provider[2]]:() => flag}), authMethod === "apikey" || flag);
  }
  for (const entry of outputs) {
    const call = entry.source.match(/([\w$]+)\(([\w$]+(?:\?\.models)?),\{([^{}]*includeUltraInSlider:!0\/\*codexLinuxApiKeyUltraSlider(?:Selection)?\*\/[^{}]*)\}\)/);
    assert.ok(call);
    const bindings = Object.fromEntries([...`${call[2]},${call[3]}`.matchAll(/\b[A-Za-z_$][\w$]*\b/g)].map(match => [match[0], false]));
    bindings[call[1]] = (_models, options) => options;
    assert.equal(evaluate(call[0], bindings).includeUltraInSlider, true);
  }
  const fastFunction = declaration(initial, /function [\w$]+\(e\)\{let t=\(0,[\w$]+\.c\)\(6\),n=[\w$]+\([\w$]+\),r=e\?\.hostId\?\?n,i=[\w$]+\(r\),a=i\?\.authMethod===`chatgpt`/);
  const fastName = fastFunction.match(/function ([\w$]+)/)[1];
  const cache = fastFunction.match(/\(0,([\w$]+)\.c\)/)[1];
  const hostRead = fastFunction.match(/n=([\w$]+)\(([\w$]+)\)/);
  const authRead = fastFunction.match(/i=([\w$]+)\(r\)/)[1];
  const requirements = fastFunction.match(/=([\w$]+)\(([\w$]+),s\)/);
  for (const loading of [false, true]) {
    const bindings = {[cache]:{c:() => []}, [hostRead[1]]:() => "offline", [hostRead[2]]:null, [authRead]:() => ({authMethod:"apikey", isLoading:loading}), [requirements[1]]:() => ({data:null, isPending:false}), [requirements[2]]:null};
    const fast = Function(...Object.keys(bindings), `${fastFunction};return ${fastName}`)(...Object.values(bindings));
    assert.equal(fast().isServiceTierAllowed, !loading);
  }
  assert.throws(() => applyApiKeyUltraAssets([outputs[0]]), /Required/);
  let rejectedContinuations = 0;
  const validatedReport = fs.readFileSync(reportPath, "utf8");
  for (const entry of outputs) {
    for (const gate of report.assets.find(candidate => candidate.asset === entry.asset).validated) {
      const marker = `/*${gate}*/`;
      const corrupted = {...entry, source:entry.source.replace(marker, marker + "&&false")};
      assert.throws(() => applyApiKeyUltraAssets(outputs.map(candidate => candidate === entry ? corrupted : candidate)), /Required/, marker);
      const assetPath = path.join(assetsDir, entry.asset);
      fs.writeFileSync(assetPath, corrupted.source);
      const rejected = run();
      assert.notEqual(rejected.status, 0, marker);
      assert.match(rejected.stderr, /Required/, marker);
      assert.equal(fs.readFileSync(assetPath, "utf8"), corrupted.source);
      assert.equal(fs.readFileSync(reportPath, "utf8"), validatedReport);
      fs.writeFileSync(assetPath, entry.source);
      rejectedContinuations++;
    }
  }
  assert.equal(rejectedContinuations, 8);
  fs.writeFileSync(path.join(assetsDir, inputs[0].asset), "function unknown(){}");
  assert.notEqual(run().status, 0);
  console.log(JSON.stringify({archive, version, assets:names, validated:report.validated, catalogQueryCases:cases, rejectedContinuations, syntax:"PASS", idempotency:"PASS", missingGate:"FAIL_CLOSED"}, null, 2));
} finally {
  fs.rmSync(root, {recursive:true, force:true});
}

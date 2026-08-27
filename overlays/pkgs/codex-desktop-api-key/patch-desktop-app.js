"use strict";

const fs = require("node:fs");
const path = require("node:path");
const sourceMapModule = process.env.CODEX_BUNDLE_SOURCE_MAP
  ?? path.join(__dirname, "bundle-source-map.js");
const ultraGatesModule = process.env.CODEX_API_KEY_ULTRA_GATES
  ?? path.join(__dirname, "api-key-ultra-gates.js");
const { withSourceMap } = require(sourceMapModule);
const { applyApiKeyUltraGates, replaceOnce: replaceSourceOnce } = require(ultraGatesModule);

const root = path.resolve(process.argv[2] ?? process.cwd());
const assetsDir = path.join(root, "webview", "assets");
const assetNames = fs
  .readdirSync(assetsDir)
  .filter((name) => /^app-initial-[^.]+\.js$/.test(name));

if (assetNames.length !== 1) {
  throw new Error(
    `Expected exactly one desktop app-initial asset, found ${assetNames.length}: ${assetNames.join(", ")}`,
  );
}

const assetName = assetNames[0];
const assetPath = path.join(assetsDir, assetName);
const originalSource = fs.readFileSync(assetPath, "utf8");
let source = originalSource;

function replaceOnce(input, needle, replacement, marker) {
  return replaceSourceOnce(input, needle, replacement, marker, assetName);
}

if (!source.includes("codexLinuxApiKeyFastTier")) {
  throw new Error(
    "The api-key-service-tier feature was not applied before the desktop UI patch",
  );
}

source = replaceOnce(
  source,
  "fWc=l_(`composer-model-picker-menu-view-v1`,`simple`)",
  "fWc=l_(`composer-model-picker-menu-view-api-key-v2`,`simple`)/*codexLinuxApiKeySimpleViewState*/",
  "codexLinuxApiKeySimpleViewState",
);

source = applyApiKeyUltraGates(source, assetName);
source = replaceOnce(
  source,
  "de=p?oe.map(sWc):ygc(F,{includeUltraInSlider:u||m?.authMethod===`apikey`/*codexLinuxApiKeyUltraSlider*/})",
  "de=m?.authMethod===`apikey`?oe.filter(({model:t})=>t===E).map(sWc):p?oe.map(sWc):ygc(F,{includeUltraInSlider:u||m?.authMethod===`apikey`/*codexLinuxApiKeyUltraSlider*/})/*codexLinuxApiKeyDynamicPowerSelections*/",
  "codexLinuxApiKeyDynamicPowerSelections",
);
source = replaceOnce(
  source,
  "e===E?t!=null&&t!==se&&Jh(o,hDt,{reasoningEffort:t}):Jh(o,pDt,{model:e}),(o.get(_Or,n)??0)>0&&e!==E&&!Kfn(E,e)&&o.get(Tg).info",
  "e===E?t!=null&&t!==se&&Jh(o,hDt,{reasoningEffort:t}):Jh(o,pDt,{model:e}),m?.authMethod===`apikey`&&e!==E&&o.set(fWc,`simple`)/*codexLinuxApiKeySimpleAfterModelSwitch*/,(o.get(_Or,n)??0)>0&&e!==E&&!Kfn(E,e)&&o.get(Tg).info",
  "codexLinuxApiKeySimpleAfterModelSwitch",
);
source = replaceOnce(
  source,
  "w?.isModelLocked!==!0&&l!=null&&!re&&_&&!ie&&M!==`error`",
  "w?.isModelLocked!==!0&&(l!=null||m?.authMethod===`apikey`)&&!re&&_&&!ie&&M!==`error`/*codexLinuxApiKeySliderInit*/",
  "codexLinuxApiKeySliderInit",
);

const mapped = withSourceMap({ assetName, originalSource, patchedSource: source });
fs.writeFileSync(assetPath, mapped.source);
fs.writeFileSync(path.join(assetsDir, mapped.mapName), mapped.mapText);

const reportPath = path.join(root, ".codex-linux", "api-key-ui-patch.json");
fs.mkdirSync(path.dirname(reportPath), { recursive: true });
fs.writeFileSync(
  reportPath,
  `${JSON.stringify(
    {
      schemaVersion: 1,
      asset: assetName,
      patches: [
        "api-key-service-tier",
        "api-key-ultra-model-catalog",
        "api-key-ultra-power-slider",
        "api-key-dynamic-power-selections",
        "api-key-simple-view-state",
        "api-key-simple-after-model-switch",
        "api-key-slider-initialization",
      ],
    },
    null,
    2,
  )}\n`,
);

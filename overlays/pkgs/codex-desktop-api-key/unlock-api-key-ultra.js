"use strict";

const fs = require("node:fs");
const path = require("node:path");
const sourceMapModule = process.env.CODEX_BUNDLE_SOURCE_MAP
  ?? path.join(__dirname, "bundle-source-map.js");
const ultraGatesModule = process.env.CODEX_API_KEY_ULTRA_GATES
  ?? path.join(__dirname, "api-key-ultra-gates.js");
const { withSourceMap } = require(sourceMapModule);
const { applyApiKeyUltraAssets } = require(ultraGatesModule);

const root = path.resolve(process.argv[2] ?? process.cwd());
const assetsDir = path.join(root, "webview", "assets");
const assetNames = fs
  .readdirSync(assetsDir)
  .filter((name) => /^app-(?:initial|primary)-[^.]+\.js$/.test(name))
  .sort();

if (assetNames.length === 0) {
  throw new Error("Required desktop app assets are missing");
}

// API-key hosts reuse the native OAuth entitlement path. Provider catalog
// metadata and the native enabled-effort set remain the source of truth.
const assets = [];
const results = applyApiKeyUltraAssets(assetNames.map(asset => ({
  asset,
  source: fs.readFileSync(path.join(assetsDir, asset), "utf8"),
})));
for (const result of results) {
  const assetName = result.asset;
  const assetPath = path.join(assetsDir, assetName);
  const originalSource = fs.readFileSync(assetPath, "utf8");

  if (result.source !== originalSource) {
    const mapped = withSourceMap({
      assetName,
      originalSource,
      patchedSource: result.source,
    });
    fs.writeFileSync(assetPath, mapped.source);
    fs.writeFileSync(path.join(assetsDir, mapped.mapName), mapped.mapText);
  }
  assets.push({ asset: assetName, patches: result.patches, validated: result.validated });
}

const reportPath = path.join(root, ".codex-linux", "api-key-ultra-patch.json");
fs.mkdirSync(path.dirname(reportPath), { recursive: true });
fs.writeFileSync(
  reportPath,
  `${JSON.stringify(
    {
      schemaVersion: 1,
      assets,
      patches: [...new Set(assets.flatMap((entry) => entry.patches))],
      validated: assets.flatMap((entry) => entry.validated),
    },
    null,
    2,
  )}\n`,
);

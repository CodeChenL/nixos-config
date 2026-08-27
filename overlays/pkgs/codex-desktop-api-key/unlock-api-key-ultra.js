"use strict";

const fs = require("node:fs");
const path = require("node:path");
const sourceMapModule = process.env.CODEX_BUNDLE_SOURCE_MAP
  ?? path.join(__dirname, "bundle-source-map.js");
const ultraGatesModule = process.env.CODEX_API_KEY_ULTRA_GATES
  ?? path.join(__dirname, "api-key-ultra-gates.js");
const { withSourceMap } = require(sourceMapModule);
const { applyApiKeyUltraGates } = require(ultraGatesModule);

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
// API-key hosts reuse the native OAuth entitlement path. Provider catalog
// metadata and the native enabled-effort set remain the source of truth.
const source = applyApiKeyUltraGates(originalSource, assetName);

const mapped = withSourceMap({ assetName, originalSource, patchedSource: source });
fs.writeFileSync(assetPath, mapped.source);
fs.writeFileSync(path.join(assetsDir, mapped.mapName), mapped.mapText);

const reportPath = path.join(root, ".codex-linux", "api-key-ultra-patch.json");
fs.mkdirSync(path.dirname(reportPath), { recursive: true });
fs.writeFileSync(
  reportPath,
  `${JSON.stringify(
    {
      schemaVersion: 1,
      asset: assetName,
      patches: [
        "api-key-ultra-model-catalog",
        "api-key-ultra-power-slider",
      ],
    },
    null,
    2,
  )}\n`,
);

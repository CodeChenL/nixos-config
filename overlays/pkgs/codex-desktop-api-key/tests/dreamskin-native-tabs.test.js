"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const patchPath = path.resolve(__dirname, "..", "dreamskin-patch.js");

function patchSource() {
  return fs.readFileSync(patchPath, "utf8");
}

test("Linux only lets right-panel tabs paint through the frameless header", () => {
  const source = patchSource();
  const tick = String.fromCharCode(96);
  assert.doesNotMatch(source, /linuxNativeTabCss/u);
  assert.ok(source.includes(
    "const combinedCss = " + tick +
      "${coreCss}\\n${safeCss.runtimeSource}\\n${linuxFramelessHeaderCss}\\n" + tick + ";",
  ));
  assert.match(source, /main:is\([\s\S]*?:has\(\[data-app-shell-tab-strip-controller="right"\]\) > header:is\(/u);
  assert.match(source, /background:\s*transparent\s*!important/u);
  assert.match(source, /backdrop-filter:\s*none\s*!important/u);
  assert.doesNotMatch(source, /data-app-shell-tab-close-button/u);
  assert.doesNotMatch(source, /(?:visibility|opacity|color):[^;]*!important/u);
  assert.ok(source.includes(
    'linuxCompatibilityExceptions: ["right-panel-tabs-header-paint-through"]',
  ));
});

test("Linux overrides current main-content and home-suggestions selector drift", () => {
  const source = patchSource();
  const overrides = source.match(/const linuxSelectorOverrides = \{([\s\S]*?)\n  \};/u)?.[1];
  assert.ok(overrides, "linuxSelectorOverrides block missing");
  assert.match(overrides, /"main-content-top-fade"/u);
  assert.match(overrides, /"home-suggestions"/u);
  assert.doesNotMatch(overrides, /"(?:left-panel|message)"/u);
  assert.doesNotMatch(overrides, /\[data-app-shell-main-content-top-fade\]/u);
  assert.ok(source.includes(
    'linuxSelectorOverrides: ["main-content-top-fade", "home-suggestions"]',
  ));
});

test("Linux composer mapping follows the upstream visual-surface selector", () => {
  const source = patchSource();
  assert.doesNotMatch(source, /^\s*"composer-chrome":/mu);
  assert.match(source, /selector:\s*linuxSelectorOverrides\[entry\.key\]\s*\?\?\s*entry\.selector/u);
});

test("DreamSkin disable flag crosses the preload bridge into the sandboxed renderer", () => {
  const source = patchSource();
  assert.match(source, /isDreamSkinDisabled:\(\)=>process\.env\.CODEX_DREAMSKIN_DISABLE==="1"/u);
  const injection = source.match(/const injection = `([\s\S]*?)`;\n/u)?.[1];
  assert.ok(injection, "DreamSkin injection block missing");
  assert.ok(injection.includes("globalThis.electronBridge?.isDreamSkinDisabled?.()"));
  assert.doesNotMatch(injection, /globalThis\.process\?\.env\?\.CODEX_DREAMSKIN_DISABLE/u);
});

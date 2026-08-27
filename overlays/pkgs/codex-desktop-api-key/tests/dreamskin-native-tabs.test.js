"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const patchPath = path.resolve(__dirname, "..", "dreamskin-patch.js");

function nativeTabCss() {
  const source = fs.readFileSync(patchPath, "utf8");
  const marker = "const linuxNativeTabCss = `";
  const start = source.indexOf(marker);
  const end = source.indexOf("`;\n  const combinedCss", start);
  assert.notEqual(start, -1, "linuxNativeTabCss start marker missing");
  assert.notEqual(end, -1, "linuxNativeTabCss end marker missing");
  return source.slice(start + marker.length, end);
}

test("Linux tab bridge preserves native stacking and surface paint", () => {
  const css = nativeTabCss();
  assert.doesNotMatch(css, /\b(?:position|z-index)\s*:/u);
  assert.doesNotMatch(css, /header[^{}]*\{[^}]*z-index/su);
  assert.doesNotMatch(
    css,
    /\[data-app-shell-tabs\][^{]*\{[^}]*(?:position|z-index|background(?:-color)?)\s*:/su,
  );
});

test("right-panel tab descendants and sibling actions inherit DreamSkin colors", () => {
  const css = nativeTabCss();
  assert.match(css, /\[data-app-shell-tabs\]\s*>\s*:has\(\[data-app-shell-tab-strip-controller\]\)/u);
  assert.match(css, /:is\(button, button \*\)/u);
  assert.match(css, /\[data-app-shell-tab-close-button\]\s*\*/u);
  assert.match(css, /color:\s*inherit\s*!important/u);
  assert.match(css, /color:\s*var\(--ds-muted\)\s*!important/u);
});

test("open right-panel tabs are not painted over by the fixed header surface", () => {
  const css = nativeTabCss();
  assert.match(css, /@layer\s+dreamskin-accessibility\s*\{/u);
  assert.match(
    css,
    /main:is\([^)]*\):has\(\[data-app-shell-tab-strip-controller="right"\]\)\s*>\s*header:is\(/u,
  );
  assert.match(css, /background:\s*transparent\s*!important/u);
  assert.match(css, /backdrop-filter:\s*none\s*!important/u);
});

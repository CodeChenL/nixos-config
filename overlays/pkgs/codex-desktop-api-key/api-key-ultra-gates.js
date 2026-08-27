"use strict";

function replaceOnce(input, needle, replacement, marker, assetName = "bundle") {
  if (input.includes(marker)) {
    return input;
  }

  const first = input.indexOf(needle);
  const last = input.lastIndexOf(needle);
  if (first < 0 || first !== last) {
    throw new Error(`Expected one ${marker} anchor in ${assetName}`);
  }

  return input.slice(0, first) + replacement + input.slice(first + needle.length);
}

function applyApiKeyUltraGates(input, assetName = "bundle") {
  let source = input;
  source = replaceOnce(
    source,
    "f=a&&s.some(e=>e.supportedReasoningEfforts.some(({reasoningEffort:e})=>e===`ultra`))",
    "f=(a||t===`apikey`)&&s.some(e=>e.supportedReasoningEfforts.some(({reasoningEffort:e})=>e===`ultra`))/*codexLinuxApiKeyUltraCatalogFlag*/",
    "codexLinuxApiKeyUltraCatalogFlag",
    assetName,
  );
  source = replaceOnce(
    source,
    "let e=a?r.supportedReasoningEfforts:r.supportedReasoningEfforts.filter(({reasoningEffort:e})=>e!==`ultra`)",
    "let e=(a||t===`apikey`)?r.supportedReasoningEfforts:r.supportedReasoningEfforts.filter(({reasoningEffort:e})=>e!==`ultra`)/*codexLinuxApiKeyUltraCatalogParity*/",
    "codexLinuxApiKeyUltraCatalogParity",
    assetName,
  );
  source = replaceOnce(
    source,
    "ygc(F,{includeUltraInSlider:u})",
    "ygc(F,{includeUltraInSlider:u||m?.authMethod===`apikey`/*codexLinuxApiKeyUltraSlider*/})",
    "codexLinuxApiKeyUltraSlider",
    assetName,
  );
  return source;
}

module.exports = { applyApiKeyUltraGates, replaceOnce };

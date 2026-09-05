"use strict";

function literalPattern(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function matches(input, pattern) {
  return [...input.matchAll(new RegExp(pattern.source, "g"))];
}

function hasExpressionBoundaries(source, match, context) {
  const before = source.slice(0, match.index);
  const after = source.slice(match.index + match[0].length);
  switch (context) {
    case "declarator":
      return /(?:\b(?:const|let|var)\s+|,)\s*$/.test(before) && /^\s*[,;]/.test(after);
    case "declaration":
      return /(?:^|[;{}])\s*$/.test(before) && /^\s*[,;]/.test(after);
    case "property":
      return /[{,]\s*$/.test(before) && /^\s*[,}]/.test(after);
    case "call":
      return /(?:\breturn\s+|(?<![=!<>])=)\s*$/.test(before) && /^\s*[,;}]/.test(after);
    default:
      return false;
  }
}

function requiredSteps(currentSlider) {
  const steps = [
    {
      marker: "codexLinuxApiKeyUltraCatalogFlag",
      context: "declarator",
      needle: "p=o&&c.some(e=>e.supportedReasoningEfforts.some(({reasoningEffort:e})=>e===`ultra`))",
      replacement:
        "p=(o||t===`apikey`||s)&&c.some(e=>e.supportedReasoningEfforts.some(({reasoningEffort:e})=>e===`ultra`))/*codexLinuxApiKeyUltraCatalogFlag*/",
    },
    {
      marker: "codexLinuxApiKeyUltraCatalogParity",
      context: "declaration",
      needle:
        "let e=o?r.supportedReasoningEfforts:r.supportedReasoningEfforts.filter(({reasoningEffort:e})=>e!==`ultra`)",
      replacement:
        "let e=(o||t===`apikey`||s)?r.supportedReasoningEfforts:r.supportedReasoningEfforts.filter(({reasoningEffort:e})=>e!==`ultra`)/*codexLinuxApiKeyUltraCatalogParity*/",
    },
    {
      marker: "codexLinuxApiKeyUltraFeatureGate",
      context: "declarator",
      pattern: /m=([A-Za-z_$][\w$]*)&&([A-Za-z_$][\w$]*)\(([A-Za-z_$][\w$]*),`1186680773`\)/,
      replacement: (match) =>
        "m=(" + match[1] + "||t===`apikey`||a)/*codexLinuxApiKeyUltraFeatureGate*/",
      postcondition: /m=\([A-Za-z_$][\w$]*\|\|t===`apikey`\|\|a\)/,
    },
    {
      marker: "codexLinuxApiKeyUltraProviderGate",
      context: "property",
      pattern:
        /includeUltraReasoningEffort:([A-Za-z_$][\w$]*)\(([A-Za-z_$][\w$]*),`1186680773`\)/,
      replacement: (match) =>
        "includeUltraReasoningEffort:s.authMethod===`apikey`||" +
        match[1] +
        "(" +
        match[2] +
        ",`1186680773`)/*codexLinuxApiKeyUltraProviderGate*/",
      postcondition: /includeUltraReasoningEffort:s\.authMethod===`apikey`\|\|[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,`1186680773`\)/,
    },
    {
      marker: "codexLinuxApiKeyUltraSlider",
      context: "call",
      pattern: currentSlider
        ? /([A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,\{includeUltraInSlider:)[A-Za-z_$][\w$]*(,sliderModelsConfig:[A-Za-z_$][\w$]*,stripGptPrefix:![A-Za-z_$][\w$]*\}\))/
        : /([A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,\{includeUltraInSlider:)[A-Za-z_$][\w$]*(\}\))/,
      replacement: (match) =>
        match[1] + "!0/*codexLinuxApiKeyUltraSlider*/" + match[2],
      postcondition: currentSlider
        ? /[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,\{includeUltraInSlider:!0\/\*codexLinuxApiKeyUltraSlider\*\/,sliderModelsConfig:[A-Za-z_$][\w$]*,stripGptPrefix:![A-Za-z_$][\w$]*\}\)/
        : /[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,\{includeUltraInSlider:!0\/\*codexLinuxApiKeyUltraSlider\*\/\}\)/,
      embeddedMarker: true,
    },
    {
      marker: "codexLinuxApiKeyFastAllowed",
      context: "declarator",
      pattern:
        /d=!([A-Za-z_$][\w$]*)&&\(([A-Za-z_$][\w$]*)\?([A-Za-z_$][\w$]*)!=null&&\3\?\.requirements\?\.featureRequirements\?\.fast_mode!==!1:([A-Za-z_$][\w$]*)===`apikey`\)/,
      replacement: (match) =>
        "d=!" + match[1] + "/*codexLinuxApiKeyFastAllowed*/",
      postcondition: /d=![A-Za-z_$][\w$]*/,
    },
    {
      marker: "codexLinuxApiKeyFastModel",
      context: "property",
      pattern: /codexLinuxApiKeyServiceTierModel:([A-Za-z_$][\w$]*)===`apikey`/,
      replacement: (match) =>
        "codexLinuxApiKeyServiceTierModel:" +
        match[1] +
        "===`apikey`||s/*codexLinuxApiKeyFastModel*/",
      postcondition: /codexLinuxApiKeyServiceTierModel:[A-Za-z_$][\w$]*===`apikey`\|\|s/,
    },
  ];
  if (currentSlider) {
    steps.push({
      marker: "codexLinuxApiKeyUltraSliderSelection",
      context: "call",
      pattern: /([A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*(?:\?\.models)?,\{sliderModelsConfig:[A-Za-z_$][\w$]*,includeUltraInSlider:)[A-Za-z_$][\w$]*\.data\.ultraEffortEnabled===!0(\}\))/,
      replacement: (match) => match[1] + "!0/*codexLinuxApiKeyUltraSliderSelection*/" + match[2],
      postcondition: /[A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*(?:\?\.models)?,\{sliderModelsConfig:[A-Za-z_$][\w$]*,includeUltraInSlider:!0\/\*codexLinuxApiKeyUltraSliderSelection\*\/\}\)/,
      embeddedMarker: true,
    });
  }
  return steps;
}

function applyApiKeyUltraAssets(inputs) {
  const assets = inputs.map(({asset, source}) => ({asset, source, patches: [], validated: []}));
  const currentSlider = assets.some(({source}) => /includeUltraInSlider:[^{}]+,sliderModelsConfig:|\{sliderModelsConfig:[^{}]+,includeUltraInSlider:/.test(source));
  for (const step of requiredSteps(currentSlider)) {
    const pattern = step.pattern ?? new RegExp(literalPattern(step.needle));
    const marker = `/*${step.marker}*/`;
    const postcondition = step.postcondition
      ? new RegExp(step.postcondition.source + (step.embeddedMarker ? "" : literalPattern(marker)))
      : new RegExp(literalPattern(step.replacement));
    const before = assets.flatMap(entry => matches(entry.source, pattern).map(match => ({entry, match})));
    const markerCount = assets.reduce((count, entry) => count + entry.source.split(marker).length - 1, 0);
    if (markerCount === 0 && before.length === 1) {
      const {entry, match} = before[0];
      const replacement = typeof step.replacement === "function" ? step.replacement(match) : step.replacement;
      entry.source = entry.source.slice(0, match.index) + replacement + entry.source.slice(match.index + match[0].length);
      entry.patches.push(step.marker);
    }
    const after = assets.flatMap(entry => matches(entry.source, postcondition).map(match => ({entry, match})));
    const finalMarkers = assets.reduce((count, entry) => count + entry.source.split(marker).length - 1, 0);
    const remaining = assets.flatMap(entry => matches(entry.source.replace(postcondition, ""), pattern));
    if (after.length !== 1 || finalMarkers !== 1 || remaining.length !== 0 ||
        !hasExpressionBoundaries(after[0].entry.source, after[0].match, step.context)) {
      throw new Error(`Required ${step.marker}: Expected one validated gate across ${assets.map(entry => entry.asset).join(", ")}`);
    }
    after[0].entry.validated.push(step.marker);
  }
  return assets;
}

function applyApiKeyUltraGates(input, assetName = "bundle") {
  return applyApiKeyUltraAssets([{asset: assetName, source: input}])[0];
}

module.exports = { applyApiKeyUltraGates, applyApiKeyUltraAssets };

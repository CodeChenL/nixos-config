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

function requiredSteps(currentSlider, legacySliderFlag) {
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
      pattern: /([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)&&([A-Za-z_$][\w$]*)\(([A-Za-z_$][\w$]*),`1186680773`\)/,
      replacement: (match) =>
        match[1] + "=(" + match[2] + "||t===`apikey`||a)/*codexLinuxApiKeyUltraFeatureGate*/",
      postcondition: /([A-Za-z_$])=\([A-Za-z_$][\w$]*\|\|t===`apikey`\|\|a\)/,
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
  // 26.930 removed the includeUltraInSlider knob: the slider preset loop keeps
  // `ultra` entries unconditionally now. Legacy bundles still need the flag
  // forced to true; new bundles instead prove the filter no longer drops ultra.
  if (!legacySliderFlag) {
    const sliderIndex = steps.findIndex((step) => step.marker === "codexLinuxApiKeyUltraSlider");
    if (sliderIndex !== -1) {
      steps.splice(sliderIndex, 1);
    }
    steps.push(
      {
        marker: "codexLinuxApiKeyUltraSliderUnfiltered",
        assertOnly: true,
        pattern: /\(\{reasoning_effort:e\}\)=>!t\|\|e!==`xhigh`/,
      },
      {
        marker: "codexLinuxApiKeyUltraSliderNoUltraFilter",
        assertOnly: true,
        pattern: /reasoning_effort:e\)=>[^,;{}]{0,80}ultra/,
        expectAbsent: true,
      },
    );
  }
  if (currentSlider) {
    steps.push({
      marker: "codexLinuxApiKeyUltraSliderSelection",
      context: "call",
      pattern: /([A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*(?:\?\.models)?,\{sliderModelsConfig:[A-Za-z_$][\w$]*,includeUltraInSlider:)(?:(?:[A-Za-z_$][\w$]*==null\?)?[A-Za-z_$][\w$]*\.data\.ultraEffortEnabled===!0(?::[A-Za-z_$][\w$]*\.settings\?\.showUltraInModelPickerSlider===!0)?|[A-Za-z_$][\w$]*\.data\.ultraEffortEnabled===!0)(\}\))/,
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
  const legacySliderFlag = assets.some(({source}) => source.includes("includeUltraInSlider"));
  for (const step of requiredSteps(currentSlider, legacySliderFlag)) {
    if (step.assertOnly) {
      const found = assets.flatMap(entry => matches(entry.source, step.pattern).map(match => ({entry, match})));
      if (step.expectAbsent ? found.length !== 0 : found.length !== 1) {
        throw new Error(`Required ${step.marker}: expected ${step.expectAbsent ? "no" : "exactly one"} upstream occurrence across ${assets.map(entry => entry.asset).join(", ")}`);
      }
      (found[0]?.entry ?? assets[0]).validated.push(step.marker);
      continue;
    }
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

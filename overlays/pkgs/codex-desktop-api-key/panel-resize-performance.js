"use strict";

const fs = require("node:fs");
const path = require("node:path");

const MARKER = "codexLinuxPanelResizeFrame";
const MENU_FOCUS_MARKER = "codexLinuxScheduleMenuPointerFocus";
const MENU_FOCUS_NEEDLE = "e.defaultPrevented||e.currentTarget.focus({preventScroll:!0})";
const TERMINAL_FIT_MARKER = "__codexLinuxTerminalFitTimer";
const TICK = String.fromCharCode(96);

function literalPattern(value) {
  return value.replace(/[.*+?^$(){}|[\]\\]/g, "\\$&");
}

function occurrences(source, pattern) {
  return [...source.matchAll(new RegExp(pattern.source, "gu"))];
}

function resizerContracts(source) {
  const startPattern =
    /function ([A-Za-z_$][\w$]*)\(e\)\{let [^{}]{0,240}\{action:[A-Za-z_$][\w$]*,allowPointerOverflow:[A-Za-z_$][\w$]*,[^{}]{0,240}edge:([A-Za-z_$][\w$]*),[^{}]{0,1200}onResizeEnd:[A-Za-z_$][\w$]*,onResizingChange:[A-Za-z_$][\w$]*,setSize:([A-Za-z_$][\w$]*)\}=e/gu;
  return occurrences(source, startPattern).map((match) => {
    const end = source.indexOf("function ", match.index + match[0].length);
    if (end < 0) throw new Error("shared panel resizer function boundary is missing");
    return {
      start: match.index,
      end,
      functionName: match[1],
      edge: match[2],
      setter: match[3],
      source: source.slice(match.index, end),
    };
  });
}

function validatedPatchedSource(source) {
  const contracts = resizerContracts(source);
  if (contracts.length !== 1) {
    throw new Error("expected exactly one shared panel resizer");
  }
  const body = contracts[0].source;
  const required = new Map([
    [MARKER + "=null,codexLinuxPanelResizeEvent=null,codexLinuxSchedulePanelResize=e=>", 1],
    [MARKER + "??=requestAnimationFrame(()=>", 1],
    ["codexLinuxSchedulePanelResize(", 1],
    ["codexLinuxApplyPanelResize=", 1],
    ["codexLinuxApplyPanelResize(", 1],
    ["codexLinuxCancelPanelResize=()=>", 1],
    ["codexLinuxCancelPanelResize()", 2],
  ]);
  for (const [needle, expected] of required) {
    if (body.split(needle).length - 1 !== expected) {
      throw new Error("incomplete panel resize performance patch: " + needle);
    }
  }
  if (!body.includes("codexLinuxPanelResizePreviewTarget")) {
    throw new Error("incomplete panel resize performance patch: preview target");
  }
  return source;
}

function applyPanelResizePerformancePatch(source) {
  const contracts = resizerContracts(source);
  if (contracts.length !== 1) {
    throw new Error("expected exactly one shared panel resizer");
  }
  const contract = contracts[0];
  const flush =
    "let e=codexLinuxPanelResizeEvent;" +
    MARKER + "=null,codexLinuxPanelResizeEvent=null," +
    "e!=null&&codexLinuxApplyPanelResize(e)";
  if (contract.source.includes(MARKER)) return validatedPatchedSource(source);

  const pointerMove = TICK + "pointermove" + TICK;
  const listenerNeedle = "window.addEventListener(" + pointerMove + ",";
  const listenerRemoveNeedle = "window.removeEventListener(" + pointerMove + ",";
  if (!contract.source.includes(listenerNeedle) || !contract.source.includes(listenerRemoveNeedle)) {
    throw new Error("panel resize pointer listener contract has drifted");
  }

  const effectStarts = occurrences(
    contract.source,
    /=\(\)=>\{if\(![A-Za-z_$][\w$]*\)return;let /u,
  );
  if (effectStarts.length !== 1) {
    throw new Error("panel resize effect contract has drifted");
  }

  const setter = contract.setter;
  const setterPattern = literalPattern(setter);
  const movePattern = new RegExp(
    "([A-Za-z_$][\\w$]*)=([A-Za-z_$][\\w$]*)=>\\{\\2\\.preventDefault\\(\\);" +
      "([\\s\\S]{1,1500}?)" + setterPattern + "\\(([\\s\\S]{1,600}?)\\)\\}," +
      "([A-Za-z_$][\\w$]*)=([A-Za-z_$][\\w$]*)=>\\{\\6\\.preventDefault\\(\\)",
    "u",
  );
  const moveMatches = [...contract.source.matchAll(new RegExp(movePattern.source, "gu"))];
  if (moveMatches.length !== 1) {
    throw new Error("panel resize move update contract has drifted");
  }
  const move = moveMatches[0];
  const stateMatch = move[3].match(
    /let ([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\.current;/u,
  );
  if (!stateMatch) throw new Error("panel resize state contract has drifted");
  const state = stateMatch[1];
  const stateRef = stateMatch[2];

  const endPattern = new RegExp(
    setterPattern +
      "\\(([A-Za-z_$][\\w$]*)\\),([A-Za-z_$][\\w$]*)\\?\\.\\(\\1\\)",
    "u",
  );
  const listenerIndex = contract.source.indexOf(";return " + listenerNeedle, move.index);
  if (listenerIndex < 0) {
    throw new Error("panel resize listener registration contract has drifted");
  }
  const endRegion = contract.source.slice(move.index + move[0].length, listenerIndex);
  const endMatches = [...endRegion.matchAll(new RegExp(endPattern.source, "gu"))];
  if (endMatches.length !== 1) {
    throw new Error("panel resize final update contract has drifted");
  }
  const end = endMatches[0];

  const cleanupPattern = new RegExp(
    "\\(\\)=>\\{window\\.removeEventListener\\(" +
      literalPattern(pointerMove) +
      "," +
      literalPattern(move[1]) +
      "\\)",
    "u",
  );
  const cleanupMatches = [...contract.source.matchAll(new RegExp(cleanupPattern.source, "gu"))];
  if (cleanupMatches.length !== 1) {
    throw new Error("panel resize cleanup contract has drifted");
  }

  const helper =
    MARKER + "=null,codexLinuxPanelResizeEvent=null," +
    "codexLinuxSchedulePanelResize=e=>{" +
      "e.preventDefault(),codexLinuxPanelResizeEvent=e," +
      MARKER + "??=requestAnimationFrame(()=>{" + flush + "})" +
    "}," +
    "codexLinuxCancelPanelResize=()=>{" +
      "let e=" + stateRef + ".current?.codexLinuxPanelResizePreviewTarget;" +
      "e!=null&&(e.style.transform=" + stateRef +
        ".current?.codexLinuxPanelResizePreviewTransform??``)," +
      MARKER + "!=null&&cancelAnimationFrame(" + MARKER + ")," +
      MARKER + "=null,codexLinuxPanelResizeEvent=null" +
    "},";
  const preview =
    "let codexLinuxPanelResizeSize=" + move[4] + "," +
      "codexLinuxPanelResizeEdge=" + contract.edge + "??`right`," +
      "codexLinuxPanelResizeDelta=" +
        "(codexLinuxPanelResizeEdge===`left`||codexLinuxPanelResizeEdge===`top`?" +
          state + ".startSize-codexLinuxPanelResizeSize:" +
          "codexLinuxPanelResizeSize-" + state + ".startSize)," +
      "codexLinuxPanelResizeTarget=" + state + ".codexLinuxPanelResizePreviewTarget;" +
    "if(codexLinuxPanelResizeTarget==null){" +
      "codexLinuxPanelResizeTarget=" + move[2] + ".target instanceof Element?" +
        move[2] + ".target.closest(`.group\\\\/panel-resizer`):null," +
      state + ".codexLinuxPanelResizePreviewTarget=codexLinuxPanelResizeTarget," +
      state + ".codexLinuxPanelResizePreviewTransform=" +
        "codexLinuxPanelResizeTarget?.style.transform??``" +
    "}" +
    "if(codexLinuxPanelResizeTarget!=null){" +
      "let e=codexLinuxPanelResizeEdge===`left`||codexLinuxPanelResizeEdge===`right`?" +
        "`translateX`:`translateY`," +
        "t=" + state + ".codexLinuxPanelResizePreviewTransform;" +
      "codexLinuxPanelResizeTarget.style.transform=" +
        "(t?t+` `:``)+e+`(`+codexLinuxPanelResizeDelta+`px)`" +
    "}";

  let patched = contract.source;
  patched = patched.replace(
    movePattern,
    "codexLinuxApplyPanelResize=" + move[2] + "=>{" + move[2] + ".preventDefault();" +
      move[3] + preview + "}," +
      move[1] + "=" + move[2] + "=>{codexLinuxSchedulePanelResize(" + move[2] + ")}," +
      move[5] + "=" + move[6] + "=>{" + move[6] + ".preventDefault()",
  );
  patched = patched.replace(
    endPattern,
    "codexLinuxCancelPanelResize()," + setter + "(" + end[1] + ")," +
      end[2] + "?.(" + end[1] + ")",
  );
  patched = patched.replace(
    cleanupPattern,
    "()=>{codexLinuxCancelPanelResize(),window.removeEventListener(" +
      pointerMove + "," + move[1] + ")",
  );
  patched = patched.slice(0, effectStarts[0].index + effectStarts[0][0].length) +
    helper +
    patched.slice(effectStarts[0].index + effectStarts[0][0].length);

  return validatedPatchedSource(
    source.slice(0, contract.start) + patched + source.slice(contract.end),
  );
}

function validatedMenuPointerFocusSource(source) {
  const required = new Map([
    [MENU_FOCUS_MARKER + "=e=>", 1],
    [MENU_FOCUS_MARKER + "(e.currentTarget)", 1],
    ["globalThis.codexLinuxMenuPointerFocusTimer=setTimeout(", 1],
    ["e.matches(`:hover`)&&e.focus({preventScroll:!0})", 1],
  ]);
  for (const [needle, expected] of required) {
    if (source.split(needle).length - 1 !== expected) {
      throw new Error("incomplete menu pointer focus performance patch: " + needle);
    }
  }
  if (source.includes(MENU_FOCUS_NEEDLE)) {
    throw new Error("menu pointer focus performance patch left the synchronous focus call behind");
  }
  return source;
}

function applyMenuPointerFocusPerformancePatch(source) {
  if (source.includes(MENU_FOCUS_MARKER)) return validatedMenuPointerFocusSource(source);

  const menuItemAnchors = occurrences(
    source,
    /([A-Za-z_$][\w$]*)=`MenuItem`,([A-Za-z_$][\w$]*)=`menu\.itemSelect`,/u,
  );
  if (menuItemAnchors.length !== 1 || source.split(MENU_FOCUS_NEEDLE).length - 1 !== 1) {
    throw new Error("shared menu pointer focus contract has drifted");
  }
  const anchor = menuItemAnchors[0];
  const helper =
    anchor[1] + "=(" +
      "globalThis.codexLinuxMenuPointerFocusTimer=0," +
      "globalThis.codexLinuxMenuPointerFocusTarget=null," +
      "globalThis." + MENU_FOCUS_MARKER + "=e=>{" +
        "globalThis.codexLinuxMenuPointerFocusTarget=e," +
        "clearTimeout(globalThis.codexLinuxMenuPointerFocusTimer)," +
        "globalThis.codexLinuxMenuPointerFocusTimer=setTimeout(()=>{" +
          "let e=globalThis.codexLinuxMenuPointerFocusTarget;" +
          "globalThis.codexLinuxMenuPointerFocusTimer=0," +
          "globalThis.codexLinuxMenuPointerFocusTarget=null," +
          "e?.isConnected&&e.matches(`:hover`)&&e.focus({preventScroll:!0})" +
        "},120)" +
      "},`MenuItem`)," + anchor[2] + "=`menu.itemSelect`,";

  return validatedMenuPointerFocusSource(
    source
      .replace(anchor[0], helper)
      .replace(
        MENU_FOCUS_NEEDLE,
        "e.defaultPrevented||globalThis." + MENU_FOCUS_MARKER + "(e.currentTarget)",
      ),
  );
}

function terminalFitContracts(source) {
  return occurrences(
    source,
    /([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)=>\{let ([A-Za-z_$][\w$]*)=\2!==void 0&&\2;([A-Za-z_$][\w$]*)\|\|([A-Za-z_$][\w$]*)\.isConnected&&requestAnimationFrame\(\(\)=>\{\4\|\|\5\.isConnected&&\(([\s\S]{1,240}?)\)\}\)\}/u,
  );
}

function validatedTerminalFitSource(source) {
  if (source.split(TERMINAL_FIT_MARKER).length - 1 !== 4 ||
      !source.includes(TERMINAL_FIT_MARKER + "=setTimeout(()=>{") ||
      !source.includes("},250)")) {
    throw new Error("incomplete terminal fit performance patch");
  }
  if (terminalFitContracts(source).length !== 0) {
    throw new Error("terminal fit performance patch left the synchronous fit contract behind");
  }
  return source;
}

function applyTerminalFitPerformancePatch(source) {
  if (source.includes(TERMINAL_FIT_MARKER)) return validatedTerminalFitSource(source);
  const contracts = terminalFitContracts(source);
  if (contracts.length !== 1) throw new Error("terminal fit resize contract has drifted");
  const [needle, fit, event, force, disposed, element, action] = contracts[0];
  const timer = element + "." + TERMINAL_FIT_MARKER;
  const replacement =
    fit + "=" + event + "=>{let " + force + "=" + event + "!==void 0&&" + event + ";" +
    disposed + "||!" + element + ".isConnected||(" +
      timer + "!=null&&clearTimeout(" + timer + ")," +
      timer + "=setTimeout(()=>{" +
        timer + "=null," + disposed + "||" + element + ".isConnected&&(" + action + ")" +
      "},250)" +
    ")}";
  return validatedTerminalFitSource(source.replace(needle, replacement));
}

function applyPanelResizePerformanceAssets(inputs) {
  const resizerMatches = [];
  const menuFocusMatches = [];
  const terminalFitMatches = [];
  for (const input of inputs) {
    const count = resizerContracts(input.source).length;
    for (let index = 0; index < count; index += 1) resizerMatches.push(input);
    if (input.source.includes(MENU_FOCUS_NEEDLE) || input.source.includes(MENU_FOCUS_MARKER)) {
      menuFocusMatches.push(input);
    }
    if (terminalFitContracts(input.source).length > 0 || input.source.includes(TERMINAL_FIT_MARKER)) {
      terminalFitMatches.push(input);
    }
  }
  if (resizerMatches.length !== 1) {
    throw new Error("expected exactly one shared panel resizer across desktop assets");
  }
  if (menuFocusMatches.length !== 1) {
    throw new Error("expected exactly one shared menu pointer focus contract across desktop assets");
  }
  if (terminalFitMatches.length !== 1) {
    throw new Error("expected exactly one terminal fit resize contract across desktop assets");
  }
  return inputs.map((input) => {
    let source = input.source;
    if (input === resizerMatches[0]) source = applyPanelResizePerformancePatch(source);
    if (input === menuFocusMatches[0]) source = applyMenuPointerFocusPerformancePatch(source);
    if (input === terminalFitMatches[0]) source = applyTerminalFitPerformancePatch(source);
    return source === input.source ? input : { ...input, source };
  });
}

function main() {
  const root = path.resolve(process.argv[2] ?? process.cwd());
  const assetsDir = path.join(root, "webview", "assets");
  const assetNames = fs.readdirSync(assetsDir)
    .filter((name) => /^(?:app-(?:initial|primary|shared)|terminal-panel)-[^.]+\.js$/u.test(name))
    .sort();
  if (assetNames.length === 0) throw new Error("required desktop app assets are missing");

  const inputs = assetNames.map((asset) => ({
    asset,
    source: fs.readFileSync(path.join(assetsDir, asset), "utf8"),
  }));
  const outputs = applyPanelResizePerformanceAssets(inputs);
  const changed = outputs.filter((output, index) => output.source !== inputs[index].source);
  if (changed.length > 3) throw new Error("interaction performance patch changed too many assets");

  const target = outputs.find((output) => output.source.includes(MARKER));
  const menuTarget = outputs.find((output) => output.source.includes(MENU_FOCUS_MARKER));
  const terminalTarget = outputs.find((output) => output.source.includes(TERMINAL_FIT_MARKER));
  if (!target) throw new Error("panel resize patch marker is missing");
  if (!menuTarget) throw new Error("menu pointer focus patch marker is missing");
  if (!terminalTarget) throw new Error("terminal fit patch marker is missing");
  if (changed.length > 0) {
    const sourceMapModule = process.env.CODEX_BUNDLE_SOURCE_MAP
      ?? path.join(__dirname, "bundle-source-map.js");
    const { withSourceMap } = require(sourceMapModule);
    for (const output of changed) {
      const assetPath = path.join(assetsDir, output.asset);
      const mapped = withSourceMap({
        assetName: output.asset,
        originalSource: inputs.find((input) => input.asset === output.asset).source,
        patchedSource: output.source,
      });
      fs.writeFileSync(assetPath, mapped.source);
      fs.writeFileSync(path.join(assetsDir, mapped.mapName), mapped.mapText);
    }
  }

  const reportPath = path.join(root, ".codex-linux", "panel-resize-performance-patch.json");
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, JSON.stringify({
    schemaVersion: 1,
    asset: target.asset,
    patch: "composited-divider-preview-final-commit",
    menuAsset: menuTarget.asset,
    menuPatch: "debounced-pointer-focus-120ms",
    terminalAsset: terminalTarget.asset,
    terminalPatch: "trailing-fit-debounce-250ms",
    status: changed.length > 0 ? "applied" : "already-applied",
  }, null, 2) + "\n");
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error?.stack ?? error);
    process.exitCode = 1;
  }
}

module.exports = {
  applyMenuPointerFocusPerformancePatch,
  applyPanelResizePerformancePatch,
  applyTerminalFitPerformancePatch,
  applyPanelResizePerformanceAssets,
};

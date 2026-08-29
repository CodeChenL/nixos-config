"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const sourceMapModule = process.env.CODEX_BUNDLE_SOURCE_MAP
  ?? path.join(__dirname, "bundle-source-map.js");
const { withSourceMap } = require(sourceMapModule);

const root = path.resolve(process.argv[2] ?? process.cwd());
const LINUX_DREAMSKIN_CLIENT_VERSION = "1.0.0";

function fail(message) {
  throw new Error(`DreamSkin Linux patch: ${message}`);
}

function parseArguments(argv) {
  const options = {
    source: null,
    theme: null,
    allowPlatformMismatch: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--allow-platform-mismatch") {
      options.allowPlatformMismatch = true;
      continue;
    }
    if (argument === "--source" || argument === "--theme") {
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) fail(`${argument} requires a path`);
      options[argument === "--source" ? "source" : "theme"] = path.resolve(value);
      index += 1;
      continue;
    }
    fail(`unknown argument: ${argument}`);
  }
  if (!options.source || !options.theme) fail("--source and --theme are required");
  return options;
}

function readJson(filePath, label) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`);
  }
}

function hash(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function compareSemver(left, right) {
  const a = left.split(".").map(Number);
  const b = right.split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return 0;
}

function regularFile(filePath, label) {
  const stat = fs.lstatSync(filePath);
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`${label} must be a regular file`);
  return stat;
}

function listFiles(directory) {
  const files = [];
  const walk = (current, prefix) => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      const absolute = path.join(current, entry.name);
      if (entry.isSymbolicLink()) fail(`theme package contains a symlink: ${relative}`);
      if (entry.isDirectory()) walk(absolute, relative);
      else if (entry.isFile()) files.push(relative);
      else fail(`theme package contains a non-file entry: ${relative}`);
    }
  };
  walk(directory, "");
  return files.sort();
}

function resolveThemeRoot(directory) {
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  if (entries.some((entry) => entry.isFile() && entry.name === "manifest.json")) return directory;
  const directories = entries.filter((entry) => entry.isDirectory());
  const files = entries.filter((entry) => entry.isFile());
  if (directories.length === 1 && files.length === 0) {
    const nested = path.join(directory, directories[0].name);
    if (fs.existsSync(path.join(nested, "manifest.json"))) return nested;
  }
  fail("theme package must contain manifest.json at its root or one wrapper directory below it");
}

function compileSelectorTokens(source, selectorMap, label) {
  const compiled = source.replace(/__DREAM_SELECTOR_([A-Z0-9_]+)__/gu, (token, identifier) => {
    const key = identifier.toLowerCase().replaceAll("_", "-");
    const selector = selectorMap.get(key);
    if (!selector) fail(`${label} references unknown selector token ${token}`);
    return selector;
  });
  const unresolved = compiled.match(/__DREAM_SELECTOR_[A-Za-z0-9_]+__/u);
  if (unresolved) fail(`${label} contains unresolved selector token ${unresolved[0]}`);
  return compiled;
}

function normalizeTheme(theme, imageName, imageMetadata) {
  if (!theme || typeof theme !== "object" || Array.isArray(theme)) fail("theme.json must be an object");
  if (theme.schemaVersion !== 1) fail("theme.json schemaVersion must be 1");
  if (typeof theme.id !== "string" || !/^[a-z0-9]+(?:[.-][a-z0-9]+)*$/u.test(theme.id)) {
    fail("theme.json id is invalid");
  }
  if (typeof theme.name !== "string" || theme.name.length < 1 || theme.name.length > 80) {
    fail("theme.json name is invalid");
  }
  if (theme.image !== imageName) fail("theme.json image does not match the package background");

  const appearance = theme.appearance ?? "auto";
  if (!["auto", "light", "dark"].includes(appearance)) fail("theme.json appearance is invalid");
  const art = theme.art && typeof theme.art === "object" && !Array.isArray(theme.art)
    ? theme.art : {};
  const unit = (value, fallback, label) => {
    if (value === undefined) return fallback;
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 1) {
      fail(`theme.json ${label} is invalid`);
    }
    return value;
  };
  const safeArea = art.safeArea ?? "auto";
  const taskMode = art.taskMode ?? "auto";
  if (!["auto", "left", "right", "center", "none"].includes(safeArea)) {
    fail("theme.json art.safeArea is invalid");
  }
  if (!["auto", "ambient", "banner", "full", "off"].includes(taskMode)) {
    fail("theme.json art.taskMode is invalid");
  }

  const colors = theme.colors && typeof theme.colors === "object" && !Array.isArray(theme.colors)
    ? theme.colors : {};
  const colorKeys = [
    "background", "panel", "panelAlt", "accent", "accentAlt", "secondary",
    "highlight", "text", "muted", "line",
  ];
  for (const key of colorKeys) {
    if (colors[key] !== undefined && !/^(?:#[0-9a-f]{3,8}|rgba?\([^)]*\))$/iu.test(String(colors[key]))) {
      fail(`theme.json colors.${key} is invalid`);
    }
  }

  const normalized = {
    schemaVersion: 1,
    id: theme.id,
    name: theme.name,
    image: imageName,
    appearance,
    art: {
      focusX: unit(art.focusX, 0.5, "art.focusX"),
      focusY: unit(art.focusY, 0.5, "art.focusY"),
      safeArea,
      taskMode,
    },
    artMetadata: imageMetadata,
  };
  if (Object.keys(colors).length > 0) normalized.colors = colors;
  for (const key of [
    "brandSubtitle", "tagline", "projectPrefix", "projectLabel", "statusText",
    "quote", "promoTitle", "promoSub",
  ]) {
    if (typeof theme[key] === "string") normalized[key] = theme[key].slice(0, 120);
  }
  return normalized;
}

async function buildPayload(options, assetName) {
  const themeRoot = resolveThemeRoot(options.theme);
  const manifestPath = path.join(themeRoot, "manifest.json");
  const themePath = path.join(themeRoot, "theme.json");
  const cssPath = path.join(themeRoot, "theme.css");
  regularFile(manifestPath, "manifest.json");
  regularFile(themePath, "theme.json");
  regularFile(cssPath, "theme.css");

  const manifest = readJson(manifestPath, "manifest.json");
  if (manifest.packageVersion !== 1 || manifest.skinApiVersion !== 1) {
    fail("unsupported DreamSkin package or skin API version");
  }
  if (typeof manifest.version !== "string" || !/^\d+\.\d+\.\d+$/u.test(manifest.version)) {
    fail("manifest.version must be a semantic version");
  }
  if (typeof manifest.minClientVersion !== "string" || !/^\d+\.\d+\.\d+$/u.test(manifest.minClientVersion)) {
    fail("manifest.minClientVersion must be a semantic version");
  }
  if (compareSemver(manifest.minClientVersion, LINUX_DREAMSKIN_CLIENT_VERSION) > 0) {
    fail(`theme requires DreamSkin client ${manifest.minClientVersion}, Linux adapter is ${LINUX_DREAMSKIN_CLIENT_VERSION}`);
  }
  if (typeof manifest.themeId !== "string") fail("manifest.themeId is required");
  if (!Array.isArray(manifest.platforms) || manifest.platforms.length === 0) {
    fail("manifest.platforms must be a non-empty array");
  }
  const platformMismatch = !manifest.platforms.includes("linux");
  if (platformMismatch && !options.allowPlatformMismatch) {
    fail(`theme declares ${JSON.stringify(manifest.platforms)}; explicit Linux compatibility override is required`);
  }
  if (platformMismatch) {
    console.warn(
      `DreamSkin Linux patch: accepting non-Linux declaration ${JSON.stringify(manifest.platforms)} ` +
      "through the explicit Nix compatibility override",
    );
  }
  const capabilities = new Set(Array.isArray(manifest.capabilities) ? manifest.capabilities : []);
  if (!Array.isArray(manifest.capabilities) || capabilities.size !== manifest.capabilities.length ||
      capabilities.size === 0 || [...capabilities].some((value) => !["background", "tokens", "safe-css"].includes(value))) {
    fail("manifest.capabilities contains unsupported capabilities");
  }
  if (!capabilities.has("safe-css")) fail("DreamSkin Linux consumer requires the safe-css capability");

  const actualFiles = listFiles(themeRoot)
    .filter((name) => name !== "manifest.json" && name !== "manifest.sig")
    .sort();
  const declaredFiles = Array.isArray(manifest.files) ? manifest.files : [];
  const declaredNames = declaredFiles.map((entry) => entry?.path).sort();
  if (JSON.stringify(actualFiles) !== JSON.stringify(declaredNames)) {
    fail("manifest.files does not exactly match the theme payload");
  }
  const backgrounds = declaredNames.filter((name) => /^background\.(?:png|jpe?g|webp)$/iu.test(name));
  if (backgrounds.length !== 1) fail("DreamSkin package must contain exactly one background image");
  const expectedMediaTypes = {
    "theme.json": "application/json",
    "theme.css": "text/css",
    "LICENSE.txt": "text/plain",
  };
  for (const entry of declaredFiles) {
    if (!entry || typeof entry.path !== "string" || path.basename(entry.path) !== entry.path) {
      fail("manifest.files contains an unsafe path");
    }
    if (!/^(?:theme\.json|theme\.css|LICENSE\.txt|background\.(?:png|jpe?g|webp))$/iu.test(entry.path)) {
      fail(`manifest.files contains an unsupported payload: ${entry.path}`);
    }
    if (!Number.isInteger(entry.bytes) || entry.bytes < 1 ||
        typeof entry.sha256 !== "string" || !/^[0-9a-f]{64}$/u.test(entry.sha256)) {
      fail(`manifest.files has invalid metadata for ${entry.path}`);
    }
    const expectedMediaType = expectedMediaTypes[entry.path] ??
      (/\.png$/iu.test(entry.path) ? "image/png" : /\.webp$/iu.test(entry.path) ? "image/webp" : "image/jpeg");
    if (entry.mediaType !== expectedMediaType) fail(`${entry.path} has an invalid mediaType`);
    const bytes = fs.readFileSync(path.join(themeRoot, entry.path));
    if (bytes.length !== entry.bytes || hash(bytes) !== entry.sha256) {
      fail(`${entry.path} does not match its manifest hash or byte length`);
    }
  }

  const theme = readJson(themePath, "theme.json");
  if (manifest.themeId !== theme.id) fail("manifest.themeId does not match theme.json id");
  const imageName = theme.image;
  if (typeof imageName !== "string" || path.basename(imageName) !== imageName ||
      !/^background\.(?:png|jpe?g|webp)$/iu.test(imageName)) {
    fail("theme.json image must name one background image at the package root");
  }
  const imagePath = path.join(themeRoot, imageName);
  const imageBytes = fs.readFileSync(imagePath);
  if (imageBytes.length < 1 || imageBytes.length > 10 * 1024 * 1024) {
    fail("theme background image exceeds the 10 MiB limit");
  }
  const imageModule = await import(pathToFileURL(path.join(options.source, "runtime/image-metadata.mjs")).href);
  const imageMetadata = imageModule.readImageMetadata(imageBytes, path.extname(imageName));
  if (!imageMetadata) fail("theme background image metadata is invalid or exceeds safety limits");

  const safeCssModule = await import(pathToFileURL(path.join(options.source, "runtime/safe-css-validator.mjs")).href);
  const cssBytes = fs.readFileSync(cssPath);
  if (cssBytes.length < 1 || cssBytes.length > 256 * 1024) fail("theme.css exceeds the 256 KiB limit");
  const safeCss = safeCssModule.decodeAndValidateSafeCss(new Uint8Array(cssBytes));

  const selectorContract = readJson(path.join(options.source, "tools/selectors.json"), "DreamSkin selectors.json");
  if (selectorContract.schema !== "codex-dream-skin-selectors/1" || !Array.isArray(selectorContract.selectors)) {
    fail("unsupported DreamSkin selector contract");
  }
  const linuxSelectorOverrides = {
    "home-suggestions": ':is([data-home-ambient-suggestions], .group\\/home-suggestions)',
  };
  const selectors = selectorContract.selectors.map((entry) => ({
    ...entry,
    selector: linuxSelectorOverrides[entry.key] ?? entry.selector,
  }));
  const selectorMap = new Map();
  for (const entry of selectors) {
    if (!entry?.key || !entry?.selector || selectorMap.has(entry.key)) fail("invalid DreamSkin selector contract");
    selectorMap.set(entry.key, entry.selector);
  }
  const runtimeContract = {
    schema: selectorContract.schema,
    selectors: selectors.map(({ key, selector, tier, scope, required }) => ({
      key, selector, tier, scope, required: Boolean(required),
    })),
    stableTestids: Array.isArray(selectorContract.stableTestids) ? [...selectorContract.stableTestids] : [],
  };

  const coreCss = compileSelectorTokens(
    fs.readFileSync(path.join(options.source, "runtime/dream-skin.css"), "utf8"),
    selectorMap,
    "DreamSkin core CSS",
  );
  const runtimeTemplate = fs.readFileSync(path.join(options.source, "runtime/renderer-inject.js"), "utf8")
    .replace("__DREAM_SKIN_SELECTORS_JSON__", () => JSON.stringify(runtimeContract));
  const normalizedTheme = normalizeTheme(theme, imageName, imageMetadata);
  normalizedTheme.artKey = hash(imageBytes).slice(0, 20);
  // The Linux frameless header is a root z-30 surface, while the right-panel
  // tab row is trapped in the main content's lower stacking context. Let that
  // row paint through without restyling the native tabs or their actions.
  const linuxFramelessHeaderCss = `
@layer dreamskin-accessibility {
  html[data-dream-skin="active"] main:is(
    .main-surface,
    [data-app-shell-main-surface],
    [class*="_MainContentSurface_"]
  ):has([data-app-shell-tab-strip-controller="right"]) > header:is(
    .app-header-tint,
    [data-app-shell-header-edge-scroll],
    [class*="_Header_"]
  ) {
    background: transparent !important;
    backdrop-filter: none !important;
  }
}
`;
  const combinedCss = `${coreCss}\n${safeCss.runtimeSource}\n${linuxFramelessHeaderCss}\n`;
  const styleRevision = hash(Buffer.from(combinedCss, "utf8")).slice(0, 20);
  const payloadRevision = hash(Buffer.from(
    `codex-linux-dreamskin-v1\0${combinedCss}\0${runtimeTemplate}\0${JSON.stringify(normalizedTheme)}`,
    "utf8",
  )).slice(0, 20);
  const extension = path.extname(imageName).toLowerCase();
  const mime = extension === ".jpg" || extension === ".jpeg" ? "image/jpeg"
    : extension === ".webp" ? "image/webp" : "image/png";
  const artDataUrl = `data:${mime};base64,${imageBytes.toString("base64")}`;
  const payload = runtimeTemplate
    .replace("__DREAM_SKIN_CSS_JSON__", () => JSON.stringify(combinedCss))
    .replace("__DREAM_SKIN_ART_JSON__", () => JSON.stringify(artDataUrl))
    .replace("__DREAM_SKIN_THEME_JSON__", () => JSON.stringify(normalizedTheme))
    .replace("__DREAM_SKIN_VERSION_JSON__", () => JSON.stringify("codex-linux-dreamskin-v1"))
    .replace("__DREAM_SKIN_STYLE_REVISION_JSON__", () => JSON.stringify(styleRevision))
    .replace("__DREAM_SKIN_PAYLOAD_REVISION_JSON__", () => JSON.stringify(payloadRevision));
  if (/__DREAM_(?:SKIN|SELECTOR)_[A-Z0-9_]+__/u.test(payload)) fail("unresolved DreamSkin payload placeholder");
  try {
    new Function(payload);
  } catch (error) {
    fail(`DreamSkin payload syntax validation failed: ${error.message}`);
  }

  const injection = `
;(()=>{
  if(globalThis.__codexLinuxDreamSkinInstalled===${JSON.stringify(payloadRevision)})return;
  if(globalThis.process?.env?.CODEX_DREAMSKIN_DISABLE==="1")return;
  try{
    const result=${payload};
    globalThis.__codexLinuxDreamSkinInstalled=${JSON.stringify(payloadRevision)};
    globalThis.__codexLinuxDreamSkin={themeId:${JSON.stringify(normalizedTheme.id)},themeName:${JSON.stringify(normalizedTheme.name)},revision:${JSON.stringify(payloadRevision)},result,cleanup:globalThis.__CODEX_DREAM_SKIN_STATE__?.cleanup};
  }catch(error){console.error("[codex-linux-dreamskin] failed to apply theme",error)}
})();
`;
  return {
    injection,
    report: {
      schemaVersion: 1,
      asset: assetName,
      themeId: normalizedTheme.id,
      themeName: normalizedTheme.name,
      themeVersion: manifest.version,
      linuxClientVersion: LINUX_DREAMSKIN_CLIENT_VERSION,
      packagePlatforms: manifest.platforms,
      platformCompatibilityOverride: platformMismatch,
      linuxSelectorOverrides: ["home-suggestions"],
      linuxCompatibilityExceptions: ["right-panel-tabs-header-paint-through"],
      payloadRevision,
      styleRevision,
      image: imageName,
      imageMetadata,
    },
  };
}

async function main() {
  const options = parseArguments(process.argv.slice(3));
  const assetsDir = path.join(root, "webview", "assets");
  const indexAssetNames = fs.readdirSync(assetsDir).filter((name) => /^index-[^.]+\.js$/u.test(name));
  const entryAssets = indexAssetNames.filter((name) => {
    const candidate = fs.readFileSync(path.join(assetsDir, name), "utf8");
    return candidate.includes("__vite__mapDeps") && /app-main-[^'"`]+/u.test(candidate);
  });
  if (entryAssets.length !== 1) {
    fail(`expected exactly one webview entry asset, found ${entryAssets.length}: ${entryAssets.join(", ")}`);
  }

  const assetName = entryAssets[0];
  const assetPath = path.join(assetsDir, assetName);
  const source = fs.readFileSync(assetPath, "utf8");
  if (source.includes("__codexLinuxDreamSkinInstalled")) {
    console.log("DreamSkin Linux patch is already present");
    return;
  }

  const bundleText = fs.readdirSync(assetsDir)
    .filter((name) => /\.js$/u.test(name))
    .map((name) => fs.readFileSync(path.join(assetsDir, name), "utf8"))
    .join("\n");
  for (const anchor of [
    "data-app-shell-main-surface",
    "app-shell-left-panel",
    "data-app-shell-header-edge-scroll",
    "data-codex-composer-root",
    "data-home-ambient-suggestions",
    "data-marker-message",
  ]) {
    if (!bundleText.includes(anchor)) fail(`Linux renderer anchor is missing: ${anchor}`);
  }

  const result = await buildPayload(options, assetName);
  const sourceMapMarker = source.lastIndexOf("\n//# sourceMappingURL=");
  const patchedSource = sourceMapMarker >= 0
    ? `${source.slice(0, sourceMapMarker)}\n${result.injection}${source.slice(sourceMapMarker)}`
    : `${source}\n${result.injection}`;
  const mapped = withSourceMap({ assetName, originalSource: source, patchedSource });
  fs.writeFileSync(assetPath, mapped.source);
  fs.writeFileSync(path.join(assetsDir, mapped.mapName), mapped.mapText);
  const reportPath = path.join(root, ".codex-linux", "dreamskin-native-patch.json");
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, `${JSON.stringify(result.report, null, 2)}\n`);
}

main().catch((error) => {
  console.error(error?.stack ?? error);
  process.exitCode = 1;
});

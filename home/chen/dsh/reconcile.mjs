import { constants } from "node:fs";
import { chmod, lstat, mkdir, open, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";

const credentialSources = Object.freeze([
  ["deepseek.key", "DEEPSEEK_API_KEY"],
  ["and.key", "OPENAI_API_KEY"],
  ["kimi.key", "KIMI_CODING_API_KEY"],
  ["xiaomi.key", "XIAOMI_TOKEN_PLAN_CN_API_KEY"],
  ["minimax.key", "MINIMAX_CN_API_KEY"],
]);

class ReconcileError extends Error {
  constructor(message) {
    super(message);
    this.name = "ReconcileError";
  }
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sourceError(filename, reason) {
  return new ReconcileError(`credential source ${filename} ${reason}`);
}

function validateSourceStat(stat, filename, currentUid) {
  if (!stat.isFile() || stat.isSymbolicLink()) throw sourceError(filename, "must be a non-symlink regular file");
  if ((stat.mode & 0o7777) !== 0o600) throw sourceError(filename, "must have mode 0600");
  if (stat.uid !== currentUid) throw sourceError(filename, "must be owned by the current user");
}

function decodeCredential(contents, filename) {
  let value;
  try {
    value = new TextDecoder("utf-8", { fatal: true }).decode(contents);
  } catch {
    throw sourceError(filename, "must contain UTF-8 text");
  }
  if (value.endsWith("\n")) value = value.slice(0, -1);
  if (value.length === 0 || /[\r\n\0]/.test(value)) {
    throw sourceError(filename, "must contain one non-empty line with an optional final LF");
  }
  return value;
}

async function readCredential(filename, currentUid) {
  let before;
  try {
    before = await lstat(filename);
  } catch (error) {
    if (error?.code === "ENOENT") return undefined;
    throw error;
  }
  validateSourceStat(before, filename, currentUid);
  const handle = await open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const after = await handle.stat();
    validateSourceStat(after, filename, currentUid);
    if (after.dev !== before.dev || after.ino !== before.ino) throw sourceError(filename, "changed while opening");
    return decodeCredential(await handle.readFile(), filename);
  } finally {
    await handle.close();
  }
}

async function readCredentials(secretsDir, currentUid) {
  const credentials = {};
  for (const [sourceName, credentialName] of credentialSources) {
    const value = await readCredential(join(secretsDir, sourceName), currentUid);
    if (value !== undefined) credentials[credentialName] = value;
  }
  return credentials;
}

async function readTextIfPresent(filename) {
  try {
    return await readFile(filename, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return undefined;
    throw error;
  }
}

async function targetHasContent(filename, content) {
  try {
    const stat = await lstat(filename);
    return stat.isFile() && (await readFile(filename, "utf8")) === content;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function writeIfChanged(filename, content, atomicWrite) {
  if (await targetHasContent(filename, content)) {
    await chmod(filename, 0o600);
    return;
  }
  await atomicWrite(filename, content, { mode: 0o600, dirMode: 0o700 });
}

function parseSettings(yaml, text, filename) {
  const document = yaml.parseDocument(text, { prettyErrors: true });
  if (document.errors.length > 0) throw new ReconcileError(`DSH settings at ${filename} are invalid YAML`);
  const root = document.toJS() ?? {};
  if (!isRecord(root)) throw new ReconcileError(`DSH settings at ${filename} must be a map`);
  if (!Object.hasOwn(root, "ui-onboarding")) return undefined;
  if (!isRecord(root["ui-onboarding"])) {
    throw new ReconcileError(`DSH settings at ${filename} have an invalid ui-onboarding section`);
  }
  return root["ui-onboarding"];
}

async function readSettingsSource(filename) {
  let settings;
  try {
    settings = JSON.parse(await readFile(filename, "utf8"));
  } catch {
    throw new ReconcileError(`generated DSH settings source ${filename} is invalid JSON`);
  }
  if (!isRecord(settings)) throw new ReconcileError(`generated DSH settings source ${filename} must be a map`);
  return settings;
}

async function reconcileSettings(options) {
  const target = join(options.dshHome, "settings.yaml");
  await options.withFileLock(target, async () => {
    const existing = await readTextIfPresent(target);
    const onboarding = existing === undefined ? undefined : parseSettings(options.yaml, existing, target);
    const next = onboarding === undefined
      ? options.settings
      : { ...options.settings, "ui-onboarding": onboarding };
    await writeIfChanged(target, options.yaml.stringify(next), options.writeFileAtomic);
  });
}

async function reconcileCredentials(options) {
  const target = join(options.dshHome, ".credentials.yaml");
  await options.withFileLock(target, async () => {
    await writeIfChanged(target, options.yaml.stringify(options.credentials), options.writeFileAtomic);
  });
}

async function loadDshModules(options) {
  const [atomicWrite, yaml] = await Promise.all([
    import(pathToFileURL(options.atomicWriteModulePath).href),
    import(pathToFileURL(options.yamlModulePath).href),
  ]);
  return { withFileLock: atomicWrite.withFileLock, writeFileAtomic: atomicWrite.writeFileAtomic, yaml };
}

export async function reconcile(options) {
  const currentUid = (options.getUid ?? process.getuid)();
  const [modules, credentials, settings] = await Promise.all([
    loadDshModules(options),
    readCredentials(options.secretsDir, currentUid),
    readSettingsSource(options.settingsJsonPath),
  ]);
  await mkdir(options.dshHome, { recursive: true, mode: 0o700 });
  await chmod(options.dshHome, 0o700);
  await reconcileSettings({ ...modules, ...options, settings });
  await reconcileCredentials({ ...modules, ...options, credentials });
}

function requiredOption(values, name) {
  const value = values[name];
  if (typeof value !== "string" || value.length === 0) throw new ReconcileError(`missing --${name}`);
  return value;
}

function commandOptions(argumentsList) {
  const { values } = parseArgs({
    args: argumentsList,
    options: {
      "dsh-home": { type: "string" },
      "settings-json": { type: "string" },
      "secrets-dir": { type: "string" },
      "atomic-write-module": { type: "string" },
      "yaml-module": { type: "string" },
    },
  });
  return {
    dshHome: requiredOption(values, "dsh-home"),
    settingsJsonPath: requiredOption(values, "settings-json"),
    secretsDir: requiredOption(values, "secrets-dir"),
    atomicWriteModulePath: requiredOption(values, "atomic-write-module"),
    yamlModulePath: requiredOption(values, "yaml-module"),
  };
}

export async function main(argumentsList = process.argv.slice(2), environment = process.env) {
  if (environment.DRY_RUN) {
    process.stdout.write("Would reconcile DSH settings and credentials.\n");
    return;
  }
  await reconcile(commandOptions(argumentsList));
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : "DSH reconciliation failed"}\n`);
    process.exitCode = 1;
  });
}

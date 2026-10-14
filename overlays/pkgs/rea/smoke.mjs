// Run with the packaged Node: node smoke.mjs <rea-output> <bash> [ghidra].
// Never inherits a real client configuration, and writes only beneath TMPDIR.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { lstatSync, mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

const [pkg, bash, provider] = process.argv.slice(2);
const root = mkdtempSync(join(tmpdir(), "rea-smoke-"));
const home = join(root, "home");
assert.ok(lstatSync(`${pkg}/share/agents/skills/reverse-engineer-anything`).isDirectory(),
  "Export a real skill directory that survives cp -r aggregation");
mkdirSync(join(home, ".agents", "skills"), { recursive: true });
symlinkSync(`${pkg}/share/agents/skills/reverse-engineer-anything`,
  join(home, ".agents", "skills", "reverse-engineer-anything"));
const env = {
  HOME: home, TMPDIR: root, XDG_CONFIG_HOME: join(home, ".config"),
  XDG_CACHE_HOME: join(home, ".cache"), XDG_DATA_HOME: join(home, ".local/share"),
  PATH: "", LANG: "C.UTF-8",
};
const run = (name, args, executable = "rea") => {
  const result = spawnSync(`${pkg}/bin/${executable}`, args, {
    cwd: root, env, encoding: "utf8", timeout: 60000, maxBuffer: 8 * 1024 * 1024,
  });
  writeFileSync(join(root, `${name}.stdout`), result.stdout ?? "");
  writeFileSync(join(root, `${name}.stderr`), result.stderr ?? "");
  assert.equal(result.status, 0, `${name}: ${result.error ?? result.stderr}\n${result.stdout}`);
  return result.stdout;
};
assert.equal(run("version", ["--version"]).trim(), "6.4.0");
assert.equal(run("alias-version", ["--version"], "rea-agents").trim(), "6.4.0");
run("mcp-doctor", ["mcp", "doctor", "--format", "json"]);
const skill = JSON.parse(run("skill-doctor", ["doctor", "--skill", "--json"]));
assert.equal(skill.healthy, true);
assert.equal(skill.identity.skill.installed_version, "37");
assert.equal(skill.identity.skill.installed_tool_count, 170);
if (provider === "ghidra") {
  const doctor = JSON.parse(run("ghidra-doctor", ["doctor", "--provider", "ghidra", "--json"]));
  assert.equal(doctor.healthy, true);
}

// Exercise the actual native addon, terminal renderer and REA process cleanup,
// rather than only requiring node-pty or inspecting its ELF dependencies.
const scenario = join(root, "scenario.json");
writeFileSync(scenario, JSON.stringify({
  executable: bash, arguments: ["-c", "test -t 1 && printf 'REA_PTY_OK\\n'"],
  working_directory: root, timeout_ms: 5000, idle_timeout_ms: 5000,
}));
const capture = JSON.parse(run("capture", ["capture-process", scenario, "--json"]));
assert.equal(capture.normalized_result.manifest.pty_backend, "node-pty");
assert.equal(capture.normalized_result.exit.code, 0);
assert.match(capture.normalized_result.frames.map(frame => frame.data).join(""), /REA_PTY_OK/);
assert.equal(capture.normalized_result.cleanup.owned_process_group, "verified");
assert.equal(capture.normalized_result.cleanup.temporary_root, "removed");

// A real newline-delimited JSON-RPC stdio exchange with the installed wrapper.
const child = spawn(`${pkg}/bin/rea`, ["mcp"], { cwd: root, env, stdio: "pipe" });
let stderr = "";
child.stderr.on("data", chunk => { stderr += chunk; });
const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
const deadline = setTimeout(() => child.kill("SIGKILL"), 60000);
const request = async (id, method, params) => {
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  for (;;) {
    const line = await lines.next();
    assert.equal(line.done, false, `MCP closed before ${method}: ${stderr}`);
    const response = JSON.parse(line.value);
    if (response.id !== id) continue;
    assert.equal(response.error, undefined, JSON.stringify(response));
    return response.result;
  }
};
try {
  const initialized = await request(1, "initialize", {
    protocolVersion: "2025-06-18", capabilities: {},
    clientInfo: { name: "rea-nix-smoke", version: "1" },
  });
  assert.equal(initialized.serverInfo.version, "6.4.0");
  child.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');
  const catalog = await request(2, "tools/list", {});
  assert.equal(catalog.tools.length, 170);
  assert.ok(catalog.tools.some(tool => tool.name === "capture_process_scenario"));
  writeFileSync(join(root, "mcp.json"), JSON.stringify({ initialized, catalog }, null, 2));
} finally {
  if (child.exitCode === null && child.signalCode === null) {
    const exited = once(child, "exit");
    child.stdin.end();
    await exited;
  }
  clearTimeout(deadline);
  writeFileSync(join(root, "mcp.stderr"), stderr);
  assert.equal(child.exitCode, 0, `MCP did not shut down cleanly: ${child.signalCode}\n${stderr}`);
}
console.log(`REA 6.4.0 CLI / skill 37 / MCP 170 tools / native PTY passed; evidence: ${root}`);

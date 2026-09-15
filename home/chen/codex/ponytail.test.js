"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const test = require("node:test");
const path = require("node:path");

const nixSource = fs.readFileSync(path.join(__dirname, "ponytail.nix"), "utf8");
const trustBlock = nixSource.match(
  /trustPonytailHooks = lib\.hm\.dag\.entryAfter \[ "installPonytail" \] ''(?<body>.*?)\n\s*'';/su,
)?.groups?.body;

test("trustPonytailHooks uses the installed Ponytail version", () => {
  assert.ok(trustBlock, "the Ponytail trust activation must be present");
  assert.match(
    trustBlock,
    /\$\{pkgs\.llm-agents\.codex\}\/bin\/codex plugin list --json/u,
    "the trust activation must query Codex's installed plugin list",
  );
  assert.match(
    trustBlock,
    /\|\s*\$\{pkgs\.jq\}\/bin\/jq -er/u,
    "the installed plugin list must be parsed with the packaged jq",
  );
  assert.match(
    trustBlock,
    /--arg pluginId \$\{lib\.escapeShellArg ponytailPluginId\}/u,
    "the Ponytail plugin id must be passed to jq via --arg",
  );
  assert.match(
    trustBlock,
    /\.installed\[\].*?\.pluginId\s*==\s*\$pluginId.*?\.installed\s*==\s*true/su,
    "the query must select the installed Ponytail entry by plugin id",
  );
  assert.match(
    trustBlock,
    /\(\.version\s*\|\s*type\)\s*==\s*"string".*?\(\.version\s*\|\s*length\)\s*>\s*0/su,
    "the query must require a non-empty string version",
  );
  assert.match(
    trustBlock,
    /if\s+length\s*==\s*1\s+then\s+\.\[0\]\.version\s+else\s+error\(/su,
    "the query must reject missing or ambiguous installed entries",
  );
  assert.doesNotMatch(
    trustBlock,
    /MARKETPLACE_PLUGIN_ROOT|\.codex-plugin\/plugin\.json/u,
    "the trust activation must not read the stale marketplace manifest",
  );
});

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const test = require("node:test");
const path = require("node:path");

const nixSource = fs.readFileSync(path.join(__dirname, "desktop-hooks.nix"), "utf8");

test("trustDesktopReaperHook passes CODEX_LINUX_APP_DIR without obsolete positional arguments", () => {
  const installInvocation = nixSource.match(
    /export PATH=.*?\n(?<invocation>.*?)(?=\n\s*\$\{pkgs\.nodejs\}\/bin\/node)/su,
  )?.groups?.invocation;
  assert.ok(installInvocation, "the activation must invoke the packaged install script");
  assert.match(
    installInvocation,
    /CODEX_LINUX_APP_DIR=\$\{lib\.escapeShellArg appDir\}[ \t]+"\$\{installScript\}"/u,
    "the caller must supply CODEX_LINUX_APP_DIR directly to the script",
  );
  assert.doesNotMatch(
    installInvocation,
    /(?:\\\n\s*)?"\$\{appDir\}"/u,
    "the app directory must not be passed as a positional argument",
  );
  assert.doesNotMatch(
    installInvocation,
    /\$HOME\/\.local\/state\/codex-desktop-linux(?:\/log)?/u,
    "obsolete state and log arguments must be absent",
  );
});

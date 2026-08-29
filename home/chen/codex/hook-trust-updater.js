"use strict";

const fs = require("fs");
const crypto = require("crypto");
const path = require("path");

const EVENT_LABELS = {
  PreToolUse: "pre_tool_use",
  PermissionRequest: "permission_request",
  PostToolUse: "post_tool_use",
  PreCompact: "pre_compact",
  PostCompact: "post_compact",
  SessionStart: "session_start",
  SessionEnd: "session_end",
  UserPromptSubmit: "user_prompt_submit",
  SubagentStart: "subagent_start",
  SubagentStop: "subagent_stop",
  Stop: "stop",
  Interrupt: "interrupt",
};

function canonicalJson(value) {
  if (Array.isArray(value)) return value.map(canonicalJson);
  if (value && typeof value === "object") {
    const out = {};
    for (const key of Object.keys(value).sort()) out[key] = canonicalJson(value[key]);
    return out;
  }
  return value;
}

function hookHash(eventName, matcher, handler, command) {
  const timeout = Math.max(Number(handler.timeout ?? 600), 1);
  const normalized = { type: "command", command, timeout, async: false };
  if (typeof handler.statusMessage === "string") normalized.statusMessage = handler.statusMessage;
  const limit = handler.additionalContextLimit ?? 2500;
  if (limit !== 2500) normalized.additionalContextLimit = limit;
  const identity = { event_name: eventName, hooks: [normalized] };
  if (typeof matcher === "string") identity.matcher = matcher;
  const raw = JSON.stringify(canonicalJson(identity));
  return "sha256:" + crypto.createHash("sha256").update(raw).digest("hex");
}

function stateBlock(key, trustedHash) {
  return "[hooks.state." + JSON.stringify(key) + "]\n" +
    "trusted_hash = " + JSON.stringify(trustedHash) + "\n";
}

function updateConfig(config, states) {
  let text = config;
  for (const state of states) {
    const header = "[hooks.state." + JSON.stringify(state.key) + "]";
    const marker = text.indexOf(header);
    if (marker === -1) {
      if (text.length > 0 && !text.endsWith("\n")) text += "\n";
      if (text.length > 0 && !text.endsWith("\n\n")) text += "\n";
      text += stateBlock(state.key, state.trustedHash) + "\n";
      continue;
    }
    const headerEnd = marker + header.length;
    let sectionEnd = text.indexOf("\n[", headerEnd);
    if (sectionEnd === -1) sectionEnd = text.length;
    const kept = text.slice(headerEnd, sectionEnd)
      .split("\n")
      .map((line) => line.trimEnd())
      .filter((line) => line.trim() !== "" && !/^\s*trusted_hash\s*=/.test(line));
    const replacement = header + "\n" +
      (kept.length > 0 ? kept.join("\n") + "\n" : "") +
      "trusted_hash = " + JSON.stringify(state.trustedHash) + "\n";
    let after = text.slice(sectionEnd);
    if (after.startsWith("\n")) after = after.slice(1);
    text = text.slice(0, marker) + replacement + "\n" + after;
  }
  return text;
}

function collectStates(raw, keyFor, accept) {
  const states = [];
  for (const [eventName, groups] of Object.entries(raw?.hooks ?? {})) {
    const label = EVENT_LABELS[eventName];
    if (!label || !Array.isArray(groups)) continue;
    groups.forEach((group, groupIndex) => {
      if (!group || !Array.isArray(group.hooks)) return;
      group.hooks.forEach((handler, handlerIndex) => {
        if (handler?.type !== "command" || handler.async === true) return;
        if (typeof handler.command !== "string" || !accept(handler)) return;
        states.push({
          key: keyFor(label, groupIndex, handlerIndex),
          trustedHash: hookHash(label, group.matcher, handler, handler.command),
        });
      });
    });
  }
  return states;
}

function pluginStates(pluginRoot, pluginId) {
  const manifest = JSON.parse(
    fs.readFileSync(path.join(pluginRoot, ".codex-plugin", "plugin.json"), "utf8")
  );
  const hookPaths = (Array.isArray(manifest.hooks) ? manifest.hooks : [manifest.hooks])
    .filter((entry) => typeof entry === "string" && entry.trim() !== "")
    .map((entry) => entry.replace(/^\.\//, ""));

  const states = [];
  for (const relativePath of hookPaths) {
    const raw = JSON.parse(fs.readFileSync(path.join(pluginRoot, relativePath), "utf8"));
    states.push(...collectStates(
      raw,
      (label, groupIndex, handlerIndex) =>
        pluginId + ":" + relativePath + ":" + label + ":" + groupIndex + ":" + handlerIndex,
      (handler) => handler.command.trim() !== ""
    ));
  }
  return states;
}

function hooksStates(hooksFile, marker) {
  const raw = JSON.parse(fs.readFileSync(hooksFile, "utf8"));
  return collectStates(
    raw,
    (label, groupIndex, handlerIndex) => hooksFile + ":" + label + ":" + groupIndex + ":" + handlerIndex,
    (handler) => handler.command.includes(marker)
  );
}

function main(mode, args) {
  let states;
  let label;
  if (mode === "plugin") {
    const [pluginRoot, configPath, pluginId] = args;
    if (!pluginRoot || !configPath || !pluginId) throw new Error("usage: hook-trust-updater.js plugin <plugin-root> <config.toml> <plugin-id>");
    states = pluginStates(pluginRoot, pluginId);
    label = "plugin";
  } else if (mode === "hooks") {
    const [hooksFile, configPath, marker] = args;
    if (!hooksFile || !configPath || !marker) throw new Error("usage: hook-trust-updater.js hooks <hooks.json> <config.toml> <marker>");
    if (!fs.existsSync(hooksFile)) return;
    states = hooksStates(hooksFile, marker);
    label = "desktop";
  } else {
    throw new Error("unknown mode: " + mode);
  }
  if (states.length === 0) throw new Error(label + " hook trust updater: no trustable command hooks found");

  const configPath = args[1];
  const current = fs.readFileSync(configPath, "utf8");
  const next = updateConfig(current, states);
  if (next !== current) {
    const dir = path.dirname(configPath);
    const tmp = path.join(dir, ".config.toml." + label + "-trust.tmp");
    fs.writeFileSync(tmp, next, { mode: 0o600 });
    fs.renameSync(tmp, configPath);
  }
  console.log(label + " hook trust updated: " + states.length + " hook(s)");
}

if (require.main === module) {
  main(process.argv[2], process.argv.slice(3));
}

module.exports = { canonicalJson, hookHash, updateConfig, collectStates, pluginStates, hooksStates };

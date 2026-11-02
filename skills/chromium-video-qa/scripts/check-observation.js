'use strict';

const fs = require('node:fs');

const VERSION = 'ROOTLESS_OBSERVATION_V1';
const decimal = /^\d+$/;
const boolean = /^[01]$/;

function parseSamples(text) {
  const lines = text.trim().split('\n');
  const samples = [];
  const sampleIds = new Set();
  let versioned = false;
  let sample;
  for (const line of lines) {
    if (line === VERSION) {
      if (sample || versioned) throw new Error('unexpected ROOTLESS_OBSERVATION_V1 marker');
      versioned = true;
      continue;
    }
    if (!sample && !versioned) throw new Error('expected ROOTLESS_OBSERVATION_V1');
    const fields = line.split('\t');
    const [kind, id] = fields;
    if (kind === 'BEGIN') {
      if (!versioned) throw new Error('expected ROOTLESS_OBSERVATION_V1');
      if (sample || fields.length !== 6 || !/^[a-f0-9]{32}$/.test(id) ||
          !/^[0-9a-f-]{36}$/.test(fields[2]) || !/^pid:\[[0-9]+\]$/.test(fields[3]) ||
          !decimal.test(fields[4]) || !decimal.test(fields[5]) || sampleIds.has(id))
        throw new Error('invalid observation header');
      sample = {id, boot: fields[2], namespace: fields[3], uid: fields[4],
        session: fields[5], processes: new Map(), unknown: []};
      sampleIds.add(id);
      versioned = false;
      continue;
    }
    if (!sample || id !== sample.id) throw new Error('cross-sample observation');
    if (kind === 'P') {
      if (fields.length !== 11 || !fields.slice(2, 7).every((value) => decimal.test(value)) ||
          !fields.slice(7).every((value) => boolean.test(value)))
        throw new Error('invalid process observation');
      if (sample.processes.has(fields[2])) throw new Error('duplicate process observation');
      sample.processes.set(fields[2], {start: fields[3], parent: fields[4],
        parentStart: fields[5], session: fields[6], profile: fields[7] === '1',
        gpu: fields[8] === '1', chromium: fields[9] === '1', fdOwner: fields[10] === '1'});
    } else if (kind === 'U') {
      if (fields.length !== 4 || !decimal.test(fields[2]) ||
          !/^[a-z0-9][a-z0-9._-]*$/.test(fields[3]))
        throw new Error('invalid opacity observation');
      sample.unknown.push({pid: fields[2], reason: fields[3]});
    } else if (kind === 'END') {
      if (fields.length !== 2) throw new Error('invalid observation end');
      for (const process of sample.processes.values()) {
        const parent = sample.processes.get(process.parent);
        if (parent && parent.start !== process.parentStart)
          throw new Error('parent identity mismatch');
      }
      samples.push(sample);
      sample = undefined;
    } else {
      throw new Error('unknown observation record');
    }
  }
  if (sample || versioned || samples.length === 0) throw new Error('incomplete observation');
  return samples;
}

function scopeOf(sample, unknown) {
  if (unknown.pid === '0') return 'device';
  const process = sample.processes.get(unknown.pid);
  if (!process) return 'unclassified';
  if (process.profile || (sample.session !== '0' && process.session === sample.session))
    return 'run';
  return 'external';
}

function scopes(samples) {
  const result = {device: false, run: false, unclassified: false, external: false};
  for (const sample of samples)
    for (const unknown of sample.unknown)
      result[scopeOf(sample, unknown)] = true;
  return result;
}

// Rootless observation cannot read every same-UID process (for example
// non-dumpable compositor processes), so opacity of unrelated processes is a
// recorded blind spot covered by GLOBAL_IDLE_UNKNOWN, not a hard block. Only an
// unreadable device, a visible conflict, or opacity that could belong to this
// run's session/profile may refuse or fail a check.
function check(text, mode, session = '0') {
  const samples = parseSamples(text);
  const first = samples[0];
  if (samples.some((sample) => sample.session !== session || sample.boot !== first.boot ||
      sample.namespace !== first.namespace || sample.uid !== first.uid)) return false;
  const observed = scopes(samples);
  const gap = observed.device || observed.run || observed.unclassified;
  const visibleOwner = samples.some((sample) =>
    [...sample.processes.values()].some((process) => process.fdOwner));
  if (mode === 'complete') return !gap;
  if (mode === 'visible-idle') return !gap && !visibleOwner;
  if (mode === 'preflight') return !observed.device && !visibleOwner && samples.every((sample) =>
    ![...sample.processes.values()].some((process) => process.chromium));
  if (mode === 'hold') return !gap && session !== '0' && samples.some((sample) =>
    [...sample.processes.values()].some((process) =>
      process.session === session && process.gpu && process.fdOwner));
  throw new Error('invalid observation check');
}

if (require.main === module) {
  try {
    const [mode, file, session] = process.argv.slice(2);
    process.exitCode = check(fs.readFileSync(file, 'utf8'), mode, session) ? 0 : 1;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = {VERSION, parseSamples, check};

'use strict';

const fs = require('node:fs');

function parseSamples(text) {
  const samples = [];
  let sample;
  for (const line of text.trim().split('\n')) {
    const fields = line.split('\t');
    const [kind, id] = fields;
    if (kind === 'BEGIN') {
      if (sample || fields.length !== 4 || !/^[a-f0-9]{32}$/.test(id) ||
          !/^pid:\[[0-9]+\]$/.test(fields[2]) || !/^\d+$/.test(fields[3]))
        throw new Error('invalid observation header');
      sample = {id, session: fields[3], processes: new Map(), owners: []};
      continue;
    }
    if (!sample || id !== sample.id) throw new Error('cross-sample observation');
    if (kind === 'P') {
      if (fields.length !== 8 || !fields.slice(2, 5).every((value) => /^\d+$/.test(value)) ||
          !fields.slice(5).every((value) => /^[01]$/.test(value)) || sample.processes.has(fields[2]))
        throw new Error('invalid process observation');
      sample.processes.set(fields[2], {start: fields[3], session: fields[4],
        gpu: fields[5] === '1', profile: fields[6] === '1', chromium: fields[7] === '1'});
    } else if (kind === 'O') {
      if (fields.length !== 4) throw new Error('invalid owner observation');
      sample.owners.push({pid: fields[2], start: fields[3]});
    } else if (kind === 'END') {
      if (fields.length !== 2 || sample.owners.some((owner) =>
        sample.processes.get(owner.pid)?.start !== owner.start)) throw new Error('unobserved owner');
      samples.push(sample);
      sample = undefined;
    } else throw new Error('unknown observation record');
  }
  if (sample || samples.length === 0) throw new Error('incomplete observation');
  return samples;
}

function check(text, mode, session = '0') {
  const samples = parseSamples(text);
  if (samples.some((sample) => sample.session !== session)) return false;
  if (mode === 'complete') return true;
  if (mode === 'idle') return samples.every((sample) => sample.owners.length === 0);
  if (mode === 'preflight') return samples.every((sample) => sample.owners.length === 0 &&
    ![...sample.processes.values()].some((process) => process.chromium));
  if (mode === 'hold') return session !== '0' && samples.some((sample) => sample.owners.some((owner) => {
    const process = sample.processes.get(owner.pid);
    return process.session === session && process.gpu;
  }));
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

module.exports = {parseSamples, check};

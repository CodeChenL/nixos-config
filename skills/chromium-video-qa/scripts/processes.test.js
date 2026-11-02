'use strict';

const assert = require('node:assert/strict');
const {test} = require('node:test');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

const guard = path.join(__dirname, 'remote-guard.sh');
const sample = 'a'.repeat(32);
const begin = `BEGIN\t${sample}\t11111111-2222-4333-8444-555555555555\tpid:[1]\t1000\t321\n`;
const end = `END\t${sample}\n`;

function evaluate(lines, session) {
  const stream = ['ROOTLESS_OBSERVATION_V1', begin, ...lines, end].join('\n') + '\n';
  return spawnSync('bash', ['-c',
    'source "$1"; shift; evaluate_processes "$1"', 'qa-processes', guard, session],
  {input: stream, encoding: 'utf8', timeout: 3000});
}

test('run-owned or unclassifiable opacity blocks removal', () => {
  const runOwned = evaluate(
      [`P\t${sample}\t123\t500\t1\t0\t321\t1\t0\t1\t0`, `U\t${sample}\t123\tfd-unreadable`], '321');
  const unclassified = evaluate([`U\t${sample}\t99997\tcmdline-unreadable`], '321');

  assert.equal(runOwned.status, 3, runOwned.stderr);
  assert.equal(unclassified.status, 3, unclassified.stderr);
});

test('external and device opacity do not block removal', () => {
  const external = evaluate(
      [`P\t${sample}\t200\t700\t1\t0\t7\t0\t0\t0\t0`, `U\t${sample}\t200\tfd-unreadable`], '321');
  const device = evaluate([`U\t${sample}\t0\tdevice-unreadable`], '321');

  assert.equal(external.status, 0, external.stderr);
  assert.equal(external.stdout.trim(), '');
  assert.equal(device.status, 0, device.stderr);
});

test('visible run-owned processes are still reported to the caller', () => {
  const bySession = evaluate([`P\t${sample}\t123\t500\t1\t0\t321\t0\t1\t0\t1`], '321');
  const byProfile = evaluate([`P\t${sample}\t124\t600\t1\t0\t7\t1\t1\t0\t1`], '321');

  assert.equal(bySession.status, 0, bySession.stderr);
  assert.equal(bySession.stdout.trim(), '123');
  assert.equal(byProfile.status, 0, byProfile.stderr);
  assert.equal(byProfile.stdout.trim(), '124');
});

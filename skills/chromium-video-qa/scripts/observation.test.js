'use strict';

const assert = require('node:assert/strict');
const {test} = require('node:test');
const {spawnSync} = require('node:child_process');
const path = require('node:path');
const {check} = require('./check-observation');

const sample = 'a'.repeat(32);
const prefix = `BEGIN\t${sample}\tpid:[1]\t321\n`;
const suffix = `END\t${sample}\n`;
const processRow = `P\t${sample}\t123\t500\t321\t1\t0\t0\n`;
const ownerRow = `O\t${sample}\t123\t500\n`;

test('same-sample GPU child without profile/name passes only the HOLD gate', () => {
  assert.equal(check(prefix + processRow + ownerRow + suffix, 'hold', '321'), true);
});

test('same-session non-GPU owner fails HOLD', () => {
  const row = `P\t${sample}\t123\t500\t321\t0\t1\t1\n`;
  assert.equal(check(prefix + row + ownerRow + suffix, 'hold', '321'), false);
});

test('owner with reused PID but different start time is rejected', () => {
  assert.throws(() => check(prefix + processRow + ownerRow.replace('500', '501') + suffix, 'hold', '321'));
});

test('membership in a different sample cannot justify an owner', () => {
  const next = 'b'.repeat(32);
  const text = prefix + processRow + suffix + `BEGIN\t${next}\tpid:[1]\t321\n` +
    `O\t${next}\t123\t500\nEND\t${next}\n`;
  assert.throws(() => check(text, 'hold', '321'));
});

test('missing complete marker never establishes an empty device baseline', () => {
  assert.throws(() => check(prefix + processRow, 'idle', '321'));
});

test('environment authority claims do not bypass privileged observer CLI', () => {
  const result = spawnSync('python3', ['-I', '-B', path.join(__dirname, 'observer.py'),
    'snapshot', 'pid:[1]', '-', '0', '-'], {
    encoding: 'utf8', timeout: 3000,
    env: {...process.env, OBSERVER_TRUSTED: '1', OBSERVER_HELPER: '/bin/true', PROC_ROOT: '/tmp'},
  });
  assert.equal(result.status, 3, result.stderr);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /UNKNOWN/);
});

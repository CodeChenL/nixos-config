'use strict';

const assert = require('node:assert/strict');
const {test} = require('node:test');
const {check, parseSamples} = require('./check-observation');

const sample = 'a'.repeat(32);
const boot = '11111111-2222-4333-8444-555555555555';
const version = 'ROOTLESS_OBSERVATION_V1\n';
const prefix = `${version}BEGIN\t${sample}\t${boot}\tpid:[4026531836]\t1000\t321\n`;
const suffix = `END\t${sample}\n`;
const browserRow = `P\t${sample}\t122\t400\t1\t100\t321\t1\t0\t1\t0\n`;
const gpuOwnerRow = `P\t${sample}\t123\t500\t122\t400\t321\t0\t1\t0\t1\n`;

test('ROOTLESS_OBSERVATION_V1 binds run and process ownership fields', () => {
  const [parsed] = parseSamples(prefix + browserRow + gpuOwnerRow + suffix);
  assert.deepEqual({boot: parsed.boot, namespace: parsed.namespace, uid: parsed.uid,
    session: parsed.session}, {boot, namespace: 'pid:[4026531836]', uid: '1000', session: '321'});
  assert.deepEqual(parsed.processes.get('123'), {start: '500', parent: '122',
    parentStart: '400', session: '321', profile: false, gpu: true,
    chromium: false, fdOwner: true});
});

test('same-sample run-session GPU fd owner establishes HW path observation', () => {
  assert.equal(check(prefix + browserRow + gpuOwnerRow + suffix, 'hold', '321'), true);
});

test('same-session non-GPU fd owner does not establish HW path observation', () => {
  const row = gpuOwnerRow.replace('\t1\t0\t1\n', '\t0\t0\t1\n');
  assert.equal(check(prefix + browserRow + row + suffix, 'hold', '321'), false);
});

test('fd owner in another session does not establish HW path observation', () => {
  const row = gpuOwnerRow.replace('\t321\t0\t1\t0\t1\n', '\t7\t0\t1\t0\t1\n');
  assert.equal(check(prefix + browserRow + row + suffix, 'hold', '321'), false);
});

test('PID reuse inside one sample is rejected', () => {
  const reused = gpuOwnerRow.replace('\t500\t', '\t501\t');
  assert.throws(() => parseSamples(prefix + gpuOwnerRow + reused + suffix), /duplicate process/);
});

test('mismatched parent start identity is rejected', () => {
  const wrongParent = gpuOwnerRow.replace('\t122\t400\t', '\t122\t401\t');
  assert.throws(() => parseSamples(prefix + browserRow + wrongParent + suffix), /parent identity/);
});

test('unclassifiable opacity blocks monitor completeness but not the preflight scan', () => {
  const unknown = `U\t${sample}\t99997\tcmdline-unreadable\n`;
  assert.equal(check(prefix + unknown + suffix, 'complete', '321'), false);
  const preflight = prefix.replace('\t321\n', '\t0\n');
  assert.equal(check(preflight + unknown + suffix, 'preflight', '0'), true);
});

test('external process opacity is a recorded gap and does not block observation', () => {
  const external =
    `P\t${sample}\t200\t700\t1\t0\t7\t0\t0\t0\t0\nU\t${sample}\t200\tfd-unreadable\n`;
  const text = prefix + browserRow + gpuOwnerRow + external + suffix;
  assert.equal(check(text, 'complete', '321'), true);
  assert.equal(check(text, 'hold', '321'), true);
  const preflight = prefix.replace('\t321\n', '\t0\n');
  assert.equal(check(preflight + external + suffix, 'preflight', '0'), true);
});

test('run-session opacity blocks completeness and hardware observation', () => {
  const runOpaque = `U\t${sample}\t123\tfd-unreadable\n`;
  const text = prefix + browserRow + gpuOwnerRow + runOpaque + suffix;
  assert.equal(check(text, 'complete', '321'), false);
  assert.equal(check(text, 'hold', '321'), false);
});

test('device opacity blocks every observation mode', () => {
  const device = `U\t${sample}\t0\tdevice-unreadable\n`;
  const text = prefix + gpuOwnerRow + device + suffix;
  assert.equal(check(text, 'complete', '321'), false);
  assert.equal(check(text, 'hold', '321'), false);
  assert.equal(check(text, 'visible-idle', '321'), false);
  const preflight = prefix.replace('\t321\n', '\t0\n');
  assert.equal(check(preflight + device + suffix, 'preflight', '0'), false);
});

test('visible pre-existing Chromium or fd owner blocks preflight', () => {
  const preflight = prefix.replace('\t321\n', '\t0\n');
  assert.equal(check(preflight + browserRow + suffix, 'preflight', '0'), false);
  assert.equal(check(preflight + gpuOwnerRow + suffix, 'preflight', '0'), false);
});

test('missing END never establishes a complete rootless sample', () => {
  assert.throws(() => check(prefix + gpuOwnerRow, 'complete', '321'), /incomplete observation/);
});

test('monitor samples from another boot cannot be combined', () => {
  const second = (prefix + suffix).replaceAll(sample, 'b'.repeat(32))
      .replace(boot, 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee');
  assert.equal(check(prefix + suffix + second, 'complete', '321'), false);
});

test('old authoritative observer schema is rejected', () => {
  assert.throws(() => parseSamples(`OBSERVER_V1\nBEGIN\t${sample}\tpid:[1]\t321\nEND\t${sample}\n`),
      /ROOTLESS_OBSERVATION_V1/);
});

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const modulePath = path.join(__dirname, '..', 'assets', 'telemetry.js');
assert.equal(fs.existsSync(modulePath), true, 'telemetry implementation is missing');
const {metricState, createReporter, shouldRenderFrame} = require(modulePath);

test('quality telemetry distinguishes API unavailable, null, zero, and nonzero', () => {
  // Given / When / Then
  assert.deepEqual(metricState(undefined, false), {state: 'unavailable', value: null});
  assert.deepEqual(metricState(null, true), {state: 'null', value: null});
  assert.deepEqual(metricState(0, true), {state: 'zero', value: 0});
  assert.deepEqual(metricState(3, true), {state: 'nonzero', value: 3});
});

test('result reporter posts exactly once despite duplicate terminal events', async () => {
  // Given
  const calls = [];
  const report = createReporter(async (...args) => { calls.push(args); });

  // When
  await Promise.all([report('/result/token', {state: 'ended'}), report('/result/token', {state: 'ended'})]);

  // Then
  assert.equal(calls.length, 1);
});

test('performance profile throttles frame-triggered DOM rendering', () => {
  // Given / When / Then
  assert.equal(shouldRenderFrame('performance', 1000, 1500), false);
  assert.equal(shouldRenderFrame('performance', 1000, 2000), true);
  assert.equal(shouldRenderFrame('evidence', 1000, 1001), true);
});

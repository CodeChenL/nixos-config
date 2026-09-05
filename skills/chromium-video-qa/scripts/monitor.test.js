'use strict';

const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn} = require('node:child_process');
const {check} = require('./check-observation');

test('TERM drains an in-flight observer sample without fabricating UNKNOWN', {timeout: 5000}, async () => {
  const state = fs.mkdtempSync(path.join(os.tmpdir(), 'qa-monitor-stop-'));
  const transport = path.join(state, 'transport.js');
  fs.writeFileSync(transport, `
    const fs = require('node:fs');
    const state = process.argv[2];
    const watcher = fs.watch(state, () => {
      if (fs.existsSync(state + '/release')) {
        console.log('BEGIN\\t${'a'.repeat(32)}\\tpid:[1]\\t321\\nEND\\t${'a'.repeat(32)}');
        watcher.close();
      }
    });
    fs.writeFileSync(state + '/started', 'yes');
  `);
  let watcher;
  const started = new Promise((resolve) => {
    watcher = fs.watch(state, () => { if (fs.existsSync(state + '/started')) resolve(); });
  });
  const child = spawn('setsid', ['bash', path.join(__dirname, 'monitor-observer.sh'), '10',
    'mock', 'a'.repeat(32), '/tmp/chromium-video-qa.ABCDEF123456', '/dev/video0',
    process.execPath, transport, state]);
  let output = '';
  let errors = '';
  child.stdout.on('data', (data) => { output += data; });
  child.stderr.on('data', (data) => { errors += data; });
  const closed = new Promise((resolve) => child.on('close', (code, signal) => resolve({code, signal})));
  try {
    await started;
    child.kill('SIGTERM');
    fs.writeFileSync(path.join(state, 'release'), 'yes');
    assert.deepEqual(await closed, {code: 0, signal: null}, errors);
    assert.equal(check(output, 'complete', '321'), true);
  } finally {
    watcher.close();
    try { process.kill(-child.pid, 'SIGTERM'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    fs.rmSync(state, {recursive: true, force: true});
  }
});

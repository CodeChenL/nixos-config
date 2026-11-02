'use strict';

const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const {spawn} = require('node:child_process');

async function runScenario(extra = {}) {
  const state = fs.mkdtempSync(path.join(os.tmpdir(), 'qa-mock-'));
  const bin = path.join(state, 'bin');
  fs.mkdirSync(bin);
  for (const tool of ['ssh', 'scp', 'driver']) {
    fs.writeFileSync(path.join(bin, tool), `#!/bin/sh\nexec '${process.execPath}' '${__dirname}/mock-transport.js' '${tool}' "$@"\n`, {mode: 0o700});
  }
  fs.writeFileSync(path.join(state, 'media.mp4'), 'not a real video');
  let remoteRoot;
  try {
    const inherited = {...process.env};
    for (const key of ['REMOTE_ROOT', 'CDP_REMOTE_PORT', 'SSHPASS', 'CHROMIUM_EXTRA_FLAGS']) delete inherited[key];
    const child = spawn('bash', [path.join(__dirname, 'run-scenario.sh'),
      'case', 'full', path.join(state, 'media.mp4'), '-', '-', '-', '8', '-', extra.QA_MOCK_HOLD || '0'], {
      env: {...inherited, PATH: bin + ':' + process.env.PATH,
        QA_MOCK_STATE: state, TARGET_HOST: 'mock', TARGET_USER: 'test',
        CHROMIUM_BIN: '/mock/chromium', XDG_RUNTIME_DIR_REMOTE: '/mock/runtime',
        RUNTIME_STATUS_REMOTE: '-', NODE_BIN: path.join(bin, 'driver'),
        OUTPUT_DIR: state, CDP_LOCAL_PORT: '0', CDP_WAIT_SECONDS: '1',
        ...extra},
      timeout: 10000,
    });
    let stderr = '';
    child.stderr.on('data', (data) => { stderr += data; });
    child.stdout.resume();
    const code = await new Promise((resolve, reject) => {
      child.on('error', reject);
      child.on('close', resolve);
    });
    if (fs.existsSync(path.join(state, 'root')))
      remoteRoot = fs.readFileSync(path.join(state, 'root'), 'utf8');
    const read = (name) => fs.existsSync(path.join(state, name)) ? fs.readFileSync(path.join(state, name), 'utf8') : '';
    return {code, stderr, result: read('case-result.tsv'), calls: read('ssh-calls'),
      monitorErrors: read('case-monitor.stderr'), monitor: read('case-monitor.log'),
      driverRan: !!read('driver-ran'), closeRan: !!read('close-ran'),
      remoteRemoved: remoteRoot && !fs.existsSync(remoteRoot)};
  } finally {
    if (!remoteRoot && fs.existsSync(path.join(state, 'root')))
      remoteRoot = fs.readFileSync(path.join(state, 'root'), 'utf8');
    if (remoteRoot && fs.existsSync(remoteRoot)) fs.rmSync(remoteRoot, {recursive: true});
    fs.rmSync(state, {recursive: true, force: true});
  }
}

async function availablePort() {
  const server = http.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return String(port);
}

test('preflight existing Chromium aborts without create or remove', async () => {
  const result = await runScenario({QA_MOCK_PREEXISTING: '1'});
  assert.equal(result.code, 3, result.stderr);
  assert.doesNotMatch(result.calls, /-- (create|remove) /);
});

for (const baseline of ['busy', 'error', 'missing', 'transport', 'empty-success']) {
  test('preflight device ' + baseline + ' blocks without directory creation', async () => {
    const result = await runScenario({QA_MOCK_BASELINE: baseline});
    assert.equal(result.code, 3, result.stderr);
    assert.doesNotMatch(result.calls, /-- (create|remove) /);
  });
}

test('occupied local CDP port never reaches unrelated browser or driver', async () => {
  let requests = 0;
  const server = http.createServer((_request, response) => { requests++; response.end('{}'); });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const result = await runScenario({CDP_LOCAL_PORT: String(server.address().port)});
    assert.equal(result.code, 4, result.stderr);
    assert.equal(result.driverRan, false);
    assert.equal(requests, 0);
    assert.equal(server.listening, true);
    assert.equal(result.remoteRemoved, true);
  } finally { await new Promise((resolve) => server.close(resolve)); }
});

test('identity change before Browser.close retains browser and owned directory', async () => {
  const result = await runScenario({CDP_LOCAL_PORT: await availablePort(),
    QA_MOCK_VALIDATE_FAILURE: '1'});
  assert.equal(result.code, 1, result.stderr);
  assert.match(result.result, /\tOWNED_CLEANUP_FAIL\tGLOBAL_IDLE_UNKNOWN\tOVERALL_FAIL\t/);
  assert.equal(result.remoteRemoved, false);
  assert.equal(result.closeRan, false);
});

test('playback failure is an overall failure even when owned cleanup succeeds', async () => {
  const result = await runScenario({CDP_LOCAL_PORT: await availablePort(), QA_MOCK_DRIVER_FAIL: '1'});
  assert.match(result.result,
      /\tPLAYBACK_FAIL\tHW_PATH_OBSERVED\tOWNED_CLEANUP_PASS\tGLOBAL_IDLE_UNKNOWN\tOVERALL_FAIL\t/);
});

test('browser-unsupported media is reported as UNSUPPORTED instead of FAIL', async () => {
  const result = await runScenario({CDP_LOCAL_PORT: await availablePort(),
    QA_MOCK_UNSUPPORTED: '1', QA_MOCK_LOG: 'v4l2_stateful_video_decoder.cc'});

  assert.equal(result.code, 1, result.stderr);
  assert.match(result.result,
      /\tPLAYBACK_UNSUPPORTED\tHW_PATH_NOT_OBSERVED\tOWNED_CLEANUP_PASS\tGLOBAL_IDLE_UNKNOWN\tOVERALL_UNSUPPORTED\t/);
  assert.equal(result.remoteRemoved, true);
});

for (const [name, log, overall] of [
  ['init-only', 'v4l2_stateful_video_decoder.cc initialize format:PIXEL_FORMAT_NV12', 'OVERALL_INCONCLUSIVE_ROOTLESS'],
  ['software-fallback', 'v4l2_stateful_video_decoder.cc initialize\nFFmpegVideoDecoder software fallback', 'OVERALL_FAIL'],
  ['wrong-format', 'v4l2_stateful_video_decoder.cc\nERROR pixel format mismatch', 'OVERALL_FAIL'],
  ['no-output', 'v4l2_stateful_video_decoder.cc Chosen CAPTURE format; no dequeue', 'OVERALL_INCONCLUSIVE_ROOTLESS'],
  ['unverified-output-text', 'v4l2_stateful_video_decoder.cc CAPTURE dequeue output frame format:PIXEL_FORMAT_NV12', 'OVERALL_INCONCLUSIVE_ROOTLESS'],
]) {
  test(name + ' cannot PASS despite successful playback mock', async () => {
    const result = await runScenario({CDP_LOCAL_PORT: await availablePort(), QA_MOCK_LOG: log});
    assert.equal(result.code, 1, result.stderr);
    assert.match(result.result, new RegExp(`\\tPLAYBACK_PASS\\tHW_PATH_(?:OBSERVED|FAIL)\\t` +
        `OWNED_CLEANUP_PASS\\tGLOBAL_IDLE_UNKNOWN\\t${overall}\\t`),
    result.stderr + result.monitorErrors + result.monitor);
    assert.equal(result.driverRan, true);
    assert.equal(result.remoteRemoved, true);
  });
}

for (const device of ['busy', 'error', 'missing', 'transport', 'empty-success']) {
  test('postclose device ' + device + ' fails without killing owner', async () => {
    const result = await runScenario({CDP_LOCAL_PORT: await availablePort(),
      QA_MOCK_LOG: 'v4l2_stateful_video_decoder.cc', QA_MOCK_DEVICE: device});
    assert.match(result.result, /\tOWNED_CLEANUP_FAIL\tGLOBAL_IDLE_UNKNOWN\tOVERALL_FAIL\t/);
    assert.equal(result.code, 1, result.stderr);
    assert.doesNotMatch(result.calls, /kill -|fuser -k/);
  });
}

test('remaining run process fails teardown', async () => {
  const result = await runScenario({CDP_LOCAL_PORT: await availablePort(),
    QA_MOCK_LOG: 'v4l2_stateful_video_decoder.cc', QA_MOCK_REMAIN: '1'});
  assert.match(result.result, /\tOWNED_CLEANUP_FAIL\tGLOBAL_IDLE_UNKNOWN\tOVERALL_FAIL\t/);
});

test('refused cleanup preserves directory and records FAIL', async () => {
  const result = await runScenario({CDP_LOCAL_PORT: await availablePort(),
    QA_MOCK_LOG: 'v4l2_stateful_video_decoder.cc', QA_MOCK_REMOVE_FAILURE: '1'});
  assert.match(result.result, /\tOWNED_CLEANUP_FAIL\tGLOBAL_IDLE_UNKNOWN\tOVERALL_FAIL\t/);
  assert.equal(result.remoteRemoved, false);
  assert.match(result.stderr, /cleanup refused/);
});

test('unreadable external processes do not block rootless launch', async () => {
  const result = await runScenario({CDP_LOCAL_PORT: await availablePort(),
    QA_MOCK_OBSERVER: 'external-fd', QA_MOCK_LOG: 'v4l2_stateful_video_decoder.cc'});
  assert.equal(result.code, 1, result.stderr);
  assert.equal(result.driverRan, true);
  assert.match(result.result, /\tGLOBAL_IDLE_UNKNOWN\tOVERALL_INCONCLUSIVE_ROOTLESS\t/);
  assert.equal(result.remoteRemoved, true);
});

test('external monitor opacity keeps hardware observation intact', async () => {
  const result = await runScenario({CDP_LOCAL_PORT: await availablePort(),
    QA_MOCK_HOLD: '1', QA_MOCK_MONITOR_EXTERNAL: '1',
    QA_MOCK_LOG: 'v4l2_stateful_video_decoder.cc'});
  assert.match(result.result,
      /\tHW_PATH_OBSERVED\tOWNED_CLEANUP_PASS\tGLOBAL_IDLE_UNKNOWN\tOVERALL_INCONCLUSIVE_ROOTLESS\t/);
  assert.equal(result.remoteRemoved, true);
});

test('external postclose opacity does not block owned cleanup', async () => {
  const result = await runScenario({CDP_LOCAL_PORT: await availablePort(),
    QA_MOCK_POST_EXTERNAL: '1', QA_MOCK_LOG: 'v4l2_stateful_video_decoder.cc'});
  assert.match(result.result,
      /\tOWNED_CLEANUP_PASS\tGLOBAL_IDLE_UNKNOWN\tOVERALL_INCONCLUSIVE_ROOTLESS\t/);
  assert.equal(result.remoteRemoved, true);
});

for (const owner of ['gpu-child', 'outsider', 'none', 'stale-sample']) {
  test('HOLD session correlation: ' + owner, async () => {
    const result = await runScenario({CDP_LOCAL_PORT: await availablePort(), QA_MOCK_HOLD: '1',
      QA_MOCK_OWNER: owner, QA_MOCK_LOG: 'v4l2_stateful_video_decoder.cc'});
    const malformed = owner === 'stale-sample';
    assert.match(result.result, owner === 'gpu-child' ? /\tHW_PATH_OBSERVED\t/ :
      malformed ? /\tHW_PATH_UNKNOWN\t/ : /\tHW_PATH_NOT_OBSERVED\t/);
    assert.match(result.result, malformed ? /\tGLOBAL_IDLE_UNKNOWN\tOVERALL_FAIL\t/ :
      /\tGLOBAL_IDLE_UNKNOWN\tOVERALL_INCONCLUSIVE_ROOTLESS\t/);
  });
}

test('owned process becomes opaque after close: refuses deletion and reports FAIL', async () => {
  const result = await runScenario({CDP_LOCAL_PORT: await availablePort(),
    QA_MOCK_POST_OBSERVER: 'process-opaque', QA_MOCK_LOG: 'v4l2_stateful_video_decoder.cc'});
  assert.match(result.result, /\tOWNED_CLEANUP_FAIL\tGLOBAL_IDLE_UNKNOWN\tOVERALL_FAIL\t/);
  assert.equal(result.remoteRemoved, false);
  assert.match(result.stderr, /remained|opaque/);
});

test('opaque run sample retains evidence directory even if later process scan is readable', async () => {
  const result = await runScenario({CDP_LOCAL_PORT: await availablePort(),
    QA_MOCK_MONITOR_OPAQUE: '1'});
  assert.match(result.result, /\tHW_PATH_UNKNOWN\tOWNED_CLEANUP_FAIL\tGLOBAL_IDLE_UNKNOWN\tOVERALL_FAIL\t/);
  assert.equal(result.remoteRemoved, false);
});

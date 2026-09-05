'use strict';

const assert = require('node:assert/strict');
const {test, after} = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const {spawn, spawnSync} = require('node:child_process');
const {once} = require('node:events');
const {readIdentity, ownedEndpoint, closeOwned} = require('./browser-ownership');
const {fakeCdp} = require('./fake-cdp');

const token = 'a'.repeat(32);
const mockBin = fs.mkdtempSync(path.join(os.tmpdir(), 'qa-observer-mock-'));
fs.writeFileSync(path.join(mockBin, 'sudo'), `#!/bin/sh\nexec '${process.execPath}' '${__dirname}/mock-observer.js' "$@"\n`, {mode: 0o700});
after(() => fs.rmSync(mockBin, {recursive: true, force: true}));
const guard = (action, root, owner = token) => spawnSync('bash', [
  path.join(__dirname, 'remote-guard.sh'), action, owner, root || '',
], {encoding: 'utf8', timeout: 3000, env: {...process.env, PATH: mockBin + ':' + process.env.PATH}});
const profile = '/tmp/chromium-video-qa.ABCDEF123456/profile';
const url = 'file://' + profile.slice(0, -7) + 'video-qa.html?run=' + token;
const identity = readIdentity({QA_EXPECTED_URL: url, QA_PROFILE: profile,
  QA_RUN_TOKEN: token, QA_BROWSER_PATH: '/devtools/browser/test-owned'});

test('preexisting, traversal and mismatched owner directories survive cleanup', () => {
  const existing = fs.mkdtempSync('/tmp/chromium-video-qa.legacy');
  const root = guard('create').stdout.trim();
  try {
    fs.writeFileSync(path.join(existing, 'sentinel'), 'keep');
    assert.notEqual(guard('remove', existing).status, 0);
    assert.notEqual(guard('remove', root + '/../' + path.basename(existing)).status, 0);
    assert.notEqual(guard('remove', root, 'b'.repeat(32)).status, 0);
    assert.equal(fs.readFileSync(path.join(existing, 'sentinel'), 'utf8'), 'keep');
    assert.equal(fs.existsSync(root), true);
    assert.equal(guard('remove', root).status, 0);
    assert.equal(fs.existsSync(root), false);
  } finally {
    fs.rmSync(existing, {recursive: true, force: true});
    if (root) guard('remove', root);
  }
});

test('symlinked owner marker cannot authorize removal', () => {
  const root = guard('create').stdout.trim();
  try {
    fs.renameSync(root + '/.owner', root + '/saved');
    fs.symlinkSync(root + '/saved', root + '/.owner');
    assert.notEqual(guard('remove', root).status, 0);
    assert.equal(fs.existsSync(root), true);
    fs.unlinkSync(root + '/.owner');
    fs.renameSync(root + '/saved', root + '/.owner');
  } finally { guard('remove', root); }
});

test('opaque privileged observer refuses deletion despite an empty unprivileged view', () => {
  const root = guard('create').stdout.trim();
  try {
    const result = spawnSync('bash', [path.join(__dirname, 'remote-guard.sh'), 'remove', token, root], {
      encoding: 'utf8', timeout: 3000,
      env: {...process.env, PATH: mockBin + ':' + process.env.PATH, QA_MOCK_OBSERVER: 'hidden-process'},
    });
    assert.equal(result.status, 3);
    assert.equal(fs.existsSync(root), true);
  } finally { guard('remove', root); }
});

test('unsafe overrides abort before SSH and preserve preexisting directories', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'qa-abort-'));
  try {
    const media = path.join(root, 'media.mp4');
    fs.writeFileSync(media, 'fixture');
    for (const override of [root, '/tmp/chromium-video-qa.x/../' + path.basename(root)]) {
      const result = spawnSync('bash', [path.join(__dirname, 'run-scenario.sh'),
        'test', 'full', media, '-', '-', '-', '8', '-', '0'], {
        encoding: 'utf8', timeout: 3000,
        env: {...process.env, TARGET_HOST: 'must-not-be-contacted.invalid', REMOTE_ROOT: override},
      });
      assert.equal(result.status, 2, result.stderr);
      assert.match(result.stderr, /overrides are not allowed/);
      assert.equal(fs.readFileSync(media, 'utf8'), 'fixture');
    }
  } finally { fs.rmSync(root, {recursive: true, force: true}); }
});

test('local fake CDP version endpoint rejects a different browser ID', async () => {
  let calls = 0;
  const server = http.createServer((_request, response) => {
    calls++;
    response.setHeader('Content-Type', 'application/json');
    response.end(JSON.stringify({webSocketDebuggerUrl: 'ws://127.0.0.1:1/devtools/browser/unrelated'}));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    await assert.rejects(ownedEndpoint('http://127.0.0.1:' + server.address().port, identity), /identity mismatch/);
    assert.equal(calls, 1);
  } finally { await new Promise((resolve) => server.close(resolve)); }
});

test('live exact-profile process prevents removal without killing process', async () => {
  const root = guard('create').stdout.trim();
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)', '--', '--user-data-dir=' + root + '/profile']);
  await once(child, 'spawn');
  try {
    assert.equal(guard('remove', root).status, 3);
    assert.equal(fs.existsSync(root), true);
    assert.equal(child.exitCode, null);
  } finally {
    const closed = once(child, 'close');
    child.kill();
    await closed;
    assert.equal(guard('remove', root).status, 0);
  }
});

test('uncertain launch state cannot authorize deletion', () => {
  const root = guard('create').stdout.trim();
  try {
    assert.equal(guard('arm', root).status, 0);
    assert.equal(guard('remove', root).status, 3);
    fs.writeFileSync(root + '/.session', 'not-a-session');
    assert.equal(guard('remove', root).status, 3);
    assert.equal(fs.existsSync(root), true);
  } finally {
    fs.rmSync(root + '/.launch-pending', {force: true});
    fs.rmSync(root + '/.session', {force: true});
    guard('remove', root);
  }
});

test('session member without profile argument prevents removal', {timeout: 5000}, async () => {
  const root = guard('create').stdout.trim();
  const child = spawn('setsid', ['bash', '-c',
    'printf "%s\\n" "$$" > "$1/.session"; exec "$2" -e "setInterval(() => {}, 1000)"',
    'qa-test', root, process.execPath]);
  await once(child, 'spawn');
  try {
    for (let attempt = 0; attempt < 50 && !fs.existsSync(root + '/.session'); attempt++)
      await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(fs.existsSync(root + '/.session'), true);
    assert.equal(guard('remove', root).status, 3);
    assert.equal(child.exitCode, null);
  } finally {
    const closed = once(child, 'close');
    child.kill();
    await closed;
    assert.equal(guard('remove', root).status, 0);
  }
});

for (const variant of ['owned', 'wrong-profile', 'substring-url', 'duplicate-page', 'navigated', 'missing-commandline']) {
  test('local WebSocket CDP close ownership gate: ' + variant, {timeout: 5000}, async () => {
    const args = ['--enable-automation', '--user-data-dir=' + profile, url];
    if (variant === 'wrong-profile') args[1] += '-other';
    let pages = [{url: () => url}];
    if (variant === 'substring-url') pages = [{url: () => url + '&other=1'}];
    if (variant === 'duplicate-page') pages.push({url: () => url});
    if (variant === 'navigated') pages = [{url: () => 'https://example.invalid/'}];
    const cdp = await fakeCdp(identity, args, pages, variant === 'missing-commandline');
    try {
      const endpoint = await ownedEndpoint(cdp.base, identity);
      const {browser, session} = await cdp.connect(endpoint);
      if (variant === 'owned') await closeOwned(browser, session, identity);
      else await assert.rejects(closeOwned(browser, session, identity));
      assert.equal(cdp.commands.includes('Browser.close'), variant === 'owned');
      assert.equal(cdp.disconnected(), true);
    } finally { await cdp.stop(); }
  });
}

'use strict';

const assert = require('node:assert/strict');
const {test} = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

const guard = path.join(__dirname, 'remote-guard.sh');

function scan(descriptors, deviceId) {
  const state = fs.mkdtempSync(path.join(os.tmpdir(), 'qa-scan-'));
  const fddir = path.join(state, 'fd');
  fs.mkdirSync(fddir);
  descriptors.forEach((target, index) => fs.symlinkSync(target, path.join(fddir, String(index))));
  const result = spawnSync('bash', ['-c', `
    source "$1"
    scan_descriptors "$2" "$3"
    printf '%s\\t%s\\n' "$descriptor_owner" "$descriptor_opacity"
  `, 'qa-scan', guard, fddir, deviceId], {encoding: 'utf8', timeout: 3000});
  return {result, state};
}

function deviceIdentity(target) {
  return spawnSync('stat', ['-Lc', '%t:%T', target], {encoding: 'utf8'}).stdout.trim();
}

test('real self descriptors are transparent for an unrelated device identity', () => {
  const result = spawnSync('bash', ['-c', `
    source "$1"
    scan_descriptors /proc/self/fd ffff:ffff
    printf '%s\\t%s\\n' "$descriptor_owner" "$descriptor_opacity"
  `, 'qa-scan', guard], {encoding: 'utf8', timeout: 3000});

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), '0\t0');
});

test('character device fds match only the requested major and minor identity', () => {
  const nullIdentity = deviceIdentity('/dev/null');
  const match = scan(['/dev/null'], nullIdentity);
  const mismatch = scan(['/dev/null'], 'ffff:ffff');
  try {
    assert.equal(match.result.status, 0, match.result.stderr);
    assert.equal(match.result.stdout.trim(), '1\t0');
    assert.equal(mismatch.result.status, 0, mismatch.result.stderr);
    assert.equal(mismatch.result.stdout.trim(), '0\t0');
  } finally {
    fs.rmSync(match.state, {recursive: true, force: true});
    fs.rmSync(mismatch.state, {recursive: true, force: true});
  }
});

test('vanished descriptors are ignored while present unreadable ones are opaque', () => {
  const state = fs.mkdtempSync(path.join(os.tmpdir(), 'qa-scan-'));
  const fddir = path.join(state, 'fd');
  const secret = path.join(state, 'secret');
  fs.mkdirSync(fddir);
  fs.mkdirSync(secret);
  fs.writeFileSync(path.join(secret, 'hidden'), 'x');
  fs.symlinkSync(path.join(state, 'missing'), path.join(fddir, '0'));
  fs.symlinkSync(path.join(secret, 'hidden'), path.join(fddir, '1'));
  fs.chmodSync(secret, 0o000);
  try {
    const result = spawnSync('bash', ['-c', `
      source "$1"
      scan_descriptors "$2" ffff:ffff
      printf '%s\\t%s\\n' "$descriptor_owner" "$descriptor_opacity"
    `, 'qa-scan', guard, fddir], {encoding: 'utf8', timeout: 3000});

    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), '0\t1');
  } finally {
    fs.chmodSync(secret, 0o700);
    fs.rmSync(state, {recursive: true, force: true});
  }
});

function split(assignments) {
  return spawnSync('bash', ['-c', `
    source "$1"
    ${assignments}
    split_words
    printf '%s\\n' "\${process_words[@]}"
  `, 'qa-split', guard], {encoding: 'utf8', timeout: 3000});
}

test('single-element argv rewrite is matched as words', () => {
  const result = split(
      'process_args=( "/x/chromium --user-data-dir=/tmp/chromium-video-qa.ABCDEF123456/profile --type=gpu-process" )');

  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.stdout.trim().split('\n'),
      ['/x/chromium', '--user-data-dir=/tmp/chromium-video-qa.ABCDEF123456/profile',
        '--type=gpu-process']);
});

test('normal nul-separated argv is preserved', () => {
  const result = split('process_args=( "/x/chromium" "--type=gpu-process" )');

  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.stdout.trim().split('\n'), ['/x/chromium', '--type=gpu-process']);
});

test('snapshot tolerates a naturally exited run while validate still refuses', () => {
  const token = 'b'.repeat(32);
  const root = '/tmp/chromium-video-qa.' + require('node:crypto').randomBytes(6).toString('hex');
  fs.mkdirSync(root, {mode: 0o700});
  fs.mkdirSync(root + '/profile');
  fs.writeFileSync(root + '/.owner', token + '\n');
  const boot = fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim();
  fs.writeFileSync(root + '/.browser-identity',
      `ROOTLESS_RUN_V1\t${boot}\t2147483647\t500\t2147483647\t${token}\t${root}/profile\n`);
  try {
    const snapshot = spawnSync('bash', [guard, 'snapshot', token, root], {encoding: 'utf8', timeout: 5000});
    assert.equal(snapshot.status, 0, snapshot.stderr);
    assert.match(snapshot.stdout, /^ROOTLESS_OBSERVATION_V1\n/);

    const validate = spawnSync('bash', [guard, 'validate', token, root], {encoding: 'utf8', timeout: 5000});
    assert.equal(validate.status, 3);
  } finally {
    fs.rmSync(root, {recursive: true, force: true});
  }
});

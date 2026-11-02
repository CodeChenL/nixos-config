'use strict';

const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const [tool, ...args] = process.argv.slice(2);
const state = process.env.QA_MOCK_STATE;
if (!state) throw new Error('test transport requires QA_MOCK_STATE');
const last = args.at(-1);
const readRoot = () => fs.readFileSync(path.join(state, 'root'), 'utf8').trim();

function observation(session, phase) {
  const counterFile = path.join(state, 'sample-counter');
  const counter = fs.existsSync(counterFile) ? Number(fs.readFileSync(counterFile, 'utf8')) + 1 : 1;
  fs.writeFileSync(counterFile, String(counter));
  const sample = counter.toString(16).padStart(32, '0');
  const rows = ['ROOTLESS_OBSERVATION_V1',
    `BEGIN\t${sample}\t11111111-2222-4333-8444-555555555555\tpid:[1]\t1000\t${session}`];
  const processRow = (pid, processSession, profile, gpu, chromium, owner) =>
    `P\t${sample}\t${pid}\t500\t122\t400\t${processSession}\t${profile}\t${gpu}\t${chromium}\t${owner}`;
  if (phase === 'preflight') {
    const baseline = process.env.QA_MOCK_BASELINE;
    if (baseline === 'missing') rows.push(`U\t${sample}\t0\tdevice-unreadable`);
    if (baseline === 'busy') rows.push(processRow('99999', '7', '0', '0', '0', '1'));
    if (process.env.QA_MOCK_PREEXISTING === '1')
      rows.push(processRow('99998', '7', '0', '0', '1', '0'));
    if (process.env.QA_MOCK_OBSERVER === 'process-opaque')
      rows.push(`U\t${sample}\t99997\tcmdline-unreadable`);
    if (process.env.QA_MOCK_OBSERVER === 'external-fd') {
      rows.push(processRow('99997', '7', '0', '0', '0', '0'));
      rows.push(`U\t${sample}\t99997\tfd-unreadable`);
    }
  } else if (phase === 'monitor') {
    const variant = process.env.QA_MOCK_OWNER || 'gpu-child';
    const ownerSession = variant === 'outsider' ? '7' : session;
    if (variant === 'stale-sample') {
      rows.push(processRow('99996', ownerSession, '0', '1', '0', '0'));
      rows.push(`P\t${'b'.repeat(32)}\t99997\t501\t122\t400\t${session}\t0\t1\t0\t1`);
    } else {
      rows.push(processRow('99996', ownerSession, '0', '1', '0', variant === 'none' ? '0' : '1'));
    }
    if (process.env.QA_MOCK_MONITOR_OPAQUE === '1')
      rows.push(`U\t${sample}\t99993\tfd-unreadable`);
    if (process.env.QA_MOCK_MONITOR_EXTERNAL === '1') {
      rows.push(processRow('99993', '7', '0', '0', '0', '0'));
      rows.push(`U\t${sample}\t99993\tfd-unreadable`);
    }
    fs.writeFileSync(path.join(state, 'monitor-sampled'), 'yes');
  } else {
    const status = process.env.QA_MOCK_DEVICE;
    if (status === 'missing') rows.push(`U\t${sample}\t0\tdevice-unreadable`);
    if (status === 'busy') rows.push(processRow('99995', '7', '0', '0', '0', '1'));
    if (process.env.QA_MOCK_POST_OBSERVER === 'process-opaque')
      rows.push(`U\t${sample}\t99994\tstat-unreadable`);
    if (process.env.QA_MOCK_POST_EXTERNAL === '1') {
      rows.push(processRow('99994', '7', '0', '0', '0', '0'));
      rows.push(`U\t${sample}\t99994\tfd-unreadable`);
    }
  }
  rows.push(`END\t${sample}`);
  return rows.join('\n') + '\n';
}

if (tool === 'driver') {
  if (args[0].endsWith('/drive-video-qa.js')) {
    for (let attempt = 0; attempt < 100 && !fs.existsSync(path.join(state, 'monitor-sampled')); attempt++)
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    fs.writeFileSync(path.join(state, 'driver-ran'), 'yes');
    if (process.env.QA_MOCK_UNSUPPORTED === '1') {
      fs.writeFileSync(args[1] + '-qa.json',
          JSON.stringify({state: 'media-error', error: '4'}) + '\n');
      process.exitCode = 1;
    } else {
      console.log(JSON.stringify({qa: {state: 'ended', totalVideoFrames: 10}}));
      if (process.env.QA_MOCK_DRIVER_FAIL === '1') process.exitCode = 1;
    }
  } else if (args[0].endsWith('/close-owned-browser.js')) {
    fs.writeFileSync(path.join(state, 'close-ran'), 'yes');
  } else {
    const result = spawnSync(process.execPath, args, {stdio: 'inherit'});
    process.exitCode = result.status;
  }
} else if (tool === 'scp') {
  const [source, destination] = args.slice(-2).map((arg) => arg.replace(/^.*@mock:/, ''));
  fs.copyFileSync(source, destination);
} else if (tool === 'ssh') {
  fs.appendFileSync(path.join(state, 'ssh-calls'), JSON.stringify(args) + '\n');
  if (args.includes('-N')) {
    if (!args.includes('ExitOnForwardFailure=yes')) throw new Error('missing forward safety option');
    const port = Number(args[args.indexOf('-L') + 1].split(':')[1]);
    const socket = args[args.indexOf('-S') + 1];
    const server = http.createServer((_request, response) => {
      response.end(JSON.stringify({webSocketDebuggerUrl: 'ws://127.0.0.1/devtools/browser/mock'}));
    });
    server.on('error', () => process.exit(255));
    server.listen(port, '127.0.0.1', () => fs.writeFileSync(socket, 'ready'));
  } else if (args.includes('-O')) {
    process.exitCode = fs.existsSync(args[args.indexOf('-S') + 1]) ? 0 : 255;
  } else if (last.startsWith('bash -s --')) {
    fs.readFileSync(0, 'utf8');
    const parts = last.split(' ');
    const action = parts[3];
    const token = parts[4];
    if (action === 'preflight') {
      const status = process.env.QA_MOCK_BASELINE;
      if (status === 'error') console.error('rootless observation failed');
      if (status === 'error') process.exitCode = 3;
      else if (status === 'transport') process.exitCode = 255;
      else if (status !== 'empty-success') process.stdout.write(observation('0', 'preflight'));
    } else if (action === 'create') {
      const root = '/tmp/chromium-video-qa.' + crypto.randomBytes(6).toString('hex');
      fs.mkdirSync(root, {mode: 0o700});
      fs.mkdirSync(path.join(root, 'profile'));
      fs.mkdirSync(path.join(root, 'media'));
      fs.writeFileSync(path.join(root, '.owner'), token + '\n');
      fs.writeFileSync(path.join(state, 'root'), root);
      console.log(root);
    } else if (action === 'ready') {
      process.stdout.write('12345\n/devtools/browser/mock\n');
    } else if (action === 'session') {
      console.log('2147483647');
    } else if (action === 'snapshot') {
      const postclose = fs.existsSync(path.join(state, 'close-ran'));
      const status = postclose ? process.env.QA_MOCK_DEVICE : undefined;
      if (status === 'error') console.error('rootless observation failed');
      if (status === 'error') process.exitCode = 3;
      else if (status === 'transport') process.exitCode = 255;
      else if (status !== 'empty-success')
        process.stdout.write(observation('2147483647', postclose ? 'postclose' : 'monitor'));
    } else if (action === 'processes') {
      if (process.env.QA_MOCK_REMAIN === '1') console.log('99999');
      if (process.env.QA_MOCK_POST_OBSERVER === 'process-opaque') process.exitCode = 3;
    } else if (action === 'validate') {
      if (process.env.QA_MOCK_VALIDATE_FAILURE === '1') process.exitCode = 3;
    } else if (action === 'remove') {
      if (process.env.QA_MOCK_REMOVE_FAILURE === '1' ||
          process.env.QA_MOCK_POST_OBSERVER === 'process-opaque' ||
          process.env.QA_MOCK_VALIDATE_FAILURE === '1' ||
          process.env.QA_MOCK_MONITOR_OPAQUE === '1') process.exitCode = 3;
      else fs.rmSync(readRoot(), {recursive: true});
    }
  } else if (last.startsWith('test -x ')) {
    process.exitCode = 0;
  } else if (last.startsWith('nohup setsid bash')) {
    const syntax = spawnSync('bash', ['-n', '-c', last]);
    if (syntax.status !== 0) throw new Error('invalid launch shell syntax');
    fs.writeFileSync(readRoot() + '/case-chromium.log', process.env.QA_MOCK_LOG || '');
    console.log('99998');
  } else if (last.startsWith('timeout ')) {
    process.exitCode = 0;
  } else throw new Error('unrecognized mock SSH command: ' + last);
} else throw new Error('unrecognized test tool');

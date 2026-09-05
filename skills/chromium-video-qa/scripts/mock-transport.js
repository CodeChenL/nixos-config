'use strict';

const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const {spawnSync} = require('node:child_process');
const [tool, ...args] = process.argv.slice(2);
const state = process.env.QA_MOCK_STATE;
if (!state) throw new Error('test transport requires QA_MOCK_STATE');
const last = args.at(-1);
const readRoot = () => fs.readFileSync(path.join(state, 'root'), 'utf8').trim();

if (tool === 'driver') {
  if (args[0].endsWith('/drive-video-qa.js')) {
    for (let attempt = 0; attempt < 100 && !fs.existsSync(path.join(state, 'monitor-sampled')); attempt++)
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
    fs.writeFileSync(path.join(state, 'driver-ran'), 'yes');
    console.log(JSON.stringify({qa: {state: 'ended', totalVideoFrames: 10}}));
  } else {
    const result = spawnSync(process.execPath, args, {stdio: 'inherit'});
    process.exitCode = result.status;
  }
} else if (tool === 'sudo') {
  const result = spawnSync(process.execPath, [path.join(__dirname, 'mock-observer.js'), ...args], {stdio: 'inherit'});
  process.exitCode = result.status;
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
    const script = fs.readFileSync(0, 'utf8');
    if (last.includes('-- ready ')) {
      process.stdout.write('12345\n/devtools/browser/mock\n');
    } else if (last.includes('-- remove ') && process.env.QA_MOCK_REMOVE_FAILURE === '1') {
      process.exitCode = 3;
    } else {
      const result = spawnSync('bash', ['-c', last], {input: script, encoding: 'utf8'});
      if (last.includes('-- create ') && result.status === 0)
        fs.writeFileSync(path.join(state, 'root'), result.stdout.trim());
      process.stdout.write(result.stdout);
      process.stderr.write(result.stderr);
      process.exitCode = result.status;
    }
  } else if (last.startsWith('test -x ')) {
    process.exitCode = 0;
  } else if (last.startsWith('sudo -n -- /usr/local/libexec/chromium-qa-observer snapshot')) {
    const result = spawnSync('bash', ['-c', last], {stdio: 'inherit'});
    process.exitCode = result.status;
  } else if (last.startsWith('nohup setsid bash')) {
    const syntax = spawnSync('bash', ['-n', '-c', last]);
    if (syntax.status !== 0) throw new Error('invalid launch shell syntax');
    fs.writeFileSync(readRoot() + '/.session', '2147483647');
    fs.writeFileSync(readRoot() + '/case-chromium.log', process.env.QA_MOCK_LOG || '');
    console.log('99998');
  } else if (last.startsWith('timeout ')) {
    process.exitCode = 0;
  } else throw new Error('unrecognized mock SSH command: ' + last);
} else throw new Error('unrecognized test tool');

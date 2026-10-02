'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const dgram = require('node:dgram');
const tls = require('node:tls');
const { isUtf8 } = require('node:buffer');
const { randomBytes } = require('node:crypto');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');
const { performance } = require('node:perf_hooks');

async function readPassword(input = process.stdin) {
  const chunks = [];
  let length = 0;
  const timer = setTimeout(() => input.destroy(new Error('读取 STDIN 测试密码超过 5 秒')), 5000);
  try {
    for await (const chunk of input) {
      const bytes = Buffer.from(chunk);
      length += bytes.length;
      assert(length <= 256, 'STDIN 测试密码最多为 255 个 UTF-8 字节及一个末尾换行');
      chunks.push(bytes);
    }
    const bytes = Buffer.concat(chunks);
    const password = bytes.at(-1) === 10 ? bytes.subarray(0, -1) : bytes;
    assert(password.length > 0 && password.length <= 255 && isUtf8(password)
      && !password.includes(0) && !password.includes(13) && !password.includes(10),
    'STDIN 必须只有一行非空 UTF-8 测试密码，最多 255 字节，不能包含 NUL、CR 或额外换行');
    return password.toString('utf8');
  } finally { clearTimeout(timer); }
}

function createFixture(password) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mixed-proxy-test-'));
  fs.chmodSync(directory, 0o700);
  const cwd = path.join(directory, 'work');
  const home = path.join(directory, 'home');
  for (const folder of [cwd, home]) fs.mkdirSync(folder, { mode: 0o700 });
  const processes = [];
  const servers = new Set();
  const sockets = new Set();
  const datagrams = new Set();
  const cancellation = new AbortController();
  const signal = cancellation.signal;
  const interrupt = () => cancellation.abort(new Error('测试被信号中断'));
  process.on('SIGINT', interrupt);
  process.on('SIGTERM', interrupt);
  const deadline = setTimeout(() => cancellation.abort(new Error('测试超过 90 秒')), 90000);
  const wrongPassword = password === 'wrong-fixture-password' ? 'another-wrong-fixture-password' : 'wrong-fixture-password';
  const marker = randomBytes(18).toString('hex');
  const secrets = [password, wrongPassword, Buffer.from(`chen:${password}`).toString('base64'),
    Buffer.from(`wrong-fixture-user:${password}`).toString('base64'), Buffer.from(`chen:${wrongPassword}`).toString('base64')];
  const redact = (text) => secrets.reduce((output, secret) => output.split(secret).join('[REDACTED]'), String(text));

  function launch(binary, arguments_, bounded = false, input) {
    signal.throwIfAborted();
    const child = spawn(binary, arguments_, {
      cwd, env: { ...process.env, HOME: home }, detached: true,
      stdio: [input === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'], signal,
      ...(bounded ? { timeout: 20000, killSignal: 'SIGKILL' } : {}),
    });
    const record = { child, binary, stdout: '', stderr: '', error: null, stopped: false };
    child.stdout.on('data', (data) => { record.stdout = (record.stdout + data).slice(-65536); });
    child.stderr.on('data', (data) => { record.stderr = (record.stderr + data).slice(-65536); });
    child.on('error', (error) => { record.error = new Error(redact(error.message)); });
    record.done = new Promise((resolve) => child.once('close', (code, childSignal) => {
      record.finished = true;
      resolve({ code, signal: childSignal });
    }));
    if (input !== undefined) {
      child.stdin.on('error', (error) => { record.error = new Error(redact(error.message)); });
      child.stdin.end(input);
    }
    processes.push(record);
    return record;
  }

  async function command(binary, arguments_, input) {
    const record = launch(binary, arguments_, true, input);
    const result = await record.done;
    signal.throwIfAborted();
    if (record.error) throw record.error;
    return { code: result.code, stdout: redact(record.stdout), stderr: redact(record.stderr) };
  }

  async function stop(record) {
    if (record.stopped || record.finished || !record.child.pid) return;
    const killGroup = (childSignal) => {
      try { process.kill(-record.child.pid, childSignal); }
      catch (error) { if (error.code !== 'ESRCH') throw error; }
    };
    killGroup('SIGTERM');
    let timer;
    const finished = await Promise.race([record.done.then(() => true),
      new Promise((resolve) => { timer = setTimeout(() => resolve(false), 1500); })]);
    clearTimeout(timer);
    if (!finished) { killGroup('SIGKILL'); await record.done; }
    record.stopped = true;
  }

  function track(socket) {
    sockets.add(socket);
    socket.on('error', () => {});
    socket.once('close', () => sockets.delete(socket));
    return socket;
  }

  async function listen(server) {
    servers.add(server);
    server.on('connection', track);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening', { signal });
    return server.address().port;
  }

  async function closeServer(server) {
    if (server.listening) await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    servers.delete(server);
  }

  async function bindUdp(host = '127.0.0.1', port = 0) {
    const socket = dgram.createSocket('udp4');
    socket.bind(port, host);
    try { await once(socket, 'listening', { signal }); }
    catch (error) { socket.close(); throw error; }
    socket.on('error', (error) => cancellation.abort(error));
    datagrams.add(socket);
    socket.once('close', () => datagrams.delete(socket));
    return socket;
  }

  async function closeUdp(socket) {
    if (datagrams.has(socket)) await new Promise((resolve) => socket.close(resolve));
  }

  async function reserveUdpRange() {
    for (let attempt = 0; attempt < 16; attempt++) {
      const leases = [await bindUdp()];
      const min = leases[0].address().port;
      try {
        if (min > 65532) continue;
        for (let port = min + 1; port < min + 4; port++) leases.push(await bindUdp('127.0.0.1', port));
        return { min, max: min + 3, leases };
      } catch (error) {
        if (error.code !== 'EADDRINUSE') throw error;
      } finally {
        if (leases.length !== 4) await Promise.all(leases.map(closeUdp));
      }
    }
    throw new Error('未找到可用的本地 UDP 连续端口范围');
  }

  async function connection(port, { secure = false, localAddress = '127.0.0.1' } = {}) {
    const options = { host: '127.0.0.1', port, localAddress, signal };
    const socket = track(secure ? tls.connect({ ...options, servername: 'api.chenjaly.cn',
      ca: fs.readFileSync(path.join(directory, 'proxy.pem')) }) : net.createConnection(options));
    socket.setNoDelay(true);
    socket.setTimeout(2000, () => socket.destroy(new Error('连接响应超过 2 秒')));
    try { await once(socket, secure ? 'secureConnect' : 'connect', { signal }); return socket; }
    catch (error) { socket.destroy(); throw error; }
  }

  async function ready(record, port) {
    const limit = performance.now() + 5000;
    while (performance.now() < limit) {
      signal.throwIfAborted();
      if (record.finished) throw new Error(`${record.binary} 提前退出: ${redact(record.stderr)}`);
      try { const socket = await connection(port); socket.destroy(); return; }
      catch (error) { if (error.code !== 'ECONNREFUSED') throw error; }
      await delay(25, undefined, { signal });
    }
    throw new Error(`${record.binary} 未开始监听 ${port}: ${redact(record.stderr)}`);
  }

  function assertCaches() {
    assert.deepEqual(fs.readdirSync(cwd), []);
    assert.deepEqual(fs.readdirSync(home), [], '子进程不得向隔离的 HOME 写入 TLS 缓存');
  }

  function assertLogs(binary) {
    for (const record of processes.filter((process_) => process_.binary === binary)) {
      const output = record.stdout + record.stderr;
      for (const secret of secrets) assert.equal(output.includes(secret), false, '代理日志泄漏了认证凭据');
    }
  }

  async function cleanup() {
    clearTimeout(deadline);
    process.removeListener('SIGINT', interrupt);
    process.removeListener('SIGTERM', interrupt);
    const results = await Promise.allSettled(processes.filter((record) => !record.finished).map(stop));
    for (const socket of sockets) socket.destroy();
    results.push(...await Promise.allSettled([...datagrams].map(closeUdp)));
    results.push(...await Promise.allSettled([...servers].map(closeServer)));
    const errors = results.filter((result) => result.status === 'rejected').map((result) => result.reason);
    fs.rmSync(directory, { recursive: true, force: true });
    if (errors.length) throw new AggregateError(errors, '临时资源清理失败');
    console.log('CLEANUP PASS: 本次子进程、TCP/UDP 监听器及临时 HOME、证书、配置已清理');
  }

  return { directory, password, wrongPassword, marker, signal, processes, redact, launch, command, stop, listen,
    closeServer, bindUdp, closeUdp, reserveUdpRange, connection, ready, assertCaches, assertLogs, cleanup };
}

module.exports = { createFixture, readPassword };

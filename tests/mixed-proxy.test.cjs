'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const net = require('node:net');
const os = require('node:os');
const { loadConfig, writeConfig } = require('./mixed-proxy/config.cjs');
const { createFixture, readPassword } = require('./mixed-proxy/fixture.cjs');
const { createEndpoints } = require('./mixed-proxy/endpoints.cjs');
const { certificate, certificateCases } = require('./mixed-proxy/certificates.cjs');
const { createCurl, authenticationCases, httpCases, socksCases } = require('./mixed-proxy/cases.cjs');
const { udpCases } = require('./mixed-proxy/udp-cases.cjs');

const usage = '用法: node tests/mixed-proxy.test.cjs <Rust 二进制> <生成的 JSON>\nSTDIN: 一行隔离 VM 的合成 chen 密码，非空且最多 255 个 UTF-8 字节，不得包含 NUL 或 CR。\n依赖: Node.js 22+、curl（HTTPS-proxy）、openssl；仅在隔离 VM 内以 chen 用户运行，目标均为本机回环地址。\n范围: 通过真实客户端协议验证 Rust 原生 PAM、TLS 与 SOCKS5 TCP/UDP；账户策略、systemd 与 ACME 另由 VM 场景验证。';
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--help') {
  console.log(usage);
} else if (args.length !== 2) {
  console.error(usage);
  process.exitCode = 2;
} else {
  readPassword().then((password) => main(args, password), () => {
    console.error('STDIN 必须在 5 秒内结束，且仅含一行非空测试密码，最多 255 个 UTF-8 字节，禁止 NUL、CR 或额外换行');
    process.exitCode = 2;
  }).catch((error) => { console.error(error.stack); process.exitCode = 1; });
}

async function main([proxyArgument, generatedJson], password) {
  assert(process.getuid() !== 0, '此测试必须由普通用户运行');
  assert.equal(os.userInfo().username, 'chen', '此测试必须由隔离 VM 的 chen 用户运行');
  const proxyBin = path.resolve(proxyArgument);
  const loaded = loadConfig(generatedJson);
  const fixture = createFixture(password);
  let passed = 0;
  async function check(name, operation) {
    const detail = await operation();
    console.log(`PASS ${name}${detail ? ` (${detail})` : ''}`);
    passed++;
  }

  try {
    const version = await fixture.command(proxyBin, ['--version']);
    assert.equal(version.code, 0, version.stderr);
    assert.equal(version.stdout.trim(), 'mixed-proxy 0.1.0');
    const curlVersion = await fixture.command('curl', ['--disable', '--version']);
    assert.equal(curlVersion.code, 0, curlVersion.stderr);
    assert.match(curlVersion.stdout, /HTTPS-proxy/);
    await certificate(fixture, 'proxy', 1);
    await certificate(fixture, 'target', 2);
    const endpoints = await createEndpoints(fixture);
    const lease = net.createServer();
    const front = await fixture.listen(lease);
    const ports = { front, udp: await fixture.reserveUdpRange() };
    const config = writeConfig(fixture, loaded, ports);
    console.log(`生成配置: ${path.resolve(generatedJson)}`);
    console.log(`临时夹具: ${fixture.directory} ; 回环端口: ${front}`);
    console.log('Node 范围: Rust 原生 PAM、单端口 TLS 与 SOCKS5 TCP/UDP；合成密码仅通过客户端协议发送。');
    await fixture.closeServer(lease);
    await Promise.all(ports.udp.leases.map(fixture.closeUdp));
    let proxy = fixture.launch(proxyBin, ['--config', config]);
    await fixture.ready(proxy, front);
    const curl = createCurl(fixture, endpoints, ports);
    const context = { fixture, endpoints, ports, check, curl, restartProxy: async (publicAddress = '127.0.0.1') => {
      await fixture.stop(proxy);
      writeConfig(fixture, loaded, { ...ports, udp: { ...ports.udp, publicAddress } });
      proxy = fixture.launch(proxyBin, ['--config', config]);
      await fixture.ready(proxy, front);
    } };
    await authenticationCases(context);
    await httpCases(context);
    await socksCases(context);
    await udpCases(context);
    await certificateCases(context);
    assert.equal(proxy.finished, undefined, fixture.redact(proxy.stderr));
    await fixture.stop(proxy);
    await check('显式 TLS 未向隔离 HOME/CWD 写入文件', async () => fixture.assertCaches());
    await check('代理进程日志未包含认证密码或 Basic 凭据', async () => fixture.assertLogs(proxyBin));
  } catch (error) {
    for (const record of fixture.processes.filter((record) => record.binary === proxyBin)) {
      console.error(`${record.binary}:\n${fixture.redact(record.stdout + record.stderr)}`);
    }
    throw new Error(fixture.redact(error.stack));
  } finally { await fixture.cleanup(); }
  console.log(`PASS: ${passed} 项；已通过客户端协议验证 Rust 原生 PAM；逐请求后端调用与失败分支由 Rust 测试覆盖，账户策略、systemd 与 ACME 由 VM 场景另行验证。`);
}

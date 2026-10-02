'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const https = require('node:https');
const net = require('node:net');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const { openControl } = require('./socks.cjs');

function createCurl(fixture, endpoints, ports) {
  return async function curl(proxy, scheme, extra = []) {
    const options = [];
    let input;
    for (let index = 0; index < extra.length; index++) {
      if (extra[index] === '--proxy-user') {
        const credentials = extra[++index].replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\t', '\\t');
        input = `proxy-user = "${credentials}"\n`;
      } else options.push(extra[index]);
    }
    const result = await fixture.command('curl', ['--disable', '--silent', '--show-error',
      '--noproxy', '', '--connect-timeout', '12', '--max-time', '15',
      '--proxy', proxy === 'https' ? `https://api.chenjaly.cn:${ports.front}` : `socks5h://127.0.0.1:${ports.front}`,
      ...(proxy === 'https' ? ['--resolve', `api.chenjaly.cn:${ports.front}:127.0.0.1`,
        '--proxy-cacert', path.join(fixture.directory, 'proxy.pem')] : ['--socks5-basic']),
      '--cacert', path.join(fixture.directory, 'target.pem'), '--write-out', '\n%{http_code} %{http_connect}',
      ...(input === undefined ? [] : ['--config', '-']), ...options,
      '--url', `${scheme}://127.0.0.1:${scheme === 'http' ? endpoints.httpPort : endpoints.httpsPort}/mixed-proxy-fixture`], input);
    const split = result.stdout.lastIndexOf('\n');
    return { ...result, body: result.stdout.slice(0, split),
      status: result.stdout.slice(split + 1).split(' ').map(Number) };
  };
}

async function authenticationCases({ fixture, endpoints, check, curl, ports }) {
  const authentication = ['--proxy-user', `chen:${fixture.password}`];
  for (const proxy of ['https', 'socks5h']) {
    for (const scheme of ['http', 'https']) {
      await check(`${proxy} 正确认证 ${scheme === 'http' ? 'HTTP 转发' : 'HTTPS CONNECT'}、TLS 校验`, async () => {
        const before = endpoints.targetRequests;
        const result = await curl(proxy, scheme, authentication);
        assert.equal(result.code, 0, result.stderr);
        assert.equal(result.status[0], 200);
        if (proxy === 'https' && scheme === 'https') assert.equal(result.status[1], 200);
        assert.equal(result.body, `${fixture.marker} GET /mixed-proxy-fixture`);
        assert.equal(endpoints.targetRequests, before + 1);
      });
      for (const [label, auth] of [['无凭据', []], ['错误密码', ['--proxy-user', `chen:${fixture.wrongPassword}`]],
        ['错误用户名', ['--proxy-user', `wrong-fixture-user:${fixture.password}`]]]) {
        await check(`${proxy} ${scheme} ${label} 拒绝且不访问目标`, async () => {
          const before = endpoints.targetRequests;
          const result = await curl(proxy, scheme, auth);
          if (proxy === 'https') {
            assert([401, 407].includes(result.status[scheme === 'http' ? 0 : 1]), JSON.stringify(result));
            if (scheme === 'http') assert.equal(result.code, 0, result.stderr);
            else assert.notEqual(result.code, 0, result.stderr);
          } else {
            assert.equal(result.code, 97, result.stderr);
            assert.match(result.stderr, /SOCKS5|authentication|user/i);
          }
          assert.equal(endpoints.targetRequests, before);
          assert.equal(result.body.includes(fixture.marker), false);
        });
      }
    }
  }
  await check('HTTPS 代理主机名不匹配时 TLS 校验失败', async () => {
    const before = endpoints.targetRequests;
    const result = await curl('https', 'http', [...authentication,
      '--proxy', `https://wrong-proxy.invalid:${ports.front}`,
      '--resolve', `wrong-proxy.invalid:${ports.front}:127.0.0.1`]);
    assert.equal(result.code, 60, result.stderr);
    assert.match(result.stderr, /certificate|subject|alternative/i);
    assert.equal(endpoints.targetRequests, before);
  });
}

function createHttpClient(fixture, endpoints, ports, localAddress = '127.0.0.1') {
  const agent = new https.Agent({ keepAlive: true, maxSockets: 1, localAddress });
  async function request({ headers = {}, method = 'GET', chunks = [], pathname = '/mixed-proxy-fixture' } = {}) {
    let connection;
    const outgoing = https.request({ hostname: '127.0.0.1', port: ports.front,
      servername: 'api.chenjaly.cn', ca: fs.readFileSync(path.join(fixture.directory, 'proxy.pem')),
      agent, method, path: `http://127.0.0.1:${endpoints.httpPort}${pathname}`,
      headers: { Host: `127.0.0.1:${endpoints.httpPort}`, ...headers }, signal: fixture.signal });
    outgoing.on('socket', (socket) => { connection = socket; });
    outgoing.setTimeout(15000, () => outgoing.destroy(new Error('HTTPS 代理请求超过 15 秒')));
    const response = new Promise((resolve, reject) => {
      outgoing.once('error', reject);
      outgoing.once('response', async (incoming) => {
        try {
          const body = [];
          for await (const chunk of incoming) body.push(chunk);
          resolve({ status: incoming.statusCode, headers: incoming.headers,
            body: Buffer.concat(body).toString('utf8'), socket: connection });
        } catch (error) { reject(error); }
      });
    });
    const send = async () => {
      for (const [index, chunk] of chunks.entries()) {
        if (index) await delay(25, undefined, { signal: fixture.signal });
        outgoing.write(chunk);
      }
      outgoing.end();
    };
    try {
      const [result] = await Promise.all([response, send()]);
      return result;
    } catch (error) { outgoing.destroy(); throw error; }
  }
  return { request, close() { agent.destroy(); } };
}

async function httpCases({ fixture, endpoints, ports, check }) {
  const authorization = `Basic ${Buffer.from(`chen:${fixture.password}`).toString('base64')}`;
  await check('HTTPS 代理流式 POST 保留请求体与业务头且不向目标泄漏 Proxy-Authorization', async () => {
    const client = createHttpClient(fixture, endpoints, ports);
    const chunks = [Buffer.from(`${fixture.marker} first\n`), Buffer.from([0, 1, 2, 255]), Buffer.from(' last')];
    const before = endpoints.targetRequests;
    try {
      const response = await client.request({ method: 'POST', chunks,
        headers: { 'Proxy-Authorization': authorization, 'X-Fixture': fixture.marker,
          'Content-Type': 'application/octet-stream' } });
      assert.equal(response.status, 200);
      assert.equal(response.body, `${fixture.marker} POST /mixed-proxy-fixture`);
      assert.equal(endpoints.targetRequests, before + 1);
      const target = endpoints.targetMessages.at(-1);
      assert.deepEqual(target.body, Buffer.concat(chunks));
      assert.equal(target.headers['x-fixture'], fixture.marker);
      assert.equal(target.headers['content-type'], 'application/octet-stream');
      assert.equal(target.headers['proxy-authorization'], undefined);
      assert.equal(target.rawHeaders.some((header) => /^proxy-authorization$/i.test(header)), false);
    } finally { client.close(); }
  });

  await check('持久 HTTPS 连接逐请求认证：同连接后续请求仍认证，缺失或错误凭据拒绝', async () => {
    const client = createHttpClient(fixture, endpoints, ports);
    let connection;
    let previousAllowed = false;
    try {
      for (const [credential, allowed] of [[authorization, true], [authorization, true], [undefined, false],
        [`Basic ${Buffer.from(`chen:${fixture.wrongPassword}`).toString('base64')}`, false], [authorization, true]]) {
        const before = endpoints.targetRequests;
        const response = await client.request({ headers: credential ? { 'Proxy-Authorization': credential } : {} });
        if (allowed && previousAllowed) {
          assert.equal(response.socket, connection,
            `连续成功请求必须复用同一持久 TLS 连接（上一连接已销毁: ${connection.destroyed}）`);
        }
        connection = response.socket;
        previousAllowed = allowed;
        assert.equal(endpoints.targetRequests, before + Number(allowed));
        if (allowed) {
          assert.equal(response.status, 200);
          assert.equal(response.body, `${fixture.marker} GET /mixed-proxy-fixture`);
        } else {
          assert([401, 407].includes(response.status));
          assert.equal(response.body.includes(fixture.marker), false);
        }
      }
    } finally { client.close(); }
  });

  await check('TLS ClientHello 前五字节分片后仍可认证并完成 HTTP 转发', async () => {
    const bridge = net.createServer((client) => {
      client.pause();
      const connect = async () => {
        const upstream = await fixture.connection(ports.front);
        client.once('close', () => upstream.destroy());
        upstream.once('close', () => client.destroy());
        client.on('error', () => upstream.destroy());
        upstream.on('error', () => client.destroy());
        upstream.pipe(client);
        let head = Buffer.alloc(0);
        let forwarded = false;
        client.on('data', (chunk) => {
          if (forwarded) return;
          head = Buffer.concat([head, chunk]);
          if (head.length < 5) return;
          forwarded = true;
          client.pause();
          const forward = async () => {
            assert.equal(head[0], 0x16, 'TLS 流量必须以握手记录开头');
            for (let offset = 0; offset < 5; offset++) {
              upstream.write(head.subarray(offset, offset + 1));
              await delay(25, undefined, { signal: fixture.signal });
            }
            upstream.write(head.subarray(5));
            client.pipe(upstream);
            client.resume();
          };
          forward().catch((error) => { client.destroy(error); upstream.destroy(); });
        });
        client.resume();
      };
      connect().catch((error) => client.destroy(error));
    });
    const front = await fixture.listen(bridge);
    const fragmentedCurl = createCurl(fixture, endpoints, { ...ports, front });
    const before = endpoints.targetRequests;
    try {
      const result = await fragmentedCurl('https', 'http', ['--proxy-user', `chen:${fixture.password}`]);
      assert.equal(result.code, 0, result.stderr);
      assert.equal(result.status[0], 200);
      assert.equal(result.body, `${fixture.marker} GET /mixed-proxy-fixture`);
      assert.equal(endpoints.targetRequests, before + 1);
    } finally { await fixture.closeServer(bridge); }
  });
}

async function socksCases({ fixture, endpoints, ports, check }) {
  for (const chunks of [['050102'], ['05', '0102'], ['0501', '02'], ['05', '01', '02'], ['05020002']]) {
    await check(`仅发送 SOCKS5 greeting ${chunks.join(' / ')} 后等待 05 02`, async () => {
      const control = await openControl(fixture, ports.front, chunks);
      try { return `${control.elapsed.toFixed(1)}ms`; }
      finally { await control.close(); }
    });
  }
  await check('仅提供无认证 SOCKS5 方法时返回 05 FF 且不访问目标', async () => {
    const before = endpoints.targetRequests;
    const control = await openControl(fixture, ports.front, ['050100'], '127.0.0.1', 0xff);
    try {
      assert.equal(endpoints.targetRequests, before);
    } finally { await control.close(); }
  });
  await check('认证后的 BIND 返回 REP 02', async () => {
    const before = endpoints.targetRequests;
    const control = await openControl(fixture, ports.front);
    try {
      await control.authenticate();
      assert.equal((await control.request(2)).code, 2, 'BIND 必须返回 REP 02');
      assert.equal(endpoints.targetRequests, before);
    } finally { await control.close(); }
  });
}

module.exports = { createCurl, createHttpClient, authenticationCases, httpCases, socksCases };

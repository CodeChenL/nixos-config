'use strict';

const assert = require('node:assert/strict');
const { once } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');
const { performance } = require('node:perf_hooks');

function decodeAddress(buffer, type, offset) {
  let host;
  let length;
  if (type === 1) length = 4;
  else if (type === 4) length = 16;
  else {
    assert.equal(type, 3, '未知 SOCKS5 ATYP');
    assert(buffer.length > offset, 'SOCKS5 域名长度缺失');
    length = buffer[offset++];
    assert(length > 0, 'SOCKS5 域名不能为空');
  }
  assert(buffer.length >= offset + length + 2, 'SOCKS5 地址或端口帧截断');
  const address = buffer.subarray(offset, offset + length);
  if (type === 1) host = [...address].join('.');
  else if (type === 4) host = Array.from({ length: 8 }, (_unused, index) => address.readUInt16BE(index * 2).toString(16)).join(':');
  else host = address.toString('utf8');
  const port = buffer.readUInt16BE(offset + length);
  return { host, port, next: offset + length + 2 };
}

async function openControl(fixture, port, chunks = ['050102'], localAddress = '127.0.0.1', expectedMethod = 2) {
  const socket = await fixture.connection(port, { localAddress });
  const iterator = socket[Symbol.asyncIterator]();
  let buffered = Buffer.alloc(0);
  async function read(count) {
    const timer = setTimeout(() => socket.destroy(new Error('SOCKS5 完整帧超过 2 秒')), 2000);
    try {
      while (buffered.length < count) {
        const chunk = await iterator.next();
        assert.equal(chunk.done, false, 'SOCKS5 在完整响应前关闭连接');
        buffered = Buffer.concat([buffered, chunk.value]);
      }
      const result = buffered.subarray(0, count);
      buffered = buffered.subarray(count);
      return result;
    } finally { clearTimeout(timer); }
  }
  const start = performance.now();
  const timer = setTimeout(() => socket.destroy(new Error('SOCKS5 greeting 超过 1 秒')), 1000);
  let elapsed;
  try {
    for (const [index, chunk] of chunks.entries()) {
      if (index) await delay(25, undefined, { signal: fixture.signal });
      socket.write(Buffer.from(chunk, 'hex'));
    }
    assert.deepEqual(await read(2), Buffer.from([5, expectedMethod]));
    elapsed = performance.now() - start;
    assert(elapsed < 1000, `SOCKS5 greeting 耗时 ${elapsed}ms`);
    socket.setTimeout(0);
  } catch (error) { socket.destroy(); throw error; }
  finally { clearTimeout(timer); }

  async function authenticate() {
    const password = Buffer.from(fixture.password, 'utf8');
    socket.write(Buffer.concat([Buffer.from([1, 4]), Buffer.from('chen'),
      Buffer.from([password.length]), password]));
    assert.deepEqual(await read(2), Buffer.from([1, 0]));
  }

  async function request(command) {
    socket.write(Buffer.from([5, command, 0, 1, 0, 0, 0, 0, 0, 0]));
    const header = await read(4);
    assert.equal(header[0], 5);
    assert.equal(header[2], 0);
    const type = header[3];
    let prefix = Buffer.alloc(0);
    let length;
    if (type === 1) length = 4;
    else if (type === 4) length = 16;
    else {
      assert.equal(type, 3, '未知 SOCKS5 回复 ATYP');
      prefix = await read(1);
      length = prefix[0];
    }
    const address = decodeAddress(Buffer.concat([prefix, await read(length + 2)]), type, 0);
    return { code: header[1], host: address.host, port: address.port };
  }

  async function close() {
    if (socket.closed) return;
    const closed = once(socket, 'close');
    socket.destroy();
    await closed;
  }

  return { socket, elapsed, authenticate, request, close };
}

async function associate(fixture, ports, localAddress = '127.0.0.1', publicAddress = '127.0.0.1') {
  const control = await openControl(fixture, ports.front, ['050102'], localAddress);
  try {
    await control.authenticate();
    const relay = await control.request(3);
    assert.equal(relay.code, 0, 'UDP ASSOCIATE 必须成功');
    assert.equal(relay.host, publicAddress, 'UDP 必须报告重写后的回环 publicAddress');
    assert(relay.port >= ports.udp.min && relay.port <= ports.udp.max, 'UDP 必须使用重写后的端口范围');
    return { control, relay };
  } catch (error) { await control.close(); throw error; }
}

function encodeUdp(port, payload) {
  const header = Buffer.from([0, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
  header.writeUInt16BE(port, 8);
  return Buffer.concat([header, payload]);
}

function decodeUdp(packet) {
  assert(packet.length >= 4, 'SOCKS5 UDP 头截断');
  assert.equal(packet.readUInt16BE(0), 0, 'UDP RSV 必须为零');
  assert.equal(packet[2], 0, 'UDP FRAG 必须为零');
  const address = decodeAddress(packet, packet[3], 4);
  return { host: address.host, port: address.port, payload: packet.subarray(address.next) };
}

function exchangeUdp(fixture, socket, relay, packet, timeout = 1500) {
  fixture.signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const finish = (error, received) => {
      clearTimeout(timer);
      socket.removeListener('message', onMessage);
      socket.removeListener('error', onError);
      fixture.signal.removeEventListener('abort', onAbort);
      if (error) reject(error); else resolve(received);
    };
    const onMessage = (message, remote) => finish(null, { message, remote });
    const onError = (error) => finish(error);
    const onAbort = () => finish(fixture.signal.reason);
    const timer = setTimeout(() => finish(null, null), timeout);
    socket.once('message', onMessage);
    socket.once('error', onError);
    fixture.signal.addEventListener('abort', onAbort, { once: true });
    socket.send(packet, relay.port, relay.host, (error) => { if (error) finish(error); });
  });
}

module.exports = { openControl, associate, encodeUdp, decodeUdp, exchangeUdp };

'use strict';

const assert = require('node:assert/strict');
const { once } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');
const { performance } = require('node:perf_hooks');
const { openControl, associate, encodeUdp, decodeUdp, exchangeUdp } = require('./socks.cjs');

async function udpCases({ fixture, endpoints, ports, check, restartProxy }) {
  async function roundTrip(socket, relay, label) {
    const payload = Buffer.from(`${fixture.marker} ${label}`);
    const before = endpoints.echoRequests;
    const result = await exchangeUdp(fixture, socket, relay, encodeUdp(endpoints.echoPort, payload));
    assert(result, 'UDP 回包超过 1.5 秒');
    assert.equal(result.remote.address, relay.host);
    assert.equal(result.remote.port, relay.port);
    const decoded = decodeUdp(result.message);
    assert.equal(decoded.host, '127.0.0.1');
    assert.equal(decoded.port, endpoints.echoPort);
    assert.deepEqual(decoded.payload, payload);
    assert.equal(endpoints.echoRequests, before + 1);
  }

  async function noRelay(socket, relay, label, packet = encodeUdp(endpoints.echoPort, Buffer.from(`${fixture.marker} ${label}`))) {
    const before = endpoints.echoRequests;
    const result = await exchangeUdp(fixture, socket, relay, packet, 450);
    assert.equal(result, null, '禁止转发的数据报不得收到回复');
    assert.equal(endpoints.echoRequests, before, '禁止转发的数据报不得到达 echo 目标');
  }

  async function closeAssociation(association) {
    await association.control.close();
    const deadline = performance.now() + 1500;
    while (performance.now() < deadline) {
      try {
        const probe = await fixture.bindUdp(association.relay.host, association.relay.port);
        await fixture.closeUdp(probe);
        return;
      } catch (error) { if (error.code !== 'EADDRINUSE') throw error; }
      await delay(25, undefined, { signal: fixture.signal });
    }
    assert.fail('关闭 TCP 控制连接后 UDP 关联端口未释放');
  }

  await check('认证后的标准 SOCKS5 UDP ASSOCIATE 完整 echo 往返', async () => {
    const association = await associate(fixture, ports);
    const socket = await fixture.bindUdp();
    try { await roundTrip(socket, association.relay, 'round-trip'); }
    finally { await closeAssociation(association); await fixture.closeUdp(socket); }
  });

  await check('TCP 对端来源筛选：127.0.0.2 放行，127.0.0.1 丢弃且关联继续可用', async () => {
    const association = await associate(fixture, ports, '127.0.0.2');
    const good = await fixture.bindUdp('127.0.0.2');
    const bad = await fixture.bindUdp('127.0.0.1');
    try {
      await roundTrip(good, association.relay, 'source-before');
      await noRelay(bad, association.relay, 'source-rejected');
      await roundTrip(good, association.relay, 'source-after');
    } finally { await closeAssociation(association); await Promise.all([good, bad].map(fixture.closeUdp)); }
  });

  await check('首次 UDP 数据报之前关闭 TCP 控制关联即释放端口且停止转发', async () => {
    const association = await associate(fixture, ports);
    const socket = await fixture.bindUdp();
    try {
      await closeAssociation(association);
      await noRelay(socket, association.relay, 'closed-before-first-datagram');
    } finally { await closeAssociation(association); await fixture.closeUdp(socket); }
  });

  await check('UDP FRAG 与截断或未知地址类型数据报丢弃，关联继续可用', async () => {
    const association = await associate(fixture, ports);
    const socket = await fixture.bindUdp();
    try {
      const fragmented = encodeUdp(endpoints.echoPort, Buffer.from(fixture.marker));
      fragmented[2] = 1;
      for (const packet of [fragmented, Buffer.alloc(0), Buffer.from([0, 0, 0]),
        Buffer.from([0, 0, 0, 1, 127, 0, 0, 1, 0]), Buffer.from([0, 0, 0, 0xff]),
        Buffer.from([0, 0, 0, 3, 5, 97])]) {
        await noRelay(socket, association.relay, 'malformed', packet);
      }
      await roundTrip(socket, association.relay, 'after-malformed');
    } finally { await closeAssociation(association); await fixture.closeUdp(socket); }
  });

  await check('关闭 TCP 控制关联后 UDP 端口释放且停止转发', async () => {
    const association = await associate(fixture, ports);
    const socket = await fixture.bindUdp();
    try {
      await roundTrip(socket, association.relay, 'close-before');
      await closeAssociation(association);
      await noRelay(socket, association.relay, 'close-after');
    } finally { await closeAssociation(association); await fixture.closeUdp(socket); }
  });

  await check('两个 UDP 关联独立：关闭一个不会中断另一个', async () => {
    const first = await associate(fixture, ports);
    const second = await associate(fixture, ports);
    const firstSocket = await fixture.bindUdp();
    const secondSocket = await fixture.bindUdp();
    try {
      assert.notEqual(first.relay.port, second.relay.port);
      await roundTrip(firstSocket, first.relay, 'isolation-first');
      await roundTrip(secondSocket, second.relay, 'isolation-second-before');
      await closeAssociation(first);
      await noRelay(firstSocket, first.relay, 'isolation-first-closed');
      await roundTrip(secondSocket, second.relay, 'isolation-second-after');
      assert.equal(second.control.socket.destroyed, false, '第二个 TCP 控制关联必须保持连接');
    } finally {
      await Promise.all([closeAssociation(first), closeAssociation(second)]);
      await Promise.all([firstSocket, secondSocket].map(fixture.closeUdp));
    }
  });

  await check('256 个活动 UDP 目标拒绝第 257 个，真实 60 秒空闲后同一关联恢复且单向入站保活', async () => {
    const association = await associate(fixture, ports);
    const client = await fixture.bindUdp();
    const destinations = [];
    const leases = [];
    async function targetRoundTrip(target, label) {
      const payload = Buffer.from(`${fixture.marker} ${label}`);
      const result = await exchangeUdp(fixture, client, association.relay, encodeUdp(target.socket.address().port, payload));
      assert(result, '目标首包必须在同一关联上完成转发');
      assert.equal(result.remote.address, association.relay.host);
      assert.equal(result.remote.port, association.relay.port);
      const decoded = decodeUdp(result.message);
      assert.equal(decoded.host, '127.0.0.1');
      assert.equal(decoded.port, target.socket.address().port);
      assert.deepEqual(decoded.payload, payload);
    }
    try {
      for (let index = 0; index < 257; index++) {
        const socket = await fixture.bindUdp();
        const target = { socket, upstream: null, requests: 0 };
        socket.on('message', (message, remote) => {
          target.requests++;
          target.upstream = remote;
          socket.send(message, remote.port, remote.address);
        });
        destinations.push(target);
        if (index < 256) await targetRoundTrip(target, `target-${index}`);
      }
      const overflow = destinations[256];
      assert.equal(await exchangeUdp(fixture, client, association.relay,
        encodeUdp(overflow.socket.address().port, Buffer.from('rejected')), 450), null);
      await targetRoundTrip(destinations[0], 'capacity-barrier');
      assert.equal(overflow.requests, 0, '256 个活动目标必须占满真实上限');
      const active = destinations[0];
      const upstream = active.upstream;
      const expired = destinations[1].upstream;
      for (let pulse = 0; pulse < 3; pulse++) {
        await delay(20000, undefined, { signal: fixture.signal });
        const payload = Buffer.from(`${fixture.marker} inbound-only-${pulse}`);
        const received = once(client, 'message', { signal: AbortSignal.any([fixture.signal, AbortSignal.timeout(1500)]) });
        active.socket.send(payload, upstream.port, upstream.address);
        const [message, remote] = await received;
        assert.equal(remote.address, association.relay.host);
        assert.equal(remote.port, association.relay.port);
        const decoded = decodeUdp(message);
        assert.equal(decoded.port, active.socket.address().port);
        assert.deepEqual(decoded.payload, payload);
      }
      await delay(2000, undefined, { signal: fixture.signal });
      await targetRoundTrip(overflow, 'first-after-idle-expiry');
      assert.equal(overflow.requests, 1, '第 257 个目标在空闲过期后首包即被接纳');
      leases.push(await fixture.bindUdp(expired.address, expired.port));
      await targetRoundTrip(destinations[1], 'expired-recreated');
      assert.notEqual(destinations[1].upstream.port, expired.port);
      await targetRoundTrip(active, 'active-retained');
      assert.equal(active.upstream.port, upstream.port, '仅入站活动必须保留原 upstream 套接字');
      assert.equal(active.upstream.address, upstream.address);
      assert.equal(association.control.socket.destroyed, false, '全程必须保持原 TCP 控制连接');
      await closeAssociation(association);
      for (const target of [active, overflow, destinations[1]]) {
        leases.push(await fixture.bindUdp(target.upstream.address, target.upstream.port));
      }
    } finally {
      await closeAssociation(association);
      await Promise.all([client, ...destinations.map((target) => target.socket), ...leases].map(fixture.closeUdp));
    }
  });

  await check('UDP 独占完整配置范围，耗尽返回 REP 01，关闭后复用释放端口', async () => {
    const associations = [];
    const used = new Set();
    let exhausted;
    try {
      const count = ports.udp.max - ports.udp.min + 1;
      for (let index = 0; index < count; index++) {
        const association = await associate(fixture, ports);
        associations.push(association);
        assert(association.relay.port >= ports.udp.min && association.relay.port <= ports.udp.max,
          'UDP 必须在配置范围内绑定');
        assert.equal(used.has(association.relay.port), false, '每个 UDP 关联必须独占范围内端口');
        used.add(association.relay.port);
        await assert.rejects(fixture.bindUdp('127.0.0.1', association.relay.port), { code: 'EADDRINUSE' },
          '活动 UDP 关联必须独占监听端口');
      }
      assert.equal(used.size, count, '范围耗尽前必须覆盖整个端口范围');
      exhausted = await openControl(fixture, ports.front);
      await exhausted.authenticate();
      assert.equal((await exhausted.request(3)).code, 1, '范围耗尽必须返回 REP 01，禁止使用范围外端口');
      const released = associations[0].relay.port;
      await closeAssociation(associations.shift());
      const replacement = await associate(fixture, ports);
      associations.push(replacement);
      assert.equal(replacement.relay.port, released, '关闭后必须复用唯一释放的范围内端口');
      const socket = await fixture.bindUdp();
      try { await roundTrip(socket, replacement.relay, 'reused-port'); }
      finally { await fixture.closeUdp(socket); }
    } finally {
      if (exhausted) await exhausted.close();
      for (const association of associations) await closeAssociation(association);
    }
  });

  await check('UDP 报告地址可与 TCP 本地监听地址不同，实际绑定仍为 127.0.0.1', async () => {
    let association;
    let socket;
    let advertisedLease;
    try {
      await restartProxy('127.0.0.2');
      association = await associate(fixture, ports, '127.0.0.1', '127.0.0.2');
      socket = await fixture.bindUdp();
      advertisedLease = await fixture.bindUdp('127.0.0.2', association.relay.port);
      await roundTrip(socket, { ...association.relay, host: '127.0.0.1' }, 'separate-bind-address');
    } finally {
      if (association) await closeAssociation({ ...association, relay: { ...association.relay, host: '127.0.0.1' } });
      if (socket) await fixture.closeUdp(socket);
      if (advertisedLease) await fixture.closeUdp(advertisedLease);
      await restartProxy();
    }
  });
}

module.exports = { udpCases };

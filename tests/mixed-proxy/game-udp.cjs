'use strict';

const assert = require('node:assert/strict');
const { setTimeout: delay } = require('node:timers/promises');
const { performance } = require('node:perf_hooks');
const { associate, encodeUdp, exchangeUdp } = require('./socks.cjs');
const { Kind, gamePacket, createGameInbox, startGameTargets } = require('./game-fixture.cjs');

async function gameUdpCases({ fixture, ports, check }) {
  await check('游戏 UDP：双客户端大厅/对局/语音、60Hz 双向流量、突发包、NAT 换端口及断线清理', async () => {
    const clients = [];
    const inboxes = [];
    const sockets = [];
    const failures = [];
    const targets = await startGameTargets(fixture, (error) => {
      failures.push(error);
      for (const inbox of inboxes) inbox.reject(error);
    });
    async function bindClient(player, host, association) {
      const socket = await fixture.bindUdp(host);
      sockets.push(socket);
      const inbox = createGameInbox(socket, association.relay, player, fixture.signal);
      inboxes.push(inbox);
      return { socket, inbox, inputs: [], voices: [] };
    }
    async function send(client, socket, kind, sequence, value, size) {
      const packet = encodeUdp(socket.address().port, gamePacket(kind, client.player, sequence, value, size));
      await new Promise((resolve, reject) => client.current.socket.send(packet, client.association.relay.port,
        client.association.relay.host, (error) => error ? reject(error) : resolve()));
    }
    async function drain(current) {
      await Promise.all([
        current.inbox.wait(Kind.ACK, targets.matchReply.address().port, current.inputs),
        current.inbox.wait(Kind.ACK, targets.voice.address().port, current.voices),
      ]);
    }
    try {
      for (const [index, host] of ['127.0.0.2', '127.0.0.1'].entries()) {
        const player = index + 1;
        const association = await associate(fixture, ports);
        const current = await bindClient(player, host, association);
        const client = { player, host, association, current, histories: [current], expected: new Map() };
        clients.push(client);
        await send(client, targets.lobby, Kind.JOIN, 0, 0);
        await current.inbox.wait(Kind.ACK, targets.lobby.address().port, [0]);
        const welcome = current.inbox.messages.find((message) => message.packet.sequence === 0);
        assert.equal(welcome.packet.value, targets.match.address().port);
      }
      assert.notEqual(clients[0].association.relay.port, clients[1].association.relay.port);
      for (let tick = 1; tick <= 60; tick++) {
        for (const client of clients) {
          const movement = tick % 2 ? 3 : -1;
          client.expected.set(tick, movement);
          client.current.inputs.push(tick);
          await send(client, targets.match, Kind.INPUT, tick, movement, 96);
          if (tick % 3 === 0) {
            client.current.voices.push(tick);
            await send(client, targets.voice, Kind.VOICE, tick, 0, 320);
          }
          if (tick % 15 === 0) {
            for (let burst = 0; burst < 16; burst++) {
              const sequence = 1000 + tick * 16 + burst;
              client.expected.set(sequence, 1);
              client.current.inputs.push(sequence);
              await send(client, targets.match, Kind.INPUT, sequence, 1, [96, 512, 1200][burst % 3]);
            }
            await drain(client.current);
            targets.snapshot(client.player, tick);
            await client.current.inbox.wait(Kind.SNAPSHOT, targets.matchReply.address().port, [tick]);
          }
        }
        if (tick === 30) {
          const client = clients[0];
          await drain(client.current);
          const old = client.current;
          client.current = await bindClient(client.player, client.host, client.association);
          client.histories.push(client.current);
          assert.notEqual(old.socket.address().port, client.current.socket.address().port);
          await send(client, targets.lobby, Kind.JOIN, 2000, 0);
          await client.current.inbox.wait(Kind.ACK, targets.lobby.address().port, [2000]);
          const oldCount = old.inbox.messages.length;
          targets.snapshot(client.player, 2000);
          await client.current.inbox.wait(Kind.SNAPSHOT, targets.matchReply.address().port, [2000]);
          assert.equal(old.inbox.messages.length, oldCount, 'Snapshot went to the obsolete NAT port');
        }
        if (failures.length) throw failures[0];
        await delay(16, undefined, { signal: fixture.signal });
      }
      for (const client of clients) {
        for (const current of client.histories) await drain(current);
        const position = [...client.expected.values()].reduce((sum, movement) => sum + movement, 0);
        assert.equal(targets.states.get(client.player).inputs.size, client.expected.size);
        assert.equal(targets.states.get(client.player).position, position);
        const last = [...client.expected.keys()].at(-1);
        await send(client, targets.match, Kind.INPUT, last, client.expected.get(last), 96);
        await client.current.inbox.wait(Kind.ACK, targets.matchReply.address().port, [last], 2);
        targets.snapshot(client.player, 3001);
        targets.snapshot(client.player, 3000, 2);
        await client.current.inbox.wait(Kind.SNAPSHOT, targets.matchReply.address().port, [3000], 2);
        await client.current.inbox.wait(Kind.SNAPSHOT, targets.matchReply.address().port, [3001]);
        const snapshots = client.current.inbox.messages.filter((message) => message.packet.kind === Kind.SNAPSHOT);
        assert(snapshots.slice(-3).every((message) => message.packet.value === position));
        assert.equal(targets.states.get(client.player).inputs.size, client.expected.size, 'Duplicate input changed game state');
      }
      const stranger = await fixture.bindUdp('127.0.0.3');
      sockets.push(stranger);
      const before = targets.requests;
      const injected = await exchangeUdp(fixture, stranger, clients[0].association.relay,
        encodeUdp(targets.lobby.address().port, gamePacket(Kind.JOIN, 9, 4000, 0)), 200);
      assert.equal(injected, null);
      assert.equal(targets.requests, before, 'Foreign sender entered a pinned game association');
      for (const client of clients) {
        await client.association.control.close();
        const deadline = performance.now() + 1500;
        let released = false;
        while (performance.now() < deadline) {
          try {
            const lease = await fixture.bindUdp(client.association.relay.host, client.association.relay.port);
            await fixture.closeUdp(lease);
            released = true;
            break;
          } catch (error) { if (error.code !== 'EADDRINUSE') throw error; }
          await delay(20, undefined, { signal: fixture.signal });
        }
        assert(released, 'Game association did not release its UDP port');
      }
      const beforeClosed = targets.requests;
      const closed = await exchangeUdp(fixture, clients[0].current.socket, clients[0].association.relay,
        encodeUdp(targets.match.address().port, gamePacket(Kind.INPUT, 1, 5000, 1)), 200);
      assert.equal(closed, null);
      assert.equal(targets.requests, beforeClosed);
      if (failures.length) throw failures[0];
      return '2 玩家；248 个唯一输入、40 个语音包；跨 IP、端口迁移、不同回包端口、重复/乱序快照通过';
    } finally {
      for (const inbox of inboxes) inbox.close();
      await Promise.all(clients.map((client) => client.association.control.close()));
      await Promise.all(sockets.map(fixture.closeUdp));
      await targets.close();
    }
  });
}

module.exports = { gameUdpCases };

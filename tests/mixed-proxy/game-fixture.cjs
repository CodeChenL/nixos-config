'use strict';

const assert = require('node:assert/strict');
const { decodeUdp } = require('./socks.cjs');

const Kind = Object.freeze({ JOIN: 1, INPUT: 2, ACK: 3, SNAPSHOT: 4, VOICE: 5 });

function gamePacket(kind, player, sequence, value, size = 48) {
  const packet = Buffer.alloc(size, player);
  packet.writeUInt32BE(0x47554450, 0);
  packet[4] = kind;
  packet[5] = player;
  packet.writeUInt32BE(sequence, 6);
  packet.writeInt32BE(value, 10);
  return packet;
}

function parseGame(packet) {
  assert(packet.length >= 14);
  assert.equal(packet.readUInt32BE(0), 0x47554450);
  const player = packet[5];
  assert(packet.subarray(14).every((byte) => byte === player), 'Game payload was modified');
  return { kind: packet[4], player, sequence: packet.readUInt32BE(6), value: packet.readInt32BE(10), size: packet.length };
}

function createGameInbox(socket, relay, player, signal) {
  const messages = [];
  const waiters = new Set();
  let failure;
  function reject(error) {
    failure = error;
    for (const waiter of [...waiters]) waiter.finish(error);
  }
  function onMessage(data, remote) {
    try {
      assert.equal(remote.address, relay.host);
      assert.equal(remote.port, relay.port);
      const decoded = decodeUdp(data);
      assert.equal(decoded.host, '127.0.0.1');
      const packet = parseGame(decoded.payload);
      assert.equal(packet.player, player, 'Another game session received this packet');
      assert(packet.kind === Kind.ACK || packet.kind === Kind.SNAPSHOT);
      assert.equal(packet.size, packet.kind === Kind.SNAPSHOT ? 1200 : 48, 'Game reply was truncated');
      messages.push({ port: decoded.port, packet });
      for (const waiter of [...waiters]) waiter.inspect();
    } catch (error) { reject(error); }
  }
  socket.on('message', onMessage);
  function wait(kind, port, sequences, copies = 1) {
    signal.throwIfAborted();
    if (failure) return Promise.reject(failure);
    return new Promise((resolve, rejectWait) => {
      const onAbort = () => finish(signal.reason);
      const timer = setTimeout(() => finish(new Error(`Game packets timed out: kind=${kind}, port=${port}`)), 2000);
      function finish(error) {
        clearTimeout(timer);
        signal.removeEventListener('abort', onAbort);
        waiters.delete(waiter);
        if (error) rejectWait(error); else resolve();
      }
      const waiter = { finish, inspect() {
        if (sequences.every((sequence) => messages.filter((message) => message.port === port
          && message.packet.kind === kind && message.packet.sequence === sequence).length >= copies)) finish();
      } };
      waiters.add(waiter);
      signal.addEventListener('abort', onAbort, { once: true });
      waiter.inspect();
    });
  }
  function close() {
    socket.removeListener('message', onMessage);
    for (const waiter of [...waiters]) waiter.finish(new Error('Game inbox closed'));
  }
  return { messages, wait, reject, close };
}

async function startGameTargets(fixture, onError) {
  const lobby = await fixture.bindUdp();
  const match = await fixture.bindUdp();
  const matchReply = await fixture.bindUdp();
  const voice = await fixture.bindUdp();
  const states = new Map();
  let requests = 0;
  function state(player) {
    if (!states.has(player)) states.set(player, { inputs: new Map(), position: 0, peers: new Map(), joined: false });
    return states.get(player);
  }
  function send(socket, peer, packet) {
    socket.send(packet, peer.port, peer.address, (error) => { if (error) onError(error); });
  }
  for (const [socket, replySocket, kind] of [[lobby, lobby, Kind.JOIN], [match, matchReply, Kind.INPUT], [voice, voice, Kind.VOICE]]) {
    socket.on('message', (data, peer) => {
      try {
        const packet = parseGame(data);
        assert.equal(packet.kind, kind);
        const expectedSize = kind === Kind.INPUT
          ? (packet.sequence <= 60 ? 96 : [96, 512, 1200][((packet.sequence - 1000) % 16) % 3])
          : (kind === Kind.VOICE ? 320 : 48);
        assert.equal(packet.size, expectedSize, 'Game request was truncated');
        requests++;
        const current = state(packet.player);
        current.peers.set(kind, peer);
        if (kind === Kind.JOIN) current.joined = true;
        else {
          assert(current.joined, 'Game traffic arrived before joining the lobby');
          if (kind === Kind.INPUT && !current.inputs.has(packet.sequence)) {
            current.inputs.set(packet.sequence, packet.value);
            current.position += packet.value;
          }
        }
        const value = kind === Kind.JOIN ? match.address().port : current.position;
        send(replySocket, peer, gamePacket(Kind.ACK, packet.player, packet.sequence, value));
      } catch (error) { onError(error); }
    });
  }
  function snapshot(player, sequence, copies = 1) {
    const current = state(player);
    assert(current.peers.has(Kind.INPUT));
    for (let index = 0; index < copies; index++) {
      send(matchReply, current.peers.get(Kind.INPUT), gamePacket(Kind.SNAPSHOT, player, sequence, current.position, 1200));
    }
  }
  async function close() {
    await Promise.all([lobby, match, matchReply, voice].map(fixture.closeUdp));
  }
  return { lobby, match, matchReply, voice, states, snapshot, close, get requests() { return requests; } };
}

module.exports = { Kind, gamePacket, createGameInbox, startGameTargets };

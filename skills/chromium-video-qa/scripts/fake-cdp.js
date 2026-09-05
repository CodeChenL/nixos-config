'use strict';

const http = require('node:http');
const {createHash} = require('node:crypto');
const {once} = require('node:events');

async function fakeCdp(identity, args, pages, unsupported = false) {
  const commands = [];
  const sockets = new Set();
  const server = http.createServer((_request, response) => {
    response.end(JSON.stringify({webSocketDebuggerUrl:
      `ws://127.0.0.1:${server.address().port}${identity.browserPath}`}));
  });
  server.on('upgrade', (request, socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    const accept = createHash('sha1').update(request.headers['sec-websocket-key'] +
      '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n' +
      `Connection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    let buffer = Buffer.alloc(0);
    socket.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 2) {
        const opcode = buffer[0] & 15;
        if (opcode === 8) { socket.end(Buffer.from([0x88, 0])); return; }
        let length = buffer[1] & 127;
        let offset = 2;
        if (length === 126) {
          if (buffer.length < 4) return;
          length = buffer.readUInt16BE(2);
          offset = 4;
        }
        if (length === 127 || !(buffer[1] & 128)) { socket.destroy(); return; }
        if (buffer.length < offset + 4 + length) return;
        const mask = buffer.subarray(offset, offset + 4);
        const payload = Buffer.from(buffer.subarray(offset + 4, offset + 4 + length));
        for (let index = 0; index < payload.length; index++) payload[index] ^= mask[index % 4];
        buffer = buffer.subarray(offset + 4 + length);
        const message = JSON.parse(payload.toString());
        commands.push(message.method);
        const result = message.method === 'Browser.getBrowserCommandLine' ? {arguments: args} : {};
        const reply = Buffer.from(JSON.stringify(unsupported ?
          {id: message.id, error: {message: 'unsupported command'}} : {id: message.id, result}));
        const header = Buffer.alloc(4);
        header[0] = 0x81;
        header[1] = 126;
        header.writeUInt16BE(reply.length, 2);
        socket.write(Buffer.concat([header, reply]));
      }
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  let client;
  return {
    base, commands,
    async connect(endpoint) {
      client = new WebSocket(endpoint);
      await once(client, 'open');
      let nextId = 0;
      const pending = new Map();
      client.addEventListener('message', ({data}) => {
        const message = JSON.parse(data);
        const request = pending.get(message.id);
        pending.delete(message.id);
        if (message.error) request.reject(new Error(message.error.message));
        else request.resolve(message.result);
      });
      return {
        browser: {contexts: () => [{pages: () => pages}], close: async () => {
          const closed = once(client, 'close');
          client.close();
          await closed;
        }},
        session: {send: (method) => new Promise((resolve, reject) => {
          const id = ++nextId;
          pending.set(id, {resolve, reject});
          client.send(JSON.stringify({id, method}));
        })},
      };
    },
    disconnected: () => client?.readyState === WebSocket.CLOSED,
    async stop() {
      for (const socket of sockets) socket.destroy();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

module.exports = {fakeCdp};

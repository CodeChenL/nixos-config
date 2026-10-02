'use strict';

const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');

async function createEndpoints(fixture) {
  let targetRequests = 0;
  const targetMessages = [];
  const serve = async (request, response) => {
    targetRequests++;
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    targetMessages.push({ method: request.method, url: request.url, headers: request.headers,
      body: Buffer.concat(chunks), rawHeaders: request.rawHeaders });
    response.setHeader('Content-Type', 'text/plain');
    response.end(`${fixture.marker} ${request.method} ${request.url}`);
  };
  const httpPort = await fixture.listen(http.createServer(serve));
  const httpsPort = await fixture.listen(https.createServer({
    key: fs.readFileSync(path.join(fixture.directory, 'target.key')),
    cert: fs.readFileSync(path.join(fixture.directory, 'target.pem')),
  }, serve));
  const echo = await fixture.bindUdp();
  let echoRequests = 0;
  echo.on('message', (message, remote) => {
    echoRequests++;
    echo.send(message, remote.port, remote.address);
  });
  return { targetMessages, httpPort, httpsPort, echoPort: echo.address().port,
    get targetRequests() { return targetRequests; }, get echoRequests() { return echoRequests; } };
}

module.exports = { createEndpoints };

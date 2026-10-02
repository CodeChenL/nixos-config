'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { X509Certificate } = require('node:crypto');

async function certificate(fixture, name, serial) {
  const result = await fixture.command('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-days', '1', '-set_serial', String(serial), '-subj', '/CN=api.chenjaly.cn',
    '-addext', 'subjectAltName=DNS:api.chenjaly.cn,IP:127.0.0.1',
    '-keyout', path.join(fixture.directory, `${name}.key`), '-out', path.join(fixture.directory, `${name}.pem`)]);
  assert.equal(result.code, 0, result.stderr);
  fs.chmodSync(path.join(fixture.directory, `${name}.key`), 0o600);
}

async function certificateCases(context) {
  const { fixture, ports, check, curl, restartProxy } = context;
  const proxyCert = path.join(fixture.directory, 'proxy.pem');
  async function servedFingerprint() {
    const socket = await fixture.connection(ports.front, { secure: true });
    try { return socket.getPeerCertificate().fingerprint256; }
    finally { socket.destroy(); }
  }
  await check('代理首次提供显式配置的证书', async () => {
    assert.equal(await servedFingerprint(), new X509Certificate(fs.readFileSync(proxyCert)).fingerprint256);
  });
  await check('替换证书并重启代理后提供新证书且 HTTP 认证保持有效', async () => {
    const originalFingerprint = await servedFingerprint();
    await certificate(fixture, 'proxy', 3);
    const replacementFingerprint = new X509Certificate(fs.readFileSync(proxyCert)).fingerprint256;
    assert.notEqual(replacementFingerprint, originalFingerprint);
    await restartProxy();
    assert.equal(await servedFingerprint(), replacementFingerprint);
    for (const proxy of ['https', 'socks5h']) {
      const result = await curl(proxy, 'https', ['--proxy-user', `chen:${fixture.password}`]);
      assert.equal(result.code, 0, result.stderr);
      assert.equal(result.body, `${fixture.marker} GET /mixed-proxy-fixture`);
    }
  });
}

module.exports = { certificate, certificateCases };

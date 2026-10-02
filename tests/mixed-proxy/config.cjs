'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');

function assertFields(value, fields, label) {
  assert(value !== null && typeof value === 'object' && !Array.isArray(value), `${label} 必须是对象`);
  assert.deepEqual(Object.keys(value).sort(), fields, `${label} 字段必须严格固定`);
}

function loadConfig(generatedJson) {
  const config = JSON.parse(fs.readFileSync(generatedJson, 'utf8'));
  assertFields(config, ['listen', 'tls', 'udp'], '生成 JSON 顶层');
  assert.equal(config.listen, '0.0.0.0:8443', '生产监听地址必须是 0.0.0.0:8443');
  assertFields(config.tls, ['certFile', 'keyFile'], 'tls');
  for (const field of ['certFile', 'keyFile']) {
    assert.equal(typeof config.tls[field], 'string', `tls.${field} 必须是字符串`);
    assert(path.isAbsolute(config.tls[field]), `tls.${field} 必须是绝对路径`);
  }
  assertFields(config.udp, ['portRange', 'publicAddress'], 'udp');
  assert.equal(typeof config.udp.publicAddress, 'string', 'udp.publicAddress 必须是字符串');
  assert(net.isIP(config.udp.publicAddress) !== 0, 'udp.publicAddress 必须是 IP 地址');
  assertFields(config.udp.portRange, ['from', 'to'], 'udp.portRange');
  for (const field of ['from', 'to']) {
    const port = config.udp.portRange[field];
    assert(Number.isInteger(port) && port >= 1 && port <= 65535, `udp.portRange.${field} 必须是 1-65535 的整数`);
  }
  assert(config.udp.portRange.from <= config.udp.portRange.to, 'UDP 端口范围不能倒置');
  return config;
}

function writeConfig(fixture, loaded, ports) {
  const config = structuredClone(loaded);
  config.listen = `127.0.0.1:${ports.front}`;
  config.tls.certFile = path.join(fixture.directory, 'proxy.pem');
  config.tls.keyFile = path.join(fixture.directory, 'proxy.key');
  config.udp.publicAddress = ports.udp.publicAddress ?? '127.0.0.1';
  config.udp.portRange = { from: ports.udp.min, to: ports.udp.max };
  const filename = path.join(fixture.directory, 'mixed-proxy.json');
  fs.writeFileSync(filename, JSON.stringify(config, null, 2), { mode: 0o600 });
  return filename;
}

module.exports = { loadConfig, writeConfig };

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
if (args[0] !== '-n' || args[1] !== '--' || args[2] !== '/usr/local/libexec/chromium-qa-observer')
  throw new Error('unexpected privileged command in test');
const [action, namespace, device, session, profile] = args.slice(3);
const state = process.env.QA_MOCK_STATE;
const postclose = state && fs.existsSync(path.join(state, 'driver-ran'));
if (process.env.QA_MOCK_OBSERVER || (postclose && process.env.QA_MOCK_POST_OBSERVER)) {
  console.error('UNKNOWN: observer permission or namespace opaque');
  process.exit(3);
}
if (action === 'processes') {
  console.log('OBSERVER_V1');
  if (postclose && process.env.QA_MOCK_REMAIN === '1') console.log('99999');
  for (const pid of fs.readdirSync('/proc').filter((entry) => /^\d+$/.test(entry))) {
    try {
      const fields = fs.readFileSync(`/proc/${pid}/stat`, 'utf8').split(')').at(-1).trim().split(/\s+/);
      const matchesSession = session !== '0' && fields[3] === session;
      const argv = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0');
      if (matchesSession || argv.includes('--user-data-dir=' + profile)) console.log(pid);
    } catch (error) {
      if (!['ENOENT', 'EACCES', 'ESRCH'].includes(error.code)) throw error;
    }
  }
  process.exit(0);
}
if (action !== 'snapshot' || !state || !/^\/dev\/video\d+$/.test(device))
  throw new Error('unexpected test observer operation');
const baseline = profile === '-';
const status = baseline ? process.env.QA_MOCK_BASELINE : postclose ? process.env.QA_MOCK_DEVICE : undefined;
if (['error', 'missing', 'transport'].includes(status)) {
  console.error('UNKNOWN: device observation unavailable');
  process.exit(3);
}
if (status === 'empty-success') process.exit(0);
const sample = 'a'.repeat(32);
const rows = [`BEGIN\t${sample}\t${namespace}\t${session}`];
if (baseline && process.env.QA_MOCK_PREEXISTING === '1')
  rows.push(`P\t${sample}\t99999\t1\t7\t0\t0\t1`);
if (status === 'busy') {
  rows.push(`P\t${sample}\t99999\t1\t7\t0\t0\t0`, `O\t${sample}\t99999\t1`);
} else if (!baseline && !postclose) {
  const variant = process.env.QA_MOCK_OWNER;
  const ownerSession = variant === 'outsider' ? '7' : session;
  rows.push(`P\t${sample}\t99998\t2\t${ownerSession}\t1\t0\t0`);
  if (variant && variant !== 'none')
    rows.push(`O\t${variant === 'stale-sample' ? 'b'.repeat(32) : sample}\t99998\t2`);
  fs.writeFileSync(path.join(state, 'monitor-sampled'), 'yes');
}
rows.push(`END\t${sample}`);
console.log(rows.join('\n'));

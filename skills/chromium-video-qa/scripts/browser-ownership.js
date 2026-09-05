'use strict';

function readIdentity(env) {
  const {QA_EXPECTED_URL: url, QA_PROFILE: profile,
    QA_RUN_TOKEN: token, QA_BROWSER_PATH: browserPath} = env;
  if (!/^[a-f0-9]{32}$/.test(token || '') ||
      !/^\/tmp\/chromium-video-qa\.[A-Za-z0-9]{12}\/profile$/.test(profile || '') ||
      !/^\/devtools\/browser\/[A-Za-z0-9-]+$/.test(browserPath || ''))
    throw new Error('missing or invalid run identity');
  const parsed = new URL(url);
  if (parsed.protocol !== 'file:' || parsed.hostname ||
      parsed.pathname !== profile.slice(0, -7) + 'video-qa.html' ||
      parsed.searchParams.get('run') !== token)
    throw new Error('URL does not belong to run');
  return {url, profile, token, browserPath};
}

async function ownedEndpoint(cdpUrl, identity) {
  const endpoint = new URL(cdpUrl);
  if (endpoint.protocol !== 'http:' || endpoint.hostname !== '127.0.0.1')
    throw new Error('CDP must use local loopback tunnel');
  const response = await fetch(new URL('/json/version', endpoint), {
    signal: AbortSignal.timeout(3000), redirect: 'error',
  });
  if (!response.ok) throw new Error('CDP version request failed');
  const version = await response.json();
  const websocket = new URL(version.webSocketDebuggerUrl);
  if (websocket.pathname !== identity.browserPath || websocket.protocol !== 'ws:' ||
      websocket.search || websocket.hash)
    throw new Error('CDP browser identity mismatch');
  return `ws://${endpoint.host}${identity.browserPath}`;
}

async function ownedPage(browser, session, identity) {
  const {arguments: args} = await session.send('Browser.getBrowserCommandLine');
  if (!Array.isArray(args) ||
      args.filter((arg) => arg.startsWith('--user-data-dir')).length !== 1 ||
      !args.includes('--user-data-dir=' + identity.profile) ||
      !args.includes('--enable-automation') ||
      args.filter((arg) => arg === identity.url).length !== 1)
    throw new Error('browser command line does not belong to run');
  const pages = browser.contexts().flatMap((context) => context.pages());
  if (pages.length !== 1 || pages[0].url() !== identity.url)
    throw new Error('expected exactly one run-owned page');
  return pages[0];
}

async function closeOwned(browser, session, identity) {
  try {
    await ownedPage(browser, session, identity);
    await session.send('Browser.close');
  } finally {
    await browser.close();
  }
}

module.exports = {readIdentity, ownedEndpoint, ownedPage, closeOwned};

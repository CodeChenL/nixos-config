'use strict';

const {chromium} = require('./playwright-loader');
const {readIdentity, ownedEndpoint, closeOwned} = require('./browser-ownership');

(async () => {
  const identity = readIdentity(process.env);
  const endpoint = await ownedEndpoint(process.env.CDP_URL, identity);
  const browser = await chromium.connectOverCDP(endpoint, {timeout: 10000});
  const session = await browser.newBrowserCDPSession();
  await closeOwned(browser, session, identity);
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});

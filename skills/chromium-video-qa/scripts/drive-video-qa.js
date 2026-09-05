'use strict';

const fs = require('node:fs');
const { chromium } = require('playwright');
const {readIdentity, ownedEndpoint, ownedPage, closeOwned} = require('./browser-ownership');

const [prefix, expectedMode] = process.argv.slice(2);
if (!prefix || !['full', 'seek'].includes(expectedMode)) {
  throw new Error(
      'usage: node drive-video-qa.js <output-prefix> <full|seek>');
}

const cdpUrl = process.env.CDP_URL || 'http://127.0.0.1:9222';
const terminalStates =
    ['ended', 'media-error', 'play-error', 'timeout', 'harness-error'];
const timeoutMs = Number(process.env.QA_DRIVER_TIMEOUT_MS || 60000);
const screenshots = process.env.QA_SCREENSHOTS !== '0';

(async () => {
  const identity = readIdentity(process.env);
  const endpoint = await ownedEndpoint(cdpUrl, identity);
  const browser = await chromium.connectOverCDP(endpoint, {timeout: 10000});
  let browserSession;
  let owned = false;
  try {
    browserSession = await browser.newBrowserCDPSession();
    const page = await ownedPage(browser, browserSession, identity);
    owned = true;

    page.on('console', (message) => {
      console.error('[browser ' + message.type() + '] ' + message.text());
    });
    page.on('pageerror', (error) => {
      console.error('[page error] ' + String(error));
    });

    await page.waitForFunction(
        () => window.qa && window.qa.state !== 'loading',
        undefined, {timeout: Math.min(timeoutMs, 15000)});

    const firstState = await page.evaluate(() => window.qa.state);
    if (firstState === 'playing') {
      await page.waitForFunction(
          (states) => states.includes(window.qa.state) ||
              window.qa.currentTime >= 1,
          terminalStates, {timeout: Math.min(timeoutMs, 20000)});
      const state = await page.evaluate(() => window.qa.state);
      if (screenshots && state === 'playing') {
        await page.screenshot({path: prefix + '-playing.png', fullPage: true});
        await page.locator('#status').evaluate((element) => {
          element.hidden = true;
        });
        await page.screenshot(
            {path: prefix + '-video-playing.png', fullPage: true});
        await page.locator('#status').evaluate((element) => {
          element.hidden = false;
        });
      }
    }

    await page.waitForFunction(
        (states) => states.includes(window.qa && window.qa.state),
        terminalStates, {timeout: timeoutMs});
    const qa = await page.evaluate(() => structuredClone(window.qa));
    if (screenshots)
      await page.screenshot({path: prefix + '-ended.png', fullPage: true});

    if (qa.state !== 'ended')
      throw new Error('playback did not reach EOS: ' + JSON.stringify(qa));
    if (qa.mode !== expectedMode) {
      throw new Error(
          'mode mismatch: expected ' + expectedMode + ', got ' + qa.mode);
    }
    if (!(qa.totalVideoFrames > 0 && qa.presentedFrames > 0))
      throw new Error('no decoded frames: ' + JSON.stringify(qa));
    if (qa.corruptedVideoFrames !== 0) {
      throw new Error('corrupted frames: ' + JSON.stringify(qa));
    }
    if (!(qa.duration > 0 && Number.isFinite(qa.duration) &&
        Number.isFinite(qa.currentTime) && Math.abs(qa.currentTime - qa.duration) < 0.25))
      throw new Error('invalid EOS timing: ' + JSON.stringify(qa));
    if (expectedMode === 'seek' &&
        !qa.seekEvents.some((event) => event.event === 'seeked')) {
      throw new Error('seek did not complete: ' + JSON.stringify(qa));
    }

    const systemInfo = await browserSession.send('SystemInfo.getInfo');
    fs.writeFileSync(
        prefix + '-system-info.json', JSON.stringify(systemInfo, null, 2) + '\n');

    process.stdout.write(JSON.stringify({
      browser: await browser.version(),
      url: page.url(),
      qa,
    }, null, 2) + '\n');
  } finally {
    try {
      if (owned)
        await closeOwned(browser, browserSession, identity);
      else
        await browser.close();
    } catch (error) {
      console.error('cleanup: ' + (error.stack || error));
      process.exitCode = 1;
    }
  }
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});

'use strict';

function loadPlaywright() {
  try {
    return require('playwright');
  } catch (error) {
    if (error.code !== 'MODULE_NOT_FOUND') throw error;
    return require('playwright-core');
  }
}

module.exports = {chromium: loadPlaywright().chromium};

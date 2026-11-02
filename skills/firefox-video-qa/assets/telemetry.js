'use strict';

(function initTelemetry(scope) {
  function metricState(value, available) {
    if (!available) return {state: 'unavailable', value: null};
    if (value === null || value === undefined) return {state: 'null', value: null};
    if (value === 0) return {state: 'zero', value: 0};
    return {state: 'nonzero', value};
  }

  function createReporter(post) {
    let pending;
    return function report(url, result) {
      if (pending === undefined) {
        pending = Promise.resolve(post(url, result));
      }
      return pending;
    };
  }

  function shouldRenderFrame(profile, lastRender, now) {
    if (profile === 'performance') return now - lastRender >= 1000;
    return true;
  }

  const api = {metricState, createReporter, shouldRenderFrame};
  scope.FirefoxQaTelemetry = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);

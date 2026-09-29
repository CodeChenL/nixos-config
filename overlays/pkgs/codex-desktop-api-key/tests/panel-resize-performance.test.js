"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const {
  applyMenuPointerFocusPerformancePatch,
  applyPanelResizePerformancePatch,
  applyTerminalFitPerformancePatch,
} = require("../panel-resize-performance.js");



function currentTerminalFitFixture() {
  return [
    "function terminal(){let a=!1,e={isConnected:!0},I={current:!0},m={},",
    "D={fit(){globalThis.codexLinuxPlainFits++}},i={},",
    "Ce=(e,t,n,r)=>{globalThis.codexLinuxForcedFits.push(r)},",
    "k=t=>{let n=t!==void 0&&t;a||e.isConnected&&requestAnimationFrame(()=>{",
    "a||e.isConnected&&(I.current?Ce(m,D,i,n):D.fit())})};",
    "return{fit:k,dispose:()=>{a=!0}}}",
  ].join("");
}

function currentMenuFixture() {
  return [
    "var tm=`MenuItem`,Ife=`menu.itemSelect`,",
    "handler=e=>{e.defaultPrevented||e.currentTarget.focus({preventScroll:!0})};",
  ].join("");
}

function currentResizerFixture() {
  return [
    "function kOa(e){let t=0,{action:n,allowPointerOverflow:r,ariaLabel:i,edge:a,",
    "defaultSize:o,extendIntoToolbar:s,getCurrentSize:c,indicator:l,keyboardStep:u,",
    "maximumSize:d,minimumSize:f,onResizeEnd:p,onResizingChange:m,setSize:h}=e,",
    "g=r!==void 0&&r,_=a===void 0?`right`:a,S=!0,w={current:{didMove:true,startPointer:{x:0,y:0},startSize:320}},x=2,O;",
    "O=()=>{if(!S)return;let e=e=>({x:e.clientX/x,y:e.clientY/x}),",
    "t=t=>{t.preventDefault();let n=w.current;if(n==null)return;let r=e(t);",
    "h(MOa(AOa(_,r,n),g?void 0:f,g?void 0:d))},",
    "n=t=>{t.preventDefault();let n=w.current;if(n?.didMove===!0){",
    "let r=MOa(AOa(_,e(t),n),g?void 0:f,g?void 0:d);h(r),p?.(r)}",
    "w.current=null};return window.addEventListener(`pointermove`,t),",
    "window.addEventListener(`pointerup`,n),window.addEventListener(`pointercancel`,n),",
    "()=>{window.removeEventListener(`pointermove`,t),",
    "window.removeEventListener(`pointerup`,n),window.removeEventListener(`pointercancel`,n)}};",
    "let M=e=>{let t=1;h(t),p?.(t)},P=e=>{let t=2;h(t),p?.(t)};",
    "return{effect:O,onPointerDown:()=>{},onDoubleClick:M,onKeyDown:P}}",
    "function AOa(e,t,n){globalThis.codexLinuxProjectionCalls++;return t.x-n.startPointer.x}",
    "function MOa(e){return e}",
  ].join("");
}

test("previews panel resize without committing layout on pointer motion", () => {
  // Given
  const source = currentResizerFixture();

  // When
  const patched = applyPanelResizePerformancePatch(source);

  // Then
  assert.match(patched, /codexLinuxSchedulePanelResize/u);
  assert.match(patched, /requestAnimationFrame/u);
  assert.doesNotMatch(patched, /setTimeout/u);
  assert.match(patched, /codexLinuxPanelResizePreviewTarget/u);
  assert.match(patched, /codexLinuxApplyPanelResize/u);
  assert.doesNotMatch(patched, /codexLinuxFlushPanelResize/u);
  assert.match(patched, /codexLinuxCancelPanelResize/u);
  assert.match(
    patched,
    /codexLinuxSchedulePanelResize\(t\)/u,
  );
  assert.match(patched, /codexLinuxCancelPanelResize\(\),h\(r\),p\?\.\(r\)/u);
  assert.equal(patched.split("h(t),p?.(t)").length - 1, 2);
  assert.match(
    patched,
    /codexLinuxCancelPanelResize\(\),window\.removeEventListener\(`pointermove`,t\)/u,
  );
});

test("runs the coalesced effect and cleanup without leaking its helper scope", () => {
  // Given
  const patched = applyPanelResizePerformancePatch(currentResizerFixture());
  globalThis.codexLinuxProjectionCalls = 0;
  const listeners = new Map();
  const frames = new Map();
  const cancelled = [];
  const ends = [];
  const sizes = [];
  let nextFrame = 1;
  const fakeWindow = {
    addEventListener(name, handler) {
      listeners.set(name, handler);
    },
    removeEventListener(name, handler) {
      if (listeners.get(name) === handler) listeners.delete(name);
    },
  };
  class FakeElement {}
  const createResizer = Function(
    "window",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "Element",
    patched + ";return kOa",
  )(
    fakeWindow,
    (callback) => {
      const id = nextFrame++;
      frames.set(id, callback);
      return id;
    },
    (id) => {
      cancelled.push(id);
      frames.delete(id);
    },
    FakeElement,
  );
  const previewTarget = new FakeElement();
  previewTarget.style = { transform: "" };
  previewTarget.closest = (selector) => {
    assert.equal(selector, String.raw`.group\/panel-resizer`);
    return previewTarget;
  };
  const resizer = createResizer({
    setSize(value) {
      sizes.push(value);
    },
    onResizeEnd(value) {
      ends.push(value);
    },
    onResizingChange() {},
  });
  const cleanup = resizer.effect();

  // When
  const move = listeners.get("pointermove");
  for (let clientX = 2; clientX <= 2000; clientX += 2) {
    move({ clientX, clientY: 0, target: previewTarget, preventDefault() {} });
  }

  // Then
  assert.equal(sizes.length, 0);
  assert.equal(globalThis.codexLinuxProjectionCalls, 0);
  assert.equal(frames.size, 1);
  const firstFrame = frames.entries().next().value;
  frames.delete(firstFrame[0]);
  firstFrame[1]();
  assert.deepEqual(sizes, []);
  assert.equal(globalThis.codexLinuxProjectionCalls, 1);
  assert.equal(previewTarget.style.transform, "translateX(680px)");

  move({ clientX: 1000, clientY: 0, target: previewTarget, preventDefault() {} });
  assert.equal(frames.size, 1);
  listeners.get("pointerup")({ clientX: 1200, clientY: 0, target: previewTarget, preventDefault() {} });
  assert.deepEqual(sizes, [600]);
  assert.deepEqual(ends, [600]);
  assert.equal(globalThis.codexLinuxProjectionCalls, 2);
  assert.deepEqual(cancelled, [2]);
  assert.equal(frames.size, 0);
  assert.equal(previewTarget.style.transform, "");

  assert.doesNotThrow(cleanup);
  assert.equal(listeners.size, 0);
  delete globalThis.codexLinuxProjectionCalls;
});

test("leaves an already patched panel resizer unchanged", () => {
  // Given
  const patched = applyPanelResizePerformancePatch(currentResizerFixture());

  // When
  const secondPass = applyPanelResizePerformancePatch(patched);

  // Then
  assert.equal(secondPass, patched);
});

test("rejects an ambiguous panel resizer contract", () => {
  // Given
  const source = currentResizerFixture() + currentResizerFixture();

  // When / Then
  assert.throws(
    () => applyPanelResizePerformancePatch(source),
    /expected exactly one shared panel resizer/u,
  );
});

test("fails closed when the pointer listener contract drifts", () => {
  // Given
  const source = currentResizerFixture().replaceAll("pointermove", "mousemove");

  // When / Then
  assert.throws(
    () => applyPanelResizePerformancePatch(source),
    /pointer listener contract/u,
  );
});

test("debounces shared menu pointer focus until pointer motion settles", () => {
  const patched = applyMenuPointerFocusPerformancePatch(currentMenuFixture());
  const timers = new Map();
  const cleared = [];
  let nextTimer = 1;
  const schedule = Function(
    "setTimeout",
    "clearTimeout",
    patched + ";return globalThis.codexLinuxScheduleMenuPointerFocus",
  )(
    (callback, delay) => {
      const id = nextTimer++;
      timers.set(id, { callback, delay });
      return id;
    },
    (id) => {
      cleared.push(id);
      timers.delete(id);
    },
  );
  const first = { isConnected: true, matches: () => true, focus() { throw new Error("stale target focused"); } };
  let focusOptions = null;
  const second = {
    isConnected: true,
    matches: (selector) => selector === ":hover",
    focus(options) { focusOptions = options; },
  };

  schedule(first);
  schedule(second);

  assert.deepEqual(cleared, [0, 1]);
  assert.equal(timers.size, 1);
  const pending = timers.values().next().value;
  assert.equal(pending.delay, 120);
  assert.equal(focusOptions, null);
  pending.callback();
  assert.deepEqual(focusOptions, { preventScroll: true });
});

test("leaves an already patched menu focus contract unchanged", () => {
  const patched = applyMenuPointerFocusPerformancePatch(currentMenuFixture());
  assert.equal(applyMenuPointerFocusPerformancePatch(patched), patched);
});

test("defers terminal fit until continuous panel resizing settles", () => {
  const patched = applyTerminalFitPerformancePatch(currentTerminalFitFixture());
  const timers = new Map();
  const cleared = [];
  let nextTimer = 1;
  globalThis.codexLinuxForcedFits = [];
  globalThis.codexLinuxPlainFits = 0;
  const createTerminal = Function(
    "setTimeout",
    "clearTimeout",
    patched + ";return terminal",
  )(
    (callback, delay) => {
      const id = nextTimer++;
      timers.set(id, { callback, delay });
      return id;
    },
    (id) => {
      cleared.push(id);
      timers.delete(id);
    },
  );
  const terminal = createTerminal();

  terminal.fit(false);
  terminal.fit(true);

  assert.deepEqual(cleared, [1]);
  assert.equal(timers.size, 1);
  const pending = timers.values().next().value;
  assert.equal(pending.delay, 250);
  assert.deepEqual(globalThis.codexLinuxForcedFits, []);
  assert.equal(globalThis.codexLinuxPlainFits, 0);
  pending.callback();
  assert.deepEqual(globalThis.codexLinuxForcedFits, [true]);
  delete globalThis.codexLinuxForcedFits;
  delete globalThis.codexLinuxPlainFits;
});

test("leaves an already patched terminal fit contract unchanged", () => {
  const patched = applyTerminalFitPerformancePatch(currentTerminalFitFixture());
  assert.equal(applyTerminalFitPerformancePatch(patched), patched);
});

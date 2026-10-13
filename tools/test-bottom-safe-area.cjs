'use strict';

// Exercise the real observer with window substitutes; no device or account access.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const loaderRoot = path.join(process.env.DEVECO_HOME || 'D:/software/DevEco Studio',
  'sdk/default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.TYPESCRIPT_PATH || path.join(loaderRoot, 'node_modules/typescript'));
const filename = path.resolve(__dirname, '../entry/src/main/ets/model/BottomSafeAreaObserver.ets');
const source = fs.readFileSync(filename, 'utf8');
const output = ts.transpileModule(source, { fileName: filename, reportDiagnostics: true,
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
assert.deepEqual((output.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error), []);
const types = { TYPE_SYSTEM: 0, TYPE_NAVIGATION_INDICATOR: 1, TYPE_KEYBOARD: 2, TYPE_CUTOUT: 3 };
const area = height => ({ bottomRect: { height } });

function fixture() {
  const events = [], insets = [], listeners = new Set();
  const areas = new Map([[0, area(12)], [1, area(60)], [2, area(0)]]);
  const config = { failedRead: false, getWindow: undefined };
  const win = {
    getWindowAvoidArea(type) {
      events.push(['read', type]);
      if (config.failedRead) throw new Error('temporary read failure');
      return areas.get(type);
    },
    on(name, callback) { events.push(['on', name, callback]); listeners.add(callback); },
    off(name, callback) { events.push(['off', name, callback]); listeners.delete(callback); }
  };
  config.getWindow = async () => win;
  const uiContext = { getHostContext: () => ({}), px2vp: pixels => pixels / 3 };
  const window = { AvoidAreaType: types, getLastWindow: () => config.getWindow() };
  const context = vm.createContext({ exports: {}, require: () => ({ window }) });
  vm.runInContext(output.outputText, context, { filename });
  const observer = new context.exports.BottomSafeAreaObserver();
  const start = () => observer.start(uiContext, inset => insets.push(inset));
  const emit = (type, height) => {
    for (const callback of listeners) callback({ type, area: area(height) });
  };
  return { observer, start, emit, win, config, areas, events, insets, listeners };
}

test('merges navigation and system bottoms, converts px to vp, and supports no gesture area', async () => {
  const f = fixture(); await f.start();
  assert.deepEqual(f.insets, [20]);
  f.emit(types.TYPE_SYSTEM, 90); assert.equal(f.insets.at(-1), 30);
  f.emit(types.TYPE_NAVIGATION_INDICATOR, 0); assert.equal(f.insets.at(-1), 30);
  f.emit(types.TYPE_SYSTEM, 0); assert.equal(f.insets.at(-1), 0);
  assert.equal(f.events.filter(event => event[0] === 'read').length, 3);
});

test('keyboard visibility removes the extra gesture gap and restores the latest navigation inset', async () => {
  const f = fixture(); await f.start();
  f.emit(types.TYPE_KEYBOARD, 900); assert.equal(f.insets.at(-1), 0);
  f.emit(types.TYPE_NAVIGATION_INDICATOR, 75); assert.equal(f.insets.at(-1), 0);
  f.emit(types.TYPE_KEYBOARD, 0); assert.equal(f.insets.at(-1), 25);
  assert.equal(f.events.filter(event => event[0] === 'read').length, 3);
});

test('initial keyboard state and refresh after returning to a page use current window values', async () => {
  const f = fixture(); f.areas.set(types.TYPE_KEYBOARD, area(900)); await f.start();
  assert.deepEqual(f.insets, [0]);
  f.areas.set(types.TYPE_KEYBOARD, area(0));
  f.areas.set(types.TYPE_NAVIGATION_INDICATOR, area(48)); f.observer.refresh();
  assert.equal(f.insets.at(-1), 16);
});

test('failed initial read preserves native avoidance until a later successful refresh', async () => {
  const f = fixture(); f.config.failedRead = true; await f.start();
  assert.deepEqual(f.insets, []);
  f.config.failedRead = false; f.observer.refresh(); assert.deepEqual(f.insets, [20]);
  f.config.failedRead = true; f.observer.refresh(); assert.deepEqual(f.insets, [20]);
});

test('failed window lookup can retry without a duplicate subscription', async () => {
  const f = fixture(); f.config.getWindow = async () => { throw new Error('unavailable'); };
  await f.start(); assert.deepEqual(f.insets, []);
  f.config.getWindow = async () => f.win; await f.start(); await f.start();
  assert.equal(f.listeners.size, 1); assert.deepEqual(f.insets, [20]);
});

test('disposal removes exactly the registered callback and ignores late notifications', async () => {
  const f = fixture(); await f.start();
  const registered = f.events.find(event => event[0] === 'on');
  f.observer.stop();
  const removed = f.events.find(event => event[0] === 'off');
  assert.equal(removed[2], registered[2]); assert.equal(f.listeners.size, 0);
  registered[2]({ type: types.TYPE_SYSTEM, area: area(300) });
  f.observer.refresh(); assert.deepEqual(f.insets, [20]);
});

test('a lookup resolving after disposal never registers or reports insets', async () => {
  const f = fixture(); let resolve;
  f.config.getWindow = () => new Promise(done => { resolve = done; });
  const pending = f.start(); f.observer.stop(); resolve(f.win); await pending;
  assert.equal(f.events.length, 0); assert.deepEqual(f.insets, []);
});

test('a queued notification from a previous subscription cannot overwrite insets after reappearance', async () => {
  const f = fixture(); await f.start();
  const previous = f.events.find(event => event[0] === 'on')[2];
  f.observer.stop(); f.areas.set(types.TYPE_NAVIGATION_INDICATOR, area(48)); await f.start();
  const before = [...f.insets];
  previous({ type: types.TYPE_SYSTEM, area: area(300) });
  previous({ type: types.TYPE_KEYBOARD, area: area(900) });
  assert.deepEqual(f.insets, before);
  f.emit(types.TYPE_NAVIGATION_INDICATOR, 75); assert.equal(f.insets.at(-1), 25);
});

test('overlapping old and new lookups after reappearance use only the new window', async () => {
  const f = fixture(); const resolve = [];
  f.config.getWindow = () => new Promise(done => resolve.push(done));
  const first = f.start(); f.observer.stop(); const second = f.start();
  resolve[0](f.win); await first;
  const duplicate = f.start(); assert.equal(resolve.length, 2); await duplicate;
  resolve[1](f.win); await second;
  assert.equal(f.listeners.size, 1); assert.deepEqual(f.insets, [20]);
});

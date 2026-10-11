'use strict';
// Executes the viewer's actual ETS lifecycle/inset methods with window substitutes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const loaderRoot = path.join(process.env.DEVECO_HOME || 'D:/software/DevEco Studio',
  'sdk/default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.TYPESCRIPT_PATH || path.join(loaderRoot, 'node_modules/typescript'));
const componentMap = require(path.join(loaderRoot, 'lib/component_map.js'));
const filename = path.resolve(__dirname, '../entry/src/main/ets/components/ArticleImageViewer.ets');
const source = fs.readFileSync(filename, 'utf8');
const ast = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS,
  { ets: { components: Object.keys(componentMap.COMPONENT_MAP) } });
assert.deepEqual(ast.parseDiagnostics, []);
const subject = ast.statements.find(node => node.name?.getText(ast) === 'ArticleImageViewer');
assert.ok(subject);
const methodNames = new Set(['onAvoidAreaChanged', 'aboutToAppear', 'aboutToDisappear',
  'stopSafeAreaObservation', 'observeSafeArea', 'updateSafeInsets']);
const members = subject.members.filter(member => member.name && methodNames.has(member.name.getText(ast)));
assert.equal(members.length, methodNames.size, 'Extract every actual lifecycle/inset member');
const output = ts.transpileModule('class RealViewer {\n' + members.map(member => member.getText(ast)).join('\n') +
  '\n}\nglobalThis.RealViewer=RealViewer;', { fileName: filename, reportDiagnostics: true,
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
assert.deepEqual((output.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error), []);
const types = { TYPE_SYSTEM: 0, TYPE_CUTOUT: 1, TYPE_NAVIGATION_INDICATOR: 2, TYPE_KEYBOARD: 3 };
const rect = (left = 0, top = 0, width = 0, height = 0) => ({ left, top, width, height });
const emptyArea = () => ({ topRect: rect(), bottomRect: rect(), leftRect: rect(), rightRect: rect(), visible: true });
const settle = () => new Promise(resolve => setImmediate(resolve));
function fixture() {
  const events = [], timers = new Map(), cleared = [], toasts = [];
  const areas = new Map(Object.values(types).map(type => [type, emptyArea()]));
  areas.set(types.TYPE_SYSTEM, { ...emptyArea(), topRect: rect(0, 0, 1200, 80) });
  areas.set(types.TYPE_NAVIGATION_INDICATOR, { ...emptyArea(), bottomRect: rect(0, 2352, 1200, 48) });
  areas.set(types.TYPE_CUTOUT, { ...emptyArea(), topRect: rect(480, 12, 240, 108),
    leftRect: rect(0, 900, 30, 90), rightRect: rect(1155, 900, 45, 90), bottomRect: rect(300, 2364, 60, 20) });
  const win = {
    getWindowAvoidArea(type) { events.push(['read', type]); return areas.get(type); },
    getWindowProperties() { events.push(['properties']); return { windowRect: rect(0, 0, 1200, 2400) }; },
    on(name, callback) { events.push(['on', name, callback]); },
    off(name, callback) { events.push(['off', name, callback]); }
  };
  const config = { getWindow: async () => win };
  const context = vm.createContext({ window: { AvoidAreaType: types, async getLastWindow() {
    events.push(['getLastWindow']); return config.getWindow();
  } }, setTimeout(callback, delay) { const id = timers.size + 1; timers.set(id, { callback, delay }); return id; },
    clearTimeout(id) { cleared.push(id); timers.delete(id); } });
  vm.runInContext(output.outputText, context, { filename });
  const host = new context.RealViewer();
  Object.assign(host, { viewerWindow: undefined, systemAvoidArea: undefined, cutoutAvoidArea: undefined,
    navigationAvoidArea: undefined, observingWindow: false, avoidRetryTimer: -1,
    safeInsetTop: 0, safeInsetBottom: 0, safeInsetLeft: 0, safeInsetRight: 0, safeAreaReady: false });
  let closed = 0;
  host.onClose = () => { closed++; };
  host.getUIContext = () => ({ getHostContext: () => ({ fixture: true }), px2vp: pixels => pixels / 3,
    getPromptAction: () => ({ showToast: toast => toasts.push(toast) }) });
  return { host, win, areas, events, timers, cleared, toasts, config, closed: () => closed };
}
test('initial insets merge all three avoid-area types by edge maximum and convert pixels to vp', async () => {
  const f = fixture(); f.host.aboutToAppear(); await settle();
  assert.equal(f.host.safeInsetTop, 40); // cutout 12 + 108, greater than status 80
  assert.equal(f.host.safeInsetBottom, 16); // navigation 48, greater than cutout 36
  assert.equal(f.host.safeInsetLeft, 10);
  assert.equal(f.host.safeInsetRight, 15);
  assert.equal(f.host.safeAreaReady, true);
  assert.deepEqual(f.events.filter(event => event[0] === 'read').map(event => event[1]), [0, 1, 2]);
});
test('change events use their fresh area and shrink previous insets without querying stale area values', async () => {
  const f = fixture(); f.host.aboutToAppear(); await settle();
  f.host.onAvoidAreaChanged({ type: types.TYPE_SYSTEM, area: { ...emptyArea(), topRect: rect(0, 0, 1200, 96) } });
  f.host.onAvoidAreaChanged({ type: types.TYPE_CUTOUT, area: emptyArea() });
  f.host.onAvoidAreaChanged({ type: types.TYPE_NAVIGATION_INDICATOR,
    area: { ...emptyArea(), bottomRect: rect(0, 2340, 1200, 60) } });
  assert.equal(f.host.safeInsetTop, 32);
  assert.equal(f.host.safeInsetBottom, 20);
  assert.equal(f.host.safeInsetLeft, 0);
  assert.equal(f.host.safeInsetRight, 0);
  assert.equal(f.events.filter(event => event[0] === 'read').length, 3);
});
test('disappearance unregisters only its callback and ignores late avoid-area notifications', async () => {
  const f = fixture(); f.host.aboutToAppear(); await settle();
  const registered = f.events.find(event => event[0] === 'on');
  f.host.aboutToDisappear();
  const removed = f.events.find(event => event[0] === 'off');
  assert.equal(removed[1], registered[1]); assert.equal(removed[2], registered[2]);
  assert.equal(f.host.viewerWindow, undefined);
  const count = f.events.length;
  f.host.onAvoidAreaChanged({ type: types.TYPE_SYSTEM, area: emptyArea() });
  assert.equal(f.events.length, count);
  assert.equal(f.host.safeInsetTop, 40);
});
test('window lookup resolving after destruction never reads areas, registers listeners, or changes UI state', async () => {
  const f = fixture(); let resolveWindow;
  f.config.getWindow = () => new Promise(resolve => { resolveWindow = resolve; });
  f.host.aboutToAppear(); f.host.aboutToDisappear(); resolveWindow(f.win); await settle();
  assert.deepEqual(f.events.map(event => event[0]), ['getLastWindow']);
  assert.equal(f.host.safeAreaReady, false);
  assert.equal(f.host.viewerWindow, undefined);
  assert.equal(f.timers.size, 0);
});
test('destroying during initialization retry clears its timer and the late retry callback remains inert', async () => {
  const f = fixture(); f.config.getWindow = async () => { throw new Error('fixture unavailable'); };
  f.host.aboutToAppear(); await settle();
  const entry = Array.from(f.timers.entries())[0]; assert.equal(entry[1].delay, 150);
  f.host.aboutToDisappear();
  assert.deepEqual(f.cleared, [entry[0]]); assert.equal(f.timers.size, 0);
  entry[1].callback(); await settle();
  assert.equal(f.events.filter(event => event[0] === 'getLastWindow').length, 1);
  assert.equal(f.closed(), 0);
});
test('a second window initialization failure closes safely after one retry without exposing unsafe controls', async () => {
  const f = fixture(); f.config.getWindow = async () => { throw new Error('fixture unavailable'); };
  f.host.aboutToAppear(); await settle();
  const scheduled = Array.from(f.timers.values())[0]; scheduled.callback(); await settle();
  assert.equal(f.events.filter(event => event[0] === 'getLastWindow').length, 2);
  assert.equal(f.closed(), 1); assert.equal(f.toasts.length, 1);
  assert.equal(f.host.safeAreaReady, false);
});

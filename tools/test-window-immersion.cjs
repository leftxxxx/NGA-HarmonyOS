'use strict';

// Execute the actual EntryAbility; only the window, settings, and kit boundaries are mocked.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const loaderRoot = path.join(process.env.DEVECO_HOME || 'D:/software/DevEco Studio',
  'sdk/default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.TYPESCRIPT_PATH || path.join(loaderRoot, 'node_modules/typescript'));
const filename = path.resolve(__dirname, '../entry/src/main/ets/entryability/EntryAbility.ets');
const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  fileName: filename, reportDiagnostics: true,
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
});
assert.deepEqual((output.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error), []);
const themeFilename = path.resolve(__dirname, '../entry/src/main/ets/model/AppTheme.ets');
const themeContext = vm.createContext({ exports: {}, require: () => ({}) });
vm.runInContext(ts.transpileModule(fs.readFileSync(themeFilename, 'utf8'), { fileName: themeFilename,
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText, themeContext, { filename: themeFilename });
const topKey = themeContext.exports.WINDOW_TOP_SAFE_AREA_PX_KEY;
assert.equal(topKey, 'nga_window_top_safe_area_px');
const areaTypes = { TYPE_SYSTEM: 0, TYPE_NAVIGATION_INDICATOR: 1, TYPE_KEYBOARD: 2, TYPE_CUTOUT: 3 };
const settle = () => new Promise(resolve => setImmediate(resolve));

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

function fixture() {
  const events = [], logs = [], themes = [], loads = [], storageWrites = [];
  const storage = new Map(), listeners = new Set();
  const abilityContext = { getApplicationContext: () => ({ setColorMode() {} }) };
  const config = { nightMode: false, topPx: 137, failedRead: false, failedSubscribe: false,
    layout: async () => {}, theme: async () => {}, getWindow: undefined };
  const mainWindow = {
    setWindowLayoutFullScreen(enabled) {
      events.push(['layout', enabled]);
      return config.layout(enabled);
    },
    getWindowAvoidArea(type) {
      events.push(['get-avoid-area', type]);
      if (config.failedRead) throw new Error('safe area unavailable');
      return { topRect: { height: config.topPx } };
    },
    on(name, callback) {
      events.push(['on', name, callback]);
      if (config.failedSubscribe) throw new Error('listener unavailable');
      listeners.add(callback);
    },
    off(name, callback) { events.push(['off', name, callback]); listeners.delete(callback); }
  };
  config.getWindow = () => mainWindow;
  const stage = {
    getMainWindowSync() { events.push(['get-main-window']); return config.getWindow(); },
    loadContent(page, callback) { events.push(['load', page]); loads.push({ page, callback }); }
  };
  const hilog = Object.fromEntries(['info', 'warn', 'error'].map(level => [level,
    (...args) => { logs.push({ level, args }); } ]));
  const modules = {
    '@kit.AbilityKit': {
      UIAbility: class { constructor() { this.context = abilityContext; } },
      ConfigurationConstant: { ColorMode: { COLOR_MODE_DARK: 'dark', COLOR_MODE_LIGHT: 'light' } }
    },
    '@kit.ArkUI': { window: { AvoidAreaType: areaTypes } },
    '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26 } },
    '@kit.PerformanceAnalysisKit': { hilog },
    '../model/AppSettings': {
      SettingsStore: {
        init(context) { events.push(['settings-init', context]); },
        isNightMode() { events.push(['get-night-mode']); return config.nightMode; }
      },
      SettingKeys: { NIGHT: 'night-mode' }, SettingDefaults: { NIGHT: false }
    },
    '../model/AppTheme': {
      WINDOW_TOP_SAFE_AREA_PX_KEY: topKey,
      applyApplicationColorMode(context) { events.push(['application-color-mode', context]); },
      applyWindowTheme(context, nightMode) {
        events.push(['theme']); themes.push({ context, nightMode }); return config.theme();
      }
    }
  };
  const context = vm.createContext({ exports: {}, AppStorage: {
    setOrCreate(key, value) { storageWrites.push([key, value]); storage.set(key, value); }
  }, require(name) {
    assert.ok(Object.hasOwn(modules, name), 'Unexpected runtime dependency: ' + name);
    return modules[name];
  } });
  vm.runInContext(output.outputText, context, { filename });
  const ability = new context.exports.default();
  const emit = (type, height) => {
    for (const callback of listeners) callback({ type, area: { topRect: { height } } });
  };
  return { ability, stage, config, events, logs, themes, loads, abilityContext,
    mainWindow, storage, storageWrites, listeners, emit };
}

test('content waits for immersive layout and theme, in that order, before its first load', async () => {
  const f = fixture(), layout = deferred(), theme = deferred();
  f.config.layout = () => layout.promise;
  f.config.theme = () => theme.promise;
  const pending = f.ability.loadMainPage(f.stage);
  assert.deepEqual(f.events, [['get-main-window'], ['layout', true]]);
  await settle();
  assert.equal(f.themes.length, 0);
  assert.equal(f.loads.length, 0);
  layout.resolve(); await settle();
  assert.equal(f.themes.length, 1);
  assert.equal(f.loads.length, 0);
  assert.deepEqual(f.events.map(event => event[0]),
    ['get-main-window', 'layout', 'get-avoid-area', 'on', 'get-night-mode', 'theme']);
  theme.resolve(); await pending;
  assert.deepEqual(f.loads.map(load => load.page), ['pages/Index']);
  assert.equal(f.events.at(-1)[0], 'load');
});

test('a rejected immersive-layout request still waits for theme and then loads the page', async () => {
  const f = fixture(), theme = deferred();
  f.config.layout = async enabled => { if (enabled) throw new Error('layout temporarily unavailable'); };
  f.config.theme = () => theme.promise;
  const pending = f.ability.loadMainPage(f.stage);
  await settle();
  assert.equal(f.logs.filter(log => log.level === 'warn').length, 1);
  assert.equal(f.themes.length, 1);
  assert.equal(f.loads.length, 0);
  theme.resolve(); await pending;
  assert.deepEqual(f.loads.map(load => load.page), ['pages/Index']);
});

test('a synchronous window lookup failure still applies theme and loads content once', async () => {
  const f = fixture();
  f.config.getWindow = () => { throw new Error('window not ready'); };
  await f.ability.loadMainPage(f.stage);
  assert.deepEqual(f.events.map(event => event[0]), ['get-main-window', 'get-night-mode', 'theme', 'load']);
  assert.equal(f.logs.filter(log => log.level === 'warn').length, 1);
  assert.equal(f.themes.length, 1);
  assert.equal(f.loads.length, 1);
});

test('window theme receives the actual ability context and saved day or night preference', async () => {
  for (const nightMode of [false, true]) {
    const f = fixture(); f.config.nightMode = nightMode;
    await f.ability.loadMainPage(f.stage);
    assert.equal(f.themes[0].context, f.abilityContext);
    assert.equal(f.themes[0].nightMode, nightMode);
    assert.deepEqual(f.events.find(event => event[0] === 'get-night-mode'), ['get-night-mode']);
  }
});

test('a nonzero loadContent error is logged without reporting successful content loading', async () => {
  const f = fixture(); await f.ability.loadMainPage(f.stage);
  const error = { code: 1001, message: 'test load failure' };
  f.loads[0].callback(error);
  const logs = f.logs.filter(log => log.level === 'error');
  assert.equal(logs.length, 1);
  assert.ok(logs[0].args[2].includes('Failed to load the content'));
  assert.equal(logs[0].args[3], JSON.stringify(error));
  assert.equal(f.logs.filter(log => log.level === 'info').length, 0);
});

test('a successful loadContent callback reports success without an error or a second load', async () => {
  const f = fixture(); await f.ability.loadMainPage(f.stage);
  f.loads[0].callback({ code: 0 });
  assert.equal(f.logs.filter(log => log.level === 'error').length, 0);
  assert.equal(f.logs.filter(log => log.level === 'info' &&
    log.args[2].includes('Succeeded in loading the content')).length, 1);
  assert.equal(f.loads.length, 1);
});

test('the actual onWindowStageCreate entry point starts initialization before loading content', async () => {
  const f = fixture(), layout = deferred(), theme = deferred();
  f.config.layout = () => layout.promise;
  f.config.theme = () => theme.promise;
  f.ability.onWindowStageCreate(f.stage);
  assert.deepEqual(f.events, [['get-main-window'], ['layout', true]]);
  assert.equal(f.loads.length, 0);
  assert.equal(f.logs.filter(log => log.level === 'info' &&
    log.args.includes('Ability onWindowStageCreate')).length, 1);
  layout.resolve(); await settle();
  assert.equal(f.themes.length, 1);
  assert.equal(f.loads.length, 0);
  theme.resolve(); await settle();
  assert.deepEqual(f.loads.map(load => load.page), ['pages/Index']);
});

test('the initial top inset is published in pixels before theme or content, without clearing unrelated storage', async () => {
  const f = fixture(), layout = deferred(), theme = deferred();
  f.storage.set('unrelated-setting', 'preserved');
  f.storage.set(topKey, 900);
  f.config.layout = () => layout.promise;
  f.config.theme = () => theme.promise;
  const pending = f.ability.loadMainPage(f.stage);
  assert.equal(f.storage.get(topKey), 0);
  layout.resolve(); await settle();
  assert.equal(f.storage.get(topKey), 137);
  assert.equal(f.themes.length, 1);
  assert.equal(f.loads.length, 0);
  assert.equal(f.listeners.size, 1);
  assert.equal(f.storage.get('unrelated-setting'), 'preserved');
  theme.resolve(); await pending;
  assert.deepEqual(f.storageWrites, [[topKey, 0], [topKey, 137]]);
});

test('only system avoid-area events update the top inset, using the event value rather than stale queries', async () => {
  const f = fixture(); await f.ability.loadMainPage(f.stage);
  const reads = f.events.filter(event => event[0] === 'get-avoid-area').length;
  f.emit(areaTypes.TYPE_SYSTEM, 260);
  assert.equal(f.storage.get(topKey), 260);
  for (const type of [areaTypes.TYPE_NAVIGATION_INDICATOR, areaTypes.TYPE_KEYBOARD, areaTypes.TYPE_CUTOUT]) {
    f.emit(type, 999);
    assert.equal(f.storage.get(topKey), 260);
  }
  f.emit(areaTypes.TYPE_SYSTEM, 0);
  assert.equal(f.storage.get(topKey), 0);
  assert.equal(f.events.filter(event => event[0] === 'get-avoid-area').length, reads);
});

test('stage destruction removes exactly its listener and ignores late callbacks', async () => {
  const f = fixture(); await f.ability.loadMainPage(f.stage);
  const registration = f.events.find(event => event[0] === 'on');
  f.ability.onWindowStageDestroy();
  assert.equal(f.listeners.size, 0);
  assert.equal(f.storage.get(topKey), 0);
  assert.equal(f.events.find(event => event[0] === 'off')[2], registration[2]);
  const writes = f.storageWrites.length;
  registration[2]({ type: areaTypes.TYPE_SYSTEM, area: { topRect: { height: 400 } } });
  assert.equal(f.storageWrites.length, writes);
  assert.equal(f.storage.get(topKey), 0);
});

test('a new stage clears the old inset and prevents its old callback from overwriting the new window', async () => {
  const f = fixture(); await f.ability.loadMainPage(f.stage);
  const previous = f.events.find(event => event[0] === 'on')[2];
  const layout = deferred(); f.config.layout = () => layout.promise;
  f.config.topPx = 64;
  const pending = f.ability.loadMainPage(f.stage);
  assert.equal(f.storage.get(topKey), 0);
  assert.equal(f.listeners.size, 0);
  previous({ type: areaTypes.TYPE_SYSTEM, area: { topRect: { height: 400 } } });
  assert.equal(f.storage.get(topKey), 0);
  layout.resolve(); await pending;
  assert.equal(f.storage.get(topKey), 64);
  assert.equal(f.listeners.size, 1);
  previous({ type: areaTypes.TYPE_SYSTEM, area: { topRect: { height: 500 } } });
  assert.equal(f.storage.get(topKey), 64);
  f.emit(areaTypes.TYPE_SYSTEM, 72);
  assert.equal(f.storage.get(topKey), 72);
});

test('safe-area reading failure waits for native-layout restoration before theme and content', async () => {
  const f = fixture(), restoration = deferred();
  f.config.failedRead = true;
  f.config.layout = enabled => enabled ? Promise.resolve() : restoration.promise;
  const pending = f.ability.loadMainPage(f.stage);
  await settle();
  assert.deepEqual(f.events.filter(event => event[0] === 'layout'), [['layout', true], ['layout', false]]);
  assert.equal(f.storage.get(topKey), 0);
  assert.equal(f.listeners.size, 0);
  assert.equal(f.themes.length, 0);
  assert.equal(f.loads.length, 0);
  restoration.resolve(); await pending;
  assert.equal(f.themes.length, 1);
  assert.equal(f.loads.length, 1);
  assert.equal(f.logs.filter(log => log.level === 'warn').length, 1);
});

test('listener initialization failure resets the inset and restores native layout without preventing the page load', async () => {
  const f = fixture(); f.config.failedSubscribe = true;
  await f.ability.loadMainPage(f.stage);
  assert.equal(f.storage.get(topKey), 0);
  assert.equal(f.listeners.size, 0);
  assert.deepEqual(f.events.filter(event => event[0] === 'layout'), [['layout', true], ['layout', false]]);
  assert.equal(f.themes.length, 1);
  assert.equal(f.loads.length, 1);
});

test('a stage destroyed while layout or theme is pending never loads content or registers a late listener', async () => {
  for (const gate of ['layout', 'theme']) {
    const f = fixture(), pendingGate = deferred();
    f.config[gate] = () => pendingGate.promise;
    const pending = f.ability.loadMainPage(f.stage);
    await settle();
    f.ability.onWindowStageDestroy();
    const writes = f.storageWrites.length;
    pendingGate.resolve(); await pending;
    assert.equal(f.listeners.size, 0);
    assert.equal(f.loads.length, 0);
    assert.equal(f.storage.get(topKey), 0);
    assert.equal(f.storageWrites.length, writes);
  }
});

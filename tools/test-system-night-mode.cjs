'use strict';

// Run the application settings/theme code, mocking only platform and persistence boundaries.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const loaderRoot = path.join(process.env.DEVECO_HOME || 'D:/software/DevEco Studio',
  'sdk/default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.TYPESCRIPT_PATH || path.join(loaderRoot, 'node_modules/typescript'));
const etsRoot = path.resolve(__dirname, '../entry/src/main/ets');
const colorMode = { COLOR_MODE_NOT_SET: -1, COLOR_MODE_DARK: 0, COLOR_MODE_LIGHT: 1 };

function loadEts(relativePath, modules, globals = {}) {
  const filename = path.join(etsRoot, relativePath);
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  });
  assert.deepEqual((output.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error), []);
  const sandbox = vm.createContext({ exports: {}, ...globals, require(name) {
    assert.ok(Object.hasOwn(modules, name), 'Unexpected runtime dependency: ' + name);
    return modules[name];
  } });
  vm.runInContext(output.outputText, sandbox, { filename });
  return sandbox.exports;
}

function settingsFixture(backing = new Map()) {
  const events = [], storage = new Map();
  const preference = {
    hasSync(key) { return backing.has(key); },
    getSync(key, fallback) { return backing.has(key) ? backing.get(key) : fallback; },
    putSync(key, value) { events.push(['put', key, value]); backing.set(key, value); },
    deleteSync(key) { events.push(['delete', key]); backing.delete(key); },
    flush() { events.push(['flush']); return Promise.resolve(); }
  };
  const globals = { AppStorage: {
    setOrCreate(key, value) { events.push(['publish', key, value]); storage.set(key, value); },
    get(key) { return storage.get(key); }
  } };
  const exports = loadEts('model/AppSettings.ets', {
    '@kit.ArkData': { preferences: {
      getPreferencesSync(context, options) { events.push(['open', options.name]); return preference; }
    } },
    '@kit.AbilityKit': { ConfigurationConstant: { ColorMode: colorMode } }
  }, globals);
  const context = {};
  exports.SettingsStore.init(context);
  return { ...exports, context, backing, storage, events, globals };
}

function assertAppearance(f, policy, dark) {
  assert.equal(f.SettingsStore.getNightModePolicy(), policy);
  assert.equal(f.SettingsStore.isNightMode(), dark);
  assert.equal(f.storage.get(f.NIGHT_MODE_STORAGE_KEY), dark,
    'all mounted pages must receive the effective theme through shared storage');
  assert.equal(f.storage.get(f.NIGHT_POLICY_STORAGE_KEY), policy);
}

test('new installs follow the system and missing configuration has a stable light fallback', () => {
  const f = settingsFixture();
  f.SettingsStore.initializeAppearance();
  assert.equal(f.SettingDefaults.NIGHT_MODE, f.NightModePolicy.SYSTEM);
  assert.equal(f.NIGHT_MODE_STORAGE_KEY, 'nga_night_mode');
  assert.equal(f.NIGHT_POLICY_STORAGE_KEY, 'nga_night_mode_policy');
  assertAppearance(f, f.NightModePolicy.SYSTEM, false);
  f.SettingsStore.updateSystemColorMode(colorMode.COLOR_MODE_DARK);
  assertAppearance(f, f.NightModePolicy.SYSTEM, true);
});

test('legacy boolean night preferences migrate once without losing unrelated settings', () => {
  for (const oldNight of [false, true]) {
    const backing = new Map([['nightmode', oldNight], ['nga_domain', 2], ['topic_content_size', 3]]);
    const f = settingsFixture(backing);
    f.SettingsStore.initializeAppearance(colorMode.COLOR_MODE_LIGHT);
    const expected = oldNight ? f.NightModePolicy.DARK : f.NightModePolicy.LIGHT;
    assertAppearance(f, expected, oldNight);
    assert.equal(backing.get(f.SettingKeys.NIGHT_MODE), expected);
    assert.equal(backing.get('nga_domain'), 2);
    assert.equal(backing.get('topic_content_size'), 3);
    const writes = f.events.filter(event => event[0] === 'put').length;
    f.SettingsStore.init(f.context);
    assert.equal(f.events.filter(event => event[0] === 'put').length, writes, 'init must be idempotent');
    backing.set('nightmode', !oldNight);
    const restarted = settingsFixture(backing);
    restarted.SettingsStore.initializeAppearance(colorMode.COLOR_MODE_LIGHT);
    assertAppearance(restarted, expected, oldNight);
  }
});

test('an explicit saved policy takes precedence over a stale legacy night value', () => {
  const f = settingsFixture(new Map([['night_mode_policy', 0], ['nightmode', true]]));
  f.SettingsStore.initializeAppearance(colorMode.COLOR_MODE_LIGHT);
  assertAppearance(f, f.NightModePolicy.SYSTEM, false);
});

test('system policy reacts immediately to real light and dark changes', () => {
  const f = settingsFixture();
  f.SettingsStore.initializeAppearance(colorMode.COLOR_MODE_DARK);
  assertAppearance(f, f.NightModePolicy.SYSTEM, true);
  for (const mode of [colorMode.COLOR_MODE_LIGHT, colorMode.COLOR_MODE_DARK, colorMode.COLOR_MODE_LIGHT]) {
    f.SettingsStore.updateSystemColorMode(mode);
    assertAppearance(f, f.NightModePolicy.SYSTEM, mode === colorMode.COLOR_MODE_DARK);
  }
});

test('manual policies remain fixed but returning to system uses its latest real appearance', () => {
  const f = settingsFixture();
  f.SettingsStore.initializeAppearance(colorMode.COLOR_MODE_LIGHT);
  f.SettingsStore.setNightModePolicy(f.NightModePolicy.LIGHT);
  f.SettingsStore.updateSystemColorMode(colorMode.COLOR_MODE_DARK);
  assertAppearance(f, f.NightModePolicy.LIGHT, false);
  f.SettingsStore.setNightModePolicy(f.NightModePolicy.SYSTEM);
  assertAppearance(f, f.NightModePolicy.SYSTEM, true);
  f.SettingsStore.setNightModePolicy(f.NightModePolicy.DARK);
  f.SettingsStore.updateSystemColorMode(colorMode.COLOR_MODE_LIGHT);
  assertAppearance(f, f.NightModePolicy.DARK, true);
  f.SettingsStore.setNightModePolicy(f.NightModePolicy.SYSTEM);
  assertAppearance(f, f.NightModePolicy.SYSTEM, false);
});

test('undefined, unset and malformed color notifications do not overwrite a known system appearance', () => {
  const f = settingsFixture();
  f.SettingsStore.initializeAppearance(colorMode.COLOR_MODE_DARK);
  for (const mode of [undefined, -1, 2, NaN, '0', null]) {
    f.SettingsStore.updateSystemColorMode(mode);
    assertAppearance(f, f.NightModePolicy.SYSTEM, true);
  }
  f.SettingsStore.setNightModePolicy(f.NightModePolicy.LIGHT);
  f.SettingsStore.updateSystemColorMode(-1);
  f.SettingsStore.setNightModePolicy(f.NightModePolicy.SYSTEM);
  assertAppearance(f, f.NightModePolicy.SYSTEM, true);
});

test('all three policies persist across a fresh settings instance and startup configuration', () => {
  for (const policy of [0, 1, 2]) {
    const backing = new Map(), f = settingsFixture(backing);
    f.SettingsStore.initializeAppearance(colorMode.COLOR_MODE_LIGHT);
    f.SettingsStore.setNightModePolicy(policy);
    const restarted = settingsFixture(backing);
    restarted.SettingsStore.initializeAppearance(colorMode.COLOR_MODE_DARK);
    assertAppearance(restarted, policy, policy !== restarted.NightModePolicy.LIGHT);
    assert.ok(f.events.some(event => event[0] === 'flush'), 'changed policy must be flushed');
  }
});

test('invalid stored policies fall back to system and invalid user inputs cannot break appearance', () => {
  for (const bad of [-1, 3, 'dark', null]) {
    const f = settingsFixture(new Map([['night_mode_policy', bad]]));
    f.SettingsStore.initializeAppearance(colorMode.COLOR_MODE_DARK);
    assertAppearance(f, f.NightModePolicy.SYSTEM, true);
    f.SettingsStore.setNightModePolicy(f.NightModePolicy.LIGHT);
    f.SettingsStore.setNightModePolicy(bad);
    assertAppearance(f, f.NightModePolicy.SYSTEM, true);
  }
});

function themeFixture(f, suppliedContext) {
  const calls = [], logs = [];
  const mainWindow = {
    setWindowBackgroundColor(value) { calls.push(['background', value]); },
    async setWindowSystemBarProperties(value) { calls.push(['bars', value]); }
  };
  const context = suppliedContext || {
    getApplicationContext: () => ({ setColorMode(value) { calls.push(['app-color-mode', value]); } })
  };
  const theme = loadEts('model/AppTheme.ets', {
    '@kit.AbilityKit': { ConfigurationConstant: { ColorMode: colorMode } },
    '@kit.ArkUI': { window: { getLastWindow: async () => mainWindow } },
    '@kit.PerformanceAnalysisKit': { hilog: { error(...args) { logs.push(args); } } },
    './AppSettings': f
  });
  return { theme, calls, logs, context, mainWindow };
}

test('native application color mode implements system, light and dark policies distinctly', () => {
  const f = settingsFixture(); f.SettingsStore.initializeAppearance(colorMode.COLOR_MODE_LIGHT);
  const t = themeFixture(f);
  for (const [policy, platformMode] of [[0, -1], [1, 1], [2, 0]]) {
    f.SettingsStore.setNightModePolicy(policy);
    t.theme.applyApplicationColorMode(t.context);
    assert.deepEqual(t.calls.at(-1), ['app-color-mode', platformMode]);
  }
});

test('window palette updates preserve transparent system bars and never override the app policy', async () => {
  const f = settingsFixture(); f.SettingsStore.initializeAppearance(colorMode.COLOR_MODE_LIGHT);
  const t = themeFixture(f);
  for (const dark of [false, true]) {
    t.calls.length = 0;
    await t.theme.applyWindowTheme(t.context, dark);
    assert.equal(t.calls.filter(call => call[0] === 'app-color-mode').length, 0);
    assert.equal(t.calls.find(call => call[0] === 'background')[1],
      dark ? t.theme.COLOR_NIGHT_BG : t.theme.COLOR_DAY_BG);
    const bars = t.calls.find(call => call[0] === 'bars')[1];
    assert.equal(bars.statusBarColor, '#00000000');
    assert.equal(bars.navigationBarColor, '#00000000');
    assert.equal(bars.statusBarContentColor, dark ? t.theme.COLOR_NIGHT_TEXT : t.theme.COLOR_DAY_TEXT);
  }
  assert.equal(t.logs.length, 0);
});

function abilityFixture({ sdk = 26, initialMode = colorMode.COLOR_MODE_LIGHT, policy = 0 } = {}) {
  const f = settingsFixture(new Map([['night_mode_policy', policy]]));
  const appCalls = [], listeners = new Set(), logs = [], loads = [];
  const appContext = {
    setColorMode(mode) { appCalls.push(['color-mode', mode]); },
    onSystemConfigurationUpdated(callback) { appCalls.push(['subscribe', callback]); listeners.add(callback); },
    offSystemConfigurationUpdated(callback) { appCalls.push(['unsubscribe', callback]); listeners.delete(callback); }
  };
  const context = { config: { colorMode: initialMode }, getApplicationContext: () => appContext };
  const t = themeFixture(f, context);
  Object.assign(t.mainWindow, {
    setWindowLayoutFullScreen: async () => {},
    getWindowAvoidArea: () => ({ topRect: { height: 100 } }),
    on() {}, off() {}
  });
  const modules = {
    '@kit.AbilityKit': {
      UIAbility: class { constructor() { this.context = context; } },
      ConfigurationConstant: { ColorMode: colorMode }
    },
    '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: sdk } },
    '@kit.PerformanceAnalysisKit': { hilog: Object.fromEntries(['info', 'warn', 'error'].map(level =>
      [level, (...args) => logs.push({ level, args })])) },
    '@kit.ArkUI': { window: { AvoidAreaType: { TYPE_SYSTEM: 0 } } },
    '../model/AppSettings': f,
    '../model/AppTheme': t.theme
  };
  const entry = loadEts('entryability/EntryAbility.ets', modules, f.globals);
  const ability = new entry.default();
  const stage = {
    getMainWindowSync: () => t.mainWindow,
    loadContent(page, callback) { loads.push({ page, callback }); }
  };
  const emit = mode => { for (const callback of listeners) callback.onColorModeUpdated(mode); };
  return { ...f, ...t, ability, stage, appCalls, listeners, logs, loads, emit };
}

const settle = () => new Promise(resolve => setImmediate(resolve));
const appModes = f => f.appCalls.filter(call => call[0] === 'color-mode').map(call => call[1]);

async function mount(f) {
  f.ability.onCreate({}, {});
  await f.ability.loadMainPage(f.stage);
  f.loads.at(-1).callback({ code: 0 });
  await settle();
}

test('startup reads the initial system appearance without setting native app mode before content is ready', async () => {
  for (const policy of [0, 1, 2]) {
    const f = abilityFixture({ initialMode: colorMode.COLOR_MODE_DARK, policy });
    f.ability.onCreate({}, {});
    assertAppearance(f, policy, policy !== f.NightModePolicy.LIGHT);
    assert.deepEqual(appModes(f), []);
    await f.ability.loadMainPage(f.stage);
    assert.deepEqual(appModes(f), []);
    assert.equal(f.loads[0].page, 'pages/Index');
    f.loads[0].callback({ code: 0 });
    await settle();
    assert.deepEqual(appModes(f), [policy === 0 ? -1 : policy === 1 ? 1 : 0]);
  }
});

test('a failed or stale content callback cannot apply native app color mode', async () => {
  const failed = abilityFixture();
  failed.ability.onCreate({}, {});
  await failed.ability.loadMainPage(failed.stage);
  failed.loads[0].callback({ code: 1001, message: 'failed' });
  assert.deepEqual(appModes(failed), []);
  const stale = abilityFixture();
  stale.ability.onCreate({}, {});
  await stale.ability.loadMainPage(stale.stage);
  stale.ability.onWindowStageDestroy();
  stale.loads[0].callback({ code: 0 });
  assert.deepEqual(appModes(stale), []);
});

test('API 24+ observes true system changes and app configuration overrides cannot contaminate them', async () => {
  for (const sdk of [24, 26]) {
    const f = abilityFixture({ sdk }); await mount(f);
    assert.equal(f.listeners.size, 1);
    f.SettingsStore.setNightModePolicy(f.NightModePolicy.LIGHT);
    f.emit(colorMode.COLOR_MODE_DARK);
    assertAppearance(f, f.NightModePolicy.LIGHT, false);
    f.ability.onConfigurationUpdate({ colorMode: colorMode.COLOR_MODE_LIGHT });
    f.SettingsStore.setNightModePolicy(f.NightModePolicy.SYSTEM);
    assertAppearance(f, f.NightModePolicy.SYSTEM, true);
    f.emit(colorMode.COLOR_MODE_LIGHT); await settle();
    assertAppearance(f, f.NightModePolicy.SYSTEM, false);
    assert.equal(f.calls.filter(call => call[0] === 'background').at(-1)[1], f.theme.COLOR_DAY_BG);
  }
});

test('a system change during first page loading is retained and window styling catches up after readiness', async () => {
  const f = abilityFixture(); f.ability.onCreate({}, {});
  await f.ability.loadMainPage(f.stage);
  const windowsBeforeChange = f.calls.filter(call => call[0] === 'background').length;
  f.emit(colorMode.COLOR_MODE_DARK); await settle();
  assertAppearance(f, f.NightModePolicy.SYSTEM, true);
  assert.equal(f.calls.filter(call => call[0] === 'background').length, windowsBeforeChange,
    'system updates must not touch unready content');
  assert.deepEqual(appModes(f), []);
  f.loads[0].callback({ code: 0 }); await settle();
  assert.deepEqual(appModes(f), [-1]);
  assert.equal(f.calls.filter(call => call[0] === 'background').at(-1)[1], f.theme.COLOR_NIGHT_BG);
});

test('API 21-23 configuration fallback updates system policy and ignores manual application overrides', async () => {
  for (const sdk of [21, 23]) {
    const f = abilityFixture({ sdk }); await mount(f);
    assert.equal(f.listeners.size, 0);
    f.ability.onConfigurationUpdate({ colorMode: colorMode.COLOR_MODE_DARK });
    assertAppearance(f, f.NightModePolicy.SYSTEM, true);
    f.SettingsStore.setNightModePolicy(f.NightModePolicy.LIGHT);
    f.ability.onConfigurationUpdate({ colorMode: colorMode.COLOR_MODE_LIGHT });
    assertAppearance(f, f.NightModePolicy.LIGHT, false);
    f.SettingsStore.setNightModePolicy(f.NightModePolicy.SYSTEM);
    assertAppearance(f, f.NightModePolicy.SYSTEM, true);
  }
});

test('repeated foreground refreshes window colors without reapplying the native application policy', async () => {
  const modern = abilityFixture(); await mount(modern);
  modern.emit(colorMode.COLOR_MODE_DARK);
  modern.SettingsStore.setNightModePolicy(modern.NightModePolicy.LIGHT);
  modern.theme.applyApplicationColorMode(modern.ability.context);
  modern.ability.context.config.colorMode = colorMode.COLOR_MODE_LIGHT;
  for (let count = 0; count < 3; count++) {
    modern.ability.onForeground(); await settle();
  }
  assert.deepEqual(appModes(modern), [-1, 1]);
  assertAppearance(modern, modern.NightModePolicy.LIGHT, false);
  assert.equal(modern.calls.filter(call => call[0] === 'background').at(-1)[1], modern.theme.COLOR_DAY_BG);
  modern.SettingsStore.setNightModePolicy(modern.NightModePolicy.SYSTEM);
  modern.theme.applyApplicationColorMode(modern.ability.context);
  for (let count = 0; count < 3; count++) {
    modern.ability.onForeground(); await settle();
  }
  assertAppearance(modern, modern.NightModePolicy.SYSTEM, true);
  assert.deepEqual(appModes(modern), [-1, 1, -1]);
  assert.equal(modern.calls.filter(call => call[0] === 'background').at(-1)[1], modern.theme.COLOR_NIGHT_BG);
});

test('API 21-23 foreground refreshes follow-system appearance without resetting the native policy', async () => {
  for (const sdk of [21, 23]) {
    const fallback = abilityFixture({ sdk }); await mount(fallback);
    for (const systemMode of [colorMode.COLOR_MODE_DARK, colorMode.COLOR_MODE_LIGHT]) {
      fallback.ability.context.config.colorMode = systemMode;
      fallback.ability.onForeground(); await settle();
      const dark = systemMode === colorMode.COLOR_MODE_DARK;
      assertAppearance(fallback, fallback.NightModePolicy.SYSTEM, dark);
      assert.equal(fallback.calls.filter(call => call[0] === 'background').at(-1)[1],
        dark ? fallback.theme.COLOR_NIGHT_BG : fallback.theme.COLOR_DAY_BG);
      assert.deepEqual(appModes(fallback), [-1]);
    }
    fallback.SettingsStore.setNightModePolicy(fallback.NightModePolicy.DARK);
    fallback.theme.applyApplicationColorMode(fallback.ability.context);
    fallback.ability.context.config.colorMode = colorMode.COLOR_MODE_LIGHT;
    fallback.ability.onForeground(); await settle();
    assertAppearance(fallback, fallback.NightModePolicy.DARK, true);
    assert.deepEqual(appModes(fallback), [-1, 0]);
  }
});

test('foreground never applies application policy before content loads or after its stage is destroyed', async () => {
  const f = abilityFixture(); f.ability.onCreate({}, {});
  f.ability.onForeground(); await settle();
  await f.ability.loadMainPage(f.stage);
  f.ability.onForeground(); await settle();
  assert.deepEqual(appModes(f), []);
  f.loads[0].callback({ code: 0 }); await settle();
  f.ability.onWindowStageDestroy();
  const windowCalls = f.calls.length;
  f.ability.onForeground(); await settle();
  assert.deepEqual(appModes(f), [-1]);
  assert.equal(f.calls.length, windowCalls);
});

test('a recreated stage applies each selected native policy only after its own successful content load', async () => {
  for (const policy of [0, 1, 2]) {
    const f = abilityFixture({ policy }); await mount(f);
    const nativeMode = policy === 0 ? -1 : policy === 1 ? 1 : 0;
    const oldLoad = f.loads[0];
    f.ability.onWindowStageDestroy();
    await f.ability.loadMainPage(f.stage);
    f.ability.onForeground(); await settle();
    oldLoad.callback({ code: 0 }); await settle();
    assert.deepEqual(appModes(f), [nativeMode]);
    f.loads.at(-1).callback({ code: 0 }); await settle();
    assert.deepEqual(appModes(f), [nativeMode, nativeMode]);
    f.ability.onForeground(); await settle();
    assert.deepEqual(appModes(f), [nativeMode, nativeMode]);
  }
});

test('ability destruction unregisters its own system callback exactly once', async () => {
  const f = abilityFixture(); await mount(f);
  const registered = f.appCalls.find(call => call[0] === 'subscribe')[1];
  f.ability.onDestroy();
  assert.equal(f.listeners.size, 0);
  assert.equal(f.appCalls.find(call => call[0] === 'unsubscribe')[1], registered);
  f.ability.onDestroy();
  assert.equal(f.appCalls.filter(call => call[0] === 'unsubscribe').length, 1);
  const previous = f.SettingsStore.isNightMode();
  f.emit(colorMode.COLOR_MODE_DARK);
  assert.equal(f.SettingsStore.isNightMode(), previous);
});

test('every routed page observes shared appearance and does not read the legacy night boolean', () => {
  const pages = JSON.parse(fs.readFileSync(path.join(etsRoot, '../resources/base/profile/main_pages.json'), 'utf8')).src;
  assert.ok(pages.length >= 15);
  for (const page of pages) {
    const source = fs.readFileSync(path.join(etsRoot, page + '.ets'), 'utf8');
    assert.match(source, /@StorageLink\(NIGHT_MODE_STORAGE_KEY\)(?:\s*@Watch\([^)]*\))?\s+nightMode\s*:\s*boolean/,
      page + ' must react while mounted to a system appearance change');
    assert.doesNotMatch(source, /getBool\(SettingKeys\.NIGHT\b/,
      page + ' must not replace the effective theme with the migrated legacy preference');
  }
});

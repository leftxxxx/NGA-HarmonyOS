'use strict';

/* Run: node --test tools/test-topic-action-material.cjs
 * Execute the real ETS modifier and shared theme through the DevEco compiler.
 * Native capability mocks verify fallback without connecting to a device.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const devecoHome = process.env.DEVECO_HOME || 'D:/software/DevEco Studio';
const compilerPath = process.env.TYPESCRIPT_PATH || path.join(devecoHome,
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
assert.ok(fs.existsSync(compilerPath), 'Set DEVECO_HOME or TYPESCRIPT_PATH to the DevEco SDK compiler');
const ts = require(compilerPath);

function compile(relativePath) {
  const filename = path.resolve(__dirname, relativePath);
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  const errors = (result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
  assert.deepEqual(errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
  return vm.runInThisContext('(function(require, module, exports, BlurStyle, ThemeColorMode, Color) {\n' +
    result.outputText + '\n})', { filename });
}

const evaluateModifier = compile('../entry/src/main/ets/components/TopicUiStyle.ets');
const evaluateTheme = compile('../entry/src/main/ets/model/AppTheme.ets');
const BlurStyle = { COMPONENT_REGULAR: Symbol('regular blur') };
const ThemeColorMode = { DARK: Symbol('dark theme'), LIGHT: Symbol('light theme') };
const Color = { White: '#ffffffff' };
const themeModule = { exports: {} };
evaluateTheme(id => {
  if (id === '@kit.AbilityKit' || id === '@kit.ArkUI' || id === '@kit.PerformanceAnalysisKit') return {};
  if (id === './AppSettings') return {
    NightModePolicy: { SYSTEM: 0, LIGHT: 1, DARK: 2 },
    SettingsStore: { getNightModePolicy() { assert.fail('Material colors must use their explicit appearance input'); } }
  };
  throw new Error('Unexpected theme dependency: ' + id);
}, themeModule, themeModule.exports, BlurStyle, ThemeColorMode, Color);

function createHarness(options = {}) {
  const sdkVersion = options.sdkVersion ?? 26;
  const calls = [];
  const capabilityCalls = [];
  const deviceInfo = { sdkApiVersion: sdkVersion };
  const emptyMaterial = { empty: true };
  const immersiveStyle = { THIN: Symbol('thin material') };
  let uiMaterial;
  if (sdkVersion < 26) {
    // These members do not exist on old systems; even probing them is a failure.
    uiMaterial = new Proxy({}, { get() { assert.fail('Old systems must not access API 26 material members'); } });
  } else {
    deviceInfo.apiAvailable = version => {
      capabilityCalls.push(['apiAvailable', version]);
      return options.apiAvailable ?? true;
    };
    uiMaterial = {
      ImmersiveStyle: immersiveStyle,
      Material: { empty: emptyMaterial },
      isImmersiveMaterialSupported() {
        capabilityCalls.push(['isImmersiveMaterialSupported']);
        if (options.queryError) throw new Error('Native material capability query failed');
        return options.supported ?? true;
      },
      ImmersiveMaterial: class {
        constructor(materialOptions) {
          capabilityCalls.push(['ImmersiveMaterial']);
          this.options = materialOptions;
        }
      }
    };
  }
  const row = {
    backgroundColor(color) { calls.push(['backgroundColor', color]); return this; },
    backgroundBlurStyle(style, blurOptions) { calls.push(['backgroundBlurStyle', style, blurOptions]); return this; },
    shadow(shadowOptions) { calls.push(['shadow', shadowOptions]); return this; }
  };
  if (sdkVersion >= 26) {
    row.systemMaterial = material => { calls.push(['systemMaterial', material]); return row; };
  }
  const module = { exports: {} };
  evaluateModifier(id => {
    if (id === '@kit.ArkUI') return { uiMaterial };
    if (id === '@kit.BasicServicesKit') return { deviceInfo };
    if (id === '../model/AppTheme') return themeModule.exports;
    throw new Error('Unexpected modifier dependency: ' + id);
  }, module, module.exports, BlurStyle, ThemeColorMode, Color);
  return {
    apply() { new module.exports.TopicActionMaterialModifier(options.nightMode ?? false).applyNormalAttribute(row); },
    calls, capabilityCalls, emptyMaterial, immersiveStyle
  };
}

function assertFallback(native, nightMode = false, clearsMaterial = false) {
  assert.deepEqual(native.calls.map(call => call[0]), clearsMaterial ?
    ['systemMaterial', 'backgroundColor', 'backgroundBlurStyle', 'shadow'] :
    ['backgroundColor', 'backgroundBlurStyle', 'shadow']);
  if (clearsMaterial) assert.equal(native.calls[0][1], native.emptyMaterial);
  const background = native.calls.find(call => call[0] === 'backgroundColor');
  assert.equal(background[1], themeModule.exports.themeMaterialSurfaceColor(nightMode, 0.9));
  const blur = native.calls.find(call => call[0] === 'backgroundBlurStyle');
  assert.equal(blur[1], BlurStyle.COMPONENT_REGULAR);
  assert.equal(blur[2].colorMode, nightMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT);
  assert.ok(native.calls.find(call => call[0] === 'shadow')[1].radius > 0);
}

test('old systems use fallback without probing API 26 members', () => {
  for (const sdkVersion of [12, 25]) {
    const native = createHarness({ sdkVersion });
    assert.doesNotThrow(() => native.apply());
    assert.deepEqual(native.capabilityCalls, []);
    assertFallback(native);
  }
});

test('API 26 with unavailable 26.0.0 never queries or constructs system material', () => {
  const native = createHarness({ apiAvailable: false });
  native.apply();
  assert.deepEqual(native.capabilityCalls, [['apiAvailable', '26.0.0']]);
  assertFallback(native);
});

test('supported material owns capsule surface, interaction and light feedback', () => {
  const native = createHarness();
  native.apply();
  assert.deepEqual(native.capabilityCalls, [
    ['apiAvailable', '26.0.0'], ['isImmersiveMaterialSupported'], ['ImmersiveMaterial']
  ]);
  assert.deepEqual(native.calls.map(call => call[0]), ['systemMaterial'],
    'Fallback surface attributes must not override the system material');
  assert.deepEqual(native.calls[0][1].options, {
    style: native.immersiveStyle.THIN,
    materialColor: themeModule.exports.themeMaterialSurfaceColor(false, 0.6),
    colorInvert: false, applyShadow: true, interactive: true,
    lightEffect: { color: Color.White }
  });
});

test('unsupported hardware clears previous material then restores readable capsule surface', () => {
  const native = createHarness({ supported: false });
  native.apply();
  assert.deepEqual(native.capabilityCalls, [['apiAvailable', '26.0.0'], ['isImmersiveMaterialSupported']]);
  assertFallback(native, false, true);
});

test('native capability query failure is contained and uses the same fallback', () => {
  const native = createHarness({ queryError: true, nightMode: true });
  assert.doesNotThrow(() => native.apply());
  assert.deepEqual(native.capabilityCalls, [['apiAvailable', '26.0.0'], ['isImmersiveMaterialSupported']]);
  assertFallback(native, true, true);
});

test('day and night material tint comes from the real shared theme at translucent alpha', () => {
  for (const nightMode of [false, true]) {
    const native = createHarness({ nightMode });
    native.apply();
    const tint = native.calls[0][1].options.materialColor;
    assert.equal(tint, themeModule.exports.themeMaterialSurfaceColor(nightMode, 0.6));
    assert.equal(tint.slice(1, 3), '99', 'Material tint stays translucent so it does not hide the filter');
    assert.equal(tint.slice(3), (nightMode ? themeModule.exports.COLOR_NIGHT_CARD :
      themeModule.exports.COLOR_DAY_CARD).slice(3));
  }
});

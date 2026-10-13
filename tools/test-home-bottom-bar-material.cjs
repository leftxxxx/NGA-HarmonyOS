'use strict';

/* Run: node --test tools/test-home-bottom-bar-material.cjs
 * Execute the actual homepage modifier with the DevEco compiler and native mocks.
 * These checks cover capability fallback and capsule bounds; simulator testing
 * is still required to verify the native light animation.
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
const homepagePath = path.resolve(__dirname, '../entry/src/main/ets/pages/Index.ets');
const homepageSource = fs.readFileSync(homepagePath, 'utf8');
const constantStart = homepageSource.indexOf('const HOME_FLOATING_BAR_HEIGHT:');
const modifierStart = homepageSource.indexOf('class HomeBottomBarModifier ');
const modifierEnd = homepageSource.indexOf('/* 添加板块对话框 */', modifierStart);
assert.ok(constantStart >= 0 && modifierStart > constantStart && modifierEnd > modifierStart,
  'Extract the real homepage modifier before the first UI component');

const modifierSource = [
  "import { uiMaterial } from '@kit.ArkUI';",
  "import { deviceInfo } from '@kit.BasicServicesKit';",
  "import { COLOR_DAY_BG, COLOR_NIGHT_BG, themeMaterialSurfaceColor } from '../model/AppTheme';",
  homepageSource.slice(constantStart, modifierEnd).replace(
    'class HomeBottomBarModifier ', 'export class HomeBottomBarModifier '),
  'export { HOME_FLOATING_BAR_BOTTOM_MARGIN };'
].join('\n');

function compile(source, filename) {
  const result = ts.transpileModule(source, {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  const errors = (result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
  assert.deepEqual(errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
  return vm.runInThisContext('(function(require, module, exports, BlurStyle, Color) {\n' +
    result.outputText + '\n})', { filename });
}

const evaluateModifier = compile(modifierSource, homepagePath);
const themePath = path.resolve(__dirname, '../entry/src/main/ets/model/AppTheme.ets');
const evaluateTheme = compile(fs.readFileSync(themePath, 'utf8'), themePath);
const BlurStyle = { NONE: Symbol('no compatibility blur') };
const Color = { Transparent: '#00000000', White: '#ffffffff' };
const themeModule = { exports: {} };
evaluateTheme(id => {
  if (['@kit.AbilityKit', '@kit.ArkUI', '@kit.PerformanceAnalysisKit'].includes(id)) return {};
  if (id === './AppSettings') return {
    NightModePolicy: { SYSTEM: 0, LIGHT: 1, DARK: 2 },
    SettingsStore: { getNightModePolicy() { assert.fail('Material colors must use their explicit appearance input'); } }
  };
  throw new Error('Unexpected theme dependency: ' + id);
}, themeModule, themeModule.exports, BlurStyle, Color);

function createHarness(options = {}) {
  const sdkVersion = options.sdkVersion ?? 26;
  const calls = [];
  const capabilityCalls = [];
  const emptyMaterial = { empty: true };
  const immersiveStyle = { THIN: Symbol('thin material') };
  const deviceInfo = { sdkApiVersion: sdkVersion };
  let uiMaterial;
  if (sdkVersion < 26 || options.apiAvailable === false) {
    uiMaterial = new Proxy({}, {
      get() { assert.fail('Unavailable API 26 members must not be accessed'); }
    });
  } else {
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
  if (sdkVersion >= 26) {
    deviceInfo.apiAvailable = version => {
      capabilityCalls.push(['apiAvailable', version]);
      return options.apiAvailable ?? true;
    };
  }
  const tabs = {
    barOverlap(enabled) { calls.push(['barOverlap', enabled]); return this; },
    barBackgroundColor(color) { calls.push(['barBackgroundColor', color]); return this; },
    barBackgroundBlurStyle(style) { calls.push(['barBackgroundBlurStyle', style]); return this; },
    safeAreaPadding(padding) { calls.push(['safeAreaPadding', padding]); return this; }
  };
  if (sdkVersion >= 26 && options.apiAvailable !== false) {
    tabs.barFloatingStyle = style => { calls.push(['barFloatingStyle', style]); return tabs; };
  }
  const module = { exports: {} };
  evaluateModifier(id => {
    if (id === '@kit.ArkUI') return { uiMaterial };
    if (id === '@kit.BasicServicesKit') return { deviceInfo };
    if (id === '../model/AppTheme') return themeModule.exports;
    throw new Error('Unexpected modifier dependency: ' + id);
  }, module, module.exports, BlurStyle, Color);
  return {
    apply(nightMode = options.nightMode ?? false, inset = options.inset ?? 0) {
      new module.exports.HomeBottomBarModifier(nightMode, inset).applyNormalAttribute(tabs);
    },
    calls, capabilityCalls, emptyMaterial, immersiveStyle,
    bottomMargin: module.exports.HOME_FLOATING_BAR_BOTTOM_MARGIN
  };
}

function lastCall(native, method) {
  return native.calls.filter(call => call[0] === method).at(-1);
}

function assertTransparentAvoidArea(native) {
  assert.equal(lastCall(native, 'barOverlap')[1], true);
  assert.deepEqual(lastCall(native, 'safeAreaPadding')[1], { bottom: 0 },
    'Tabs must not paint an additional bottom safe area');
}

function assertFloatingGeometry(native, inset) {
  assertTransparentAvoidArea(native);
  const style = lastCall(native, 'barFloatingStyle')[1];
  assert.deepEqual(style.barWidth, { smallBarWidth: 320, mediumBarWidth: 360, largeBarWidth: 400 });
  assert.equal(style.barSideMargin, 28);
  assert.equal(style.barBottomMargin, native.bottomMargin + inset);
  assert.equal(style.maskHeight, 0, 'The capsule must not restore a bottom mask strip');
  assert.equal(style.maskColor, Color.Transparent);
  return style;
}

function assertFallback(native, nightMode, inset = 0) {
  const style = assertFloatingGeometry(native, inset);
  assert.equal(style.systemMaterial, native.emptyMaterial);
  assert.equal(lastCall(native, 'barBackgroundColor')[1],
    nightMode ? themeModule.exports.COLOR_NIGHT_BG : themeModule.exports.COLOR_DAY_BG);
  assert.equal(lastCall(native, 'barBackgroundBlurStyle')[1], BlurStyle.NONE);
}

test('older systems avoid all API 26 access and keep the gesture area transparent', () => {
  for (const sdkVersion of [12, 25]) {
    const native = createHarness({ sdkVersion });
    assert.doesNotThrow(() => native.apply());
    assert.deepEqual(native.capabilityCalls, []);
    assertTransparentAvoidArea(native);
    assert.equal(lastCall(native, 'barBackgroundColor')[1], Color.Transparent);
    assert.equal(lastCall(native, 'barBackgroundBlurStyle')[1], BlurStyle.NONE);
    assert.equal(lastCall(native, 'barFloatingStyle'), undefined);
  }
});

test('unavailable API 26.0.0 does not probe material or floating APIs', () => {
  const native = createHarness({ apiAvailable: false });
  assert.doesNotThrow(() => native.apply());
  assert.deepEqual(native.capabilityCalls, [['apiAvailable', '26.0.0']]);
  assertTransparentAvoidArea(native);
  assert.equal(lastCall(native, 'barBackgroundColor')[1], Color.Transparent);
  assert.equal(lastCall(native, 'barBackgroundBlurStyle')[1], BlurStyle.NONE);
  assert.equal(lastCall(native, 'barFloatingStyle'), undefined);
});

test('supported hardware explicitly enables interactive light sensing on the capsule', () => {
  const native = createHarness({ inset: 31 });
  native.apply();
  assert.deepEqual(native.capabilityCalls, [
    ['apiAvailable', '26.0.0'], ['isImmersiveMaterialSupported'], ['ImmersiveMaterial']
  ]);
  const style = assertFloatingGeometry(native, 31);
  assert.notEqual(style.systemMaterial, native.emptyMaterial);
  assert.deepEqual(style.systemMaterial.options, {
    style: native.immersiveStyle.THIN,
    materialColor: themeModule.exports.themeMaterialSurfaceColor(false, 0.6),
    colorInvert: false, applyShadow: true, interactive: true,
    lightEffect: { color: Color.White }
  });
  assert.ok(native.calls.filter(call => call[0] === 'barBackgroundColor')
    .every(call => call[1] === Color.Transparent),
  'An opaque fallback color must not hide the supported material');
  assert.equal(lastCall(native, 'barBackgroundBlurStyle'), undefined,
    'The supported path must let native material own its blur');
});

test('unsupported hardware preserves a readable capsule without a bottom mask', () => {
  for (const nightMode of [false, true]) {
    const native = createHarness({ supported: false, nightMode, inset: 18 });
    native.apply();
    assert.deepEqual(native.capabilityCalls, [['apiAvailable', '26.0.0'], ['isImmersiveMaterialSupported']]);
    assertFallback(native, nightMode, 18);
  }
});

test('native capability errors fall back without interrupting page rendering', () => {
  const native = createHarness({ queryError: true, nightMode: true, inset: 29 });
  assert.doesNotThrow(() => native.apply());
  assert.deepEqual(native.capabilityCalls, [['apiAvailable', '26.0.0'], ['isImmersiveMaterialSupported']]);
  assertFallback(native, true, 29);
});

test('day and night modifiers update the actual shared theme tint while retaining translucency', () => {
  const native = createHarness();
  for (const nightMode of [false, true, false]) {
    native.apply(nightMode);
    const tint = assertFloatingGeometry(native, 0).systemMaterial.options.materialColor;
    assert.equal(tint, themeModule.exports.themeMaterialSurfaceColor(nightMode, 0.6));
    assert.equal(tint.slice(1, 3), '99');
    assert.equal(tint.slice(3), (nightMode ? themeModule.exports.COLOR_NIGHT_CARD :
      themeModule.exports.COLOR_DAY_CARD).slice(3));
    assert.equal(lastCall(native, 'barBackgroundColor')[1], Color.Transparent);
  }
});

test('safe-area updates change only the capsule bottom distance in both material modes', () => {
  for (const supported of [true, false]) {
    const native = createHarness({ supported });
    for (const inset of [0, 34, 8, 0]) {
      native.apply(false, inset);
      assertFloatingGeometry(native, inset);
    }
  }
});

test('reapplying a supported modifier clears the earlier fallback capsule color', () => {
  const options = { supported: false };
  const native = createHarness(options);
  native.apply();
  assertFallback(native, false);
  options.supported = true;
  native.apply();
  const style = assertFloatingGeometry(native, 0);
  assert.notEqual(style.systemMaterial, native.emptyMaterial);
  assert.equal(lastCall(native, 'barBackgroundColor')[1], Color.Transparent);
});

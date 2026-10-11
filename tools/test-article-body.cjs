'use strict';

/* Run the actual ArticleBody lifecycle/image methods through the DevEco ETS
 * compiler. The HTML renderer stays real; Web controller, native save API and
 * UI context are local substitutes. This does not verify Web painting.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const root = path.resolve(__dirname, '..');
const loaderRoot = path.join(process.env.DEVECO_HOME || 'D:/software/DevEco Studio',
  'sdk/default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.TYPESCRIPT_PATH || path.join(loaderRoot, 'node_modules/typescript'));
const componentMap = require(path.join(loaderRoot, 'lib/component_map.js'));

function transpile(source, filename) {
  const result = ts.transpileModule(source, {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  assert.deepEqual((result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error)
    .map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
  return result.outputText;
}
require.extensions['.ets'] = (module, filename) => {
  module._compile(transpile(fs.readFileSync(filename, 'utf8'), filename), filename);
};
const { renderArticleContent } = require('../entry/src/main/ets/model/ArticleHtml.ets');
const imageHelpers = require('../entry/src/main/ets/model/ArticleHtml.ets');
const filename = path.join(root, 'entry/src/main/ets/components/ArticleBody.ets');
const source = fs.readFileSync(filename, 'utf8');
const ast = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS,
  { ets: { components: Object.keys(componentMap.COMPONENT_MAP).concat(['ArticleImageViewer']) } });
assert.deepEqual(ast.parseDiagnostics.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
const subject = ast.statements.find(node => node.name?.getText(ast) === 'ArticleBody');
assert.ok(subject, 'Actual ArticleBody component');
const names = new Set(['aboutToDisappear', 'reloadHtml', 'openImage', 'saveImage',
  'cancelBodyMeasure', 'measureBodyHeight', 'scheduleBodyMeasure']);
const members = subject.members.filter(ts.isMethodDeclaration)
  .filter(member => names.has(member.name.getText(ast)));
assert.equal(members.length, names.size, 'Extract every actual lifecycle/image/measurement method');
const callbackNames = new Set(['onPageEnd', 'onResourceLoad', 'onAreaChange', 'onControllerAttached']);
const nativeCallbacks = new Map();
const build = subject.members.find(member => ts.isMethodDeclaration(member) && member.name.getText(ast) === 'build');
function collectCallbacks(node) {
  if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression) &&
    callbackNames.has(node.expression.name.getText(ast))) {
    assert.equal(node.arguments.length, 1);
    assert.ok(ts.isArrowFunction(node.arguments[0]));
    nativeCallbacks.set(node.expression.name.getText(ast), node.arguments[0].getText(ast));
  }
  ts.forEachChild(node, collectCallbacks);
}
collectCallbacks(build);
assert.equal(nativeCallbacks.size, callbackNames.size, 'Extract actual Web lifecycle and size callbacks');
const methods = transpile('class RealBody {\n' + members.map(member => member.getText(ast)).join('\n') +
  '\nfixtureCallbacks() { return {' + Array.from(nativeCallbacks, ([name, callback]) => name + ':' + callback).join(',') + '}; }' +
  '\n}\nglobalThis.RealBody=RealBody;', 'ActualArticleBodyMethods.ts');
const IMAGE = 'https://img.nga.cn/attachments/mon_202610/08/fixture.png';
const link = url => 'nga-image:' + encodeURIComponent(url);
const document = content => '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>' +
  renderArticleContent(content) + '</body></html>';

function defer() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture() {
  const saves = [], loads = [], toasts = [], warnings = [], heightReads = [], conversions = [], clearedTimers = [];
  const timers = new Map();
  let nextTimer = 1;
  const hostContext = { localFixture: true };
  const config = { context: hostContext, loadError: false, heightError: false, pageHeight: 64, density: 3.5,
    save: async () => ({ success: true, cancelled: false, message: '已保存到图库' }) };
  const context = vm.createContext({ ...imageHelpers,
    ArticleImageSaver: { save(url, nativeContext, isCurrent) {
      saves.push({ url, nativeContext, isCurrent }); return config.save();
    } }, console: { warn: message => warnings.push(message) },
    setTimeout(callback, delay) { const id = nextTimer++; timers.set(id, { callback, delay }); return id; },
    clearTimeout(id) { clearedTimers.push(id); timers.delete(id); } });
  vm.runInContext(methods, context, { filename });
  const host = new context.RealBody();
  Object.assign(host, { html: document('正文[img]' + IMAGE + '[/img]'),
    baseUrl: 'https://bbs.nga.cn/', bodyBackground: '#ffffffff', attached: true,
    showImageViewer: false, activeImageUrl: '', isSavingImage: false, bodyHeight: 32, bodyWidth: 0,
    measureTimers: [], measureRevision: 0,
    controller: { loadData(...args) {
      if (config.loadError) throw new Error('local controller failure');
      loads.push(args);
    }, getPageHeight() {
      heightReads.push(config.pageHeight);
      if (config.heightError) throw new Error('local height is unavailable');
      return config.pageHeight;
    } },
    getUIContext: () => ({ getHostContext: () => config.context,
      px2vp(pixels) { conversions.push(pixels); return pixels / config.density; },
      getPromptAction: () => ({ showToast: toast => toasts.push({ ...toast }) }) }) });
  const callbacks = host.fixtureCallbacks();
  function runTimer(id) { const timer = timers.get(id); assert.ok(timer, 'Active fixture timer');
    timers.delete(id); timer.callback(); }
  return { host, config, hostContext, saves, loads, toasts, warnings, heightReads, conversions,
    timers, clearedTimers, callbacks, runTimer };
}

test('opening a rendered image then reloading closes the cover and loads the current complete document', () => {
  const f = fixture();
  f.host.openImage(link(IMAGE));
  assert.equal(f.host.showImageViewer, true);
  assert.equal(f.host.activeImageUrl, IMAGE);
  const next = document('刷新正文[img]' + IMAGE + '[/img]');
  f.host.html = next; f.host.reloadHtml();
  assert.equal(f.host.showImageViewer, false);
  assert.deepEqual(f.loads, [[next, 'text/html', 'UTF-8', f.host.baseUrl, f.host.baseUrl]]);
});

test('image viewing accepts only a safe image in the current rendered document', () => {
  for (const target of [link('https://other.invalid/absent.png'), link('javascript:alert(1)'),
    link('file:///private/photo.png'), link('data:image/png;base64,YQ=='),
    'nga-image:%invalid', IMAGE, 'https://bbs.nga.cn/']) {
    const f = fixture(); f.host.openImage(target);
    assert.equal(f.host.showImageViewer, false);
    assert.equal(f.host.activeImageUrl, '');
  }
  for (const body of ['没有图片', '[code][img]' + IMAGE + '[/img][/code]',
    '[img]javascript:alert(1)[/img]']) {
    const f = fixture(); f.host.html = document(body); f.host.openImage(link(IMAGE));
    assert.equal(f.host.showImageViewer, false);
  }
});

test('destruction closes an open viewer and rejects late open or reload events', () => {
  const f = fixture(); f.host.openImage(link(IMAGE)); f.host.aboutToDisappear();
  assert.equal(f.host.attached, false);
  assert.equal(f.host.showImageViewer, false);
  f.host.openImage(link(IMAGE)); f.host.reloadHtml();
  assert.equal(f.host.showImageViewer, false);
  assert.equal(f.loads.length, 0);
});

test('saving passes the current rendered URL and native context, serializes duplicate taps and reports success', async () => {
  const f = fixture(); const result = defer(); f.config.save = () => result.promise;
  const operation = f.host.saveImage(IMAGE);
  assert.equal(f.host.isSavingImage, true);
  assert.equal(f.saves.length, 1);
  assert.equal(f.saves[0].url, IMAGE);
  assert.equal(f.saves[0].nativeContext, f.hostContext);
  assert.equal(f.saves[0].isCurrent(), true);
  await f.host.saveImage(IMAGE);
  assert.equal(f.saves.length, 1);
  result.resolve({ success: true, cancelled: false, message: '已保存到图库' }); await operation;
  assert.equal(f.host.isSavingImage, false);
  assert.deepEqual(f.toasts, [{ message: '已保存到图库' }]);
});

test('missing context, detached body, busy saves and images outside the current article never reach the save API', async () => {
  for (const change of [f => { f.config.context = undefined; }, f => { f.host.attached = false; },
    f => { f.host.isSavingImage = true; }, f => { f.host.html = document('正文没有图片'); }]) {
    const f = fixture(); change(f); await f.host.saveImage(IMAGE);
    assert.equal(f.saves.length, 0);
    assert.equal(f.toasts.length, 0);
  }
  for (const url of ['https://absent.invalid/image.png', 'javascript:alert(1)', 'file:///private/photo.png',
    'data:image/png;base64,YQ==']) {
    const f = fixture(); await f.host.saveImage(url);
    assert.equal(f.saves.length, 0);
    assert.equal(f.toasts.length, 0);
  }
});

test('cancelled saves and empty native feedback end the lock without a misleading toast', async () => {
  for (const result of [{ success: false, cancelled: true, message: '用户已取消' },
    { success: true, cancelled: false, message: '' }]) {
    const f = fixture(); f.config.save = async () => result; await f.host.saveImage(IMAGE);
    assert.equal(f.host.isSavingImage, false);
    assert.equal(f.toasts.length, 0);
  }
});

test('a visible save failure reports once, releases the lock and permits an intentional retry', async () => {
  const f = fixture(); f.config.save = async () => { throw new Error('local save failed'); };
  await f.host.saveImage(IMAGE);
  assert.equal(f.host.isSavingImage, false);
  assert.equal(f.toasts.length, 1);
  assert.match(f.toasts[0].message, /保存失败/);
  f.config.save = async () => ({ success: true, cancelled: false, message: '已保存到图库' });
  await f.host.saveImage(IMAGE);
  assert.equal(f.saves.length, 2);
  assert.equal(f.toasts.length, 2);
});

test('save completion after destruction cannot reopen the viewer or write visible state', async () => {
  const f = fixture(); const result = defer(); f.config.save = () => result.promise;
  f.host.openImage(link(IMAGE)); const operation = f.host.saveImage(IMAGE);
  f.host.aboutToDisappear();
  const stateAfterExit = { attached: f.host.attached, showImageViewer: f.host.showImageViewer,
    activeImageUrl: f.host.activeImageUrl, isSavingImage: f.host.isSavingImage };
  assert.equal(f.saves[0].isCurrent(), false);
  result.resolve({ success: true, cancelled: false, message: '迟到成功' }); await operation;
  assert.deepEqual({ attached: f.host.attached, showImageViewer: f.host.showImageViewer,
    activeImageUrl: f.host.activeImageUrl, isSavingImage: f.host.isSavingImage }, stateAfterExit);
  assert.equal(f.toasts.length, 0);
});

test('save errors after destruction are ignored without a late toast', async () => {
  const f = fixture(); const result = defer(); f.config.save = () => result.promise;
  const operation = f.host.saveImage(IMAGE); f.host.aboutToDisappear();
  result.reject(new Error('late local save failure')); await operation;
  assert.equal(f.toasts.length, 0);
  assert.equal(f.host.showImageViewer, false);
});

test('changing the article during a save closes the cover and invalidates its old result', async () => {
  const f = fixture(); const result = defer(); f.config.save = () => result.promise;
  f.host.openImage(link(IMAGE)); const operation = f.host.saveImage(IMAGE);
  f.host.html = document('新正文'); f.host.reloadHtml();
  assert.equal(f.host.showImageViewer, false);
  assert.equal(f.saves[0].isCurrent(), false);
  result.resolve({ success: true, cancelled: false, message: '旧正文保存反馈' }); await operation;
  assert.equal(f.toasts.length, 0);
  assert.equal(f.host.isSavingImage, false);
  f.host.openImage(link(IMAGE));
  assert.equal(f.host.showImageViewer, false);
});

test('controller reload failures stay contained and close the cover', () => {
  const f = fixture(); f.host.openImage(link(IMAGE)); f.config.loadError = true;
  assert.doesNotThrow(() => f.host.reloadHtml());
  assert.equal(f.host.showImageViewer, false);
  assert.equal(f.warnings.length, 1);
});

test('measurement rounds a valid page height and caps the native surface using physical pixels', () => {
  const f = fixture(); f.config.pageHeight = 48.2; f.host.measureBodyHeight();
  assert.equal(f.host.bodyHeight, 49);
  assert.deepEqual(f.heightReads, [48.2]);
  assert.deepEqual(f.conversions, [7000]);
  for (const density of [1, 2, 3.5, 4, 5.3]) {
    const f = fixture(); f.config.density = density; f.config.pageHeight = 1000000;
    f.host.measureBodyHeight();
    assert.equal(f.host.bodyHeight, 7000 / density);
    assert.ok(f.host.bodyHeight * density <= 7000 + 1e-8);
  }
});

test('an extremely long document remains intact in loadData while only its native viewport height is bounded', () => {
  const f = fixture();
  const full = document('长正文 &amp; 表情[s:ac:哭笑]\n'.repeat(5000) +
    '[code][img]https://forbidden.invalid/code.png[/img]<script>literal</script>[/code][img]' + IMAGE + '[/img]');
  assert.ok(full.length > 100000);
  f.host.html = full; f.host.reloadHtml();
  f.config.pageHeight = 1000000; f.callbacks.onPageEnd();
  assert.equal(f.loads[0][0], full);
  assert.equal(f.loads[0][0].length, full.length);
  assert.equal(f.host.html, full);
  assert.equal(f.host.bodyHeight, 2000);
  assert.equal(f.host.bodyHeight * f.config.density, 7000);
});

test('invalid or unavailable page heights preserve the last valid height and later measurements can recover', () => {
  const f = fixture(); f.host.bodyHeight = 300;
  for (const height of [0, -1, NaN, Infinity, -Infinity, undefined, null, '500', {}]) {
    f.config.pageHeight = height; assert.doesNotThrow(() => f.host.measureBodyHeight());
    assert.equal(f.host.bodyHeight, 300);
  }
  f.config.heightError = true; assert.doesNotThrow(() => f.host.measureBodyHeight());
  assert.equal(f.host.bodyHeight, 300);
  assert.equal(f.warnings.length, 1);
  f.config.heightError = false; f.config.pageHeight = 720;
  f.host.measureBodyHeight(); assert.equal(f.host.bodyHeight, 720);
});

test('page completion measures immediately and deferred measurements capture late image growth', () => {
  const f = fixture(); f.config.pageHeight = 96; f.callbacks.onPageEnd();
  assert.equal(f.host.bodyHeight, 96);
  assert.equal(f.heightReads.length, 1);
  assert.deepEqual(Array.from(f.timers.values(), timer => timer.delay), [100, 500, 2000]);
  const ids = Array.from(f.timers.keys());
  f.config.pageHeight = 420; f.runTimer(ids[0]); assert.equal(f.host.bodyHeight, 420);
  f.config.pageHeight = 900; f.runTimer(ids[1]); assert.equal(f.host.bodyHeight, 900);
  f.config.pageHeight = 1000000; f.runTimer(ids[2]); assert.equal(f.host.bodyHeight, 2000);
  assert.equal(f.heightReads.length, 4);
  assert.equal(f.timers.size, 0);
});

test('a new resource event replaces pending measurements instead of accumulating timers', () => {
  const f = fixture(); f.callbacks.onPageEnd();
  const firstIds = Array.from(f.timers.keys());
  f.config.pageHeight = 512; f.callbacks.onResourceLoad();
  assert.deepEqual(f.clearedTimers, firstIds);
  assert.equal(f.timers.size, 3);
  assert.ok(Array.from(f.timers.keys()).every(id => !firstIds.includes(id)));
  assert.equal(f.host.bodyHeight, 512);
  assert.equal(f.heightReads.length, 2);
});

test('reload cancels previous timers, resets the viewport and invalidates old-document callbacks', () => {
  const f = fixture(); f.callbacks.onPageEnd(); f.host.openImage(link(IMAGE));
  const firstIds = Array.from(f.timers.keys());
  const oldCallbacks = Array.from(f.timers.values(), timer => timer.callback);
  const next = document('新正文[img]' + IMAGE + '[/img]');
  f.host.html = next; f.host.reloadHtml();
  assert.deepEqual(f.clearedTimers, firstIds);
  assert.equal(f.timers.size, 0);
  assert.equal(f.host.bodyHeight, 32);
  assert.equal(f.host.showImageViewer, false);
  assert.equal(f.loads.at(-1)[0], next);
  const count = f.heightReads.length; f.config.pageHeight = 1200;
  oldCallbacks.forEach(callback => callback());
  assert.equal(f.heightReads.length, count);
  assert.equal(f.host.bodyHeight, 32);
  f.callbacks.onPageEnd(); assert.equal(f.host.bodyHeight, 1200);
});

test('destruction cancels every measurement and stale callbacks cannot read or change height', () => {
  const f = fixture(); f.callbacks.onPageEnd();
  const ids = Array.from(f.timers.keys());
  const oldCallbacks = Array.from(f.timers.values(), timer => timer.callback);
  f.host.aboutToDisappear();
  assert.deepEqual(f.clearedTimers, ids);
  assert.equal(f.timers.size, 0);
  assert.equal(f.host.measureTimers.length, 0);
  const count = f.heightReads.length, height = f.host.bodyHeight;
  f.config.pageHeight = 1000000; oldCallbacks.forEach(callback => callback());
  f.host.measureBodyHeight(); f.callbacks.onResourceLoad();
  assert.equal(f.heightReads.length, count);
  assert.equal(f.host.bodyHeight, height);
  assert.equal(f.timers.size, 0);
});

test('width changes remeasure once while height-only or invalid-area changes do not loop', () => {
  const f = fixture(); f.config.pageHeight = 640;
  f.callbacks.onAreaChange({ width: 0, height: 32 }, { width: 320, height: 32 });
  assert.equal(f.host.bodyWidth, 320);
  assert.equal(f.host.bodyHeight, 32);
  assert.equal(f.heightReads.length, 0, 'The first width event must wait for the new viewport layout');
  const ids = Array.from(f.timers.keys());
  for (const width of [320, 0, -1, NaN, 'invalid']) {
    f.callbacks.onAreaChange({ width: 320, height: 32 }, { width, height: 640 });
  }
  assert.equal(f.heightReads.length, 0);
  assert.deepEqual(Array.from(f.timers.keys()), ids);
  f.runTimer(ids[0]);
  assert.equal(f.host.bodyHeight, 640);
  assert.equal(f.heightReads.length, 1);
  f.config.pageHeight = 480;
  f.callbacks.onAreaChange({ width: 320, height: 640 }, { width: '360', height: 640 });
  assert.equal(f.host.bodyWidth, 360);
  assert.equal(f.host.bodyHeight, 32);
  assert.equal(f.heightReads.length, 1);
  f.runTimer(Array.from(f.timers.keys())[0]);
  assert.equal(f.host.bodyHeight, 480);
  assert.equal(f.heightReads.length, 2);
});

test('controller attachment loads the complete document and waits for an available page height', () => {
  const f = fixture(); f.host.attached = false;
  f.host.scheduleBodyMeasure();
  assert.equal(f.heightReads.length, 0);
  assert.equal(f.timers.size, 0);
  f.callbacks.onControllerAttached();
  assert.equal(f.host.attached, true);
  assert.equal(f.loads.length, 1);
  assert.equal(f.loads[0][0], f.host.html);
  assert.equal(f.heightReads.length, 0);
  f.config.pageHeight = 280; f.callbacks.onPageEnd();
  assert.equal(f.host.bodyHeight, 280);
  assert.equal(f.timers.size, 3);
});

test('reloading identical HTML invalidates its old measurement callbacks by revision', () => {
  const f = fixture(); f.config.pageHeight = 180; f.callbacks.onPageEnd();
  const oldCallbacks = Array.from(f.timers.values(), timer => timer.callback);
  const revision = f.host.measureRevision, originalHtml = f.host.html;
  f.host.reloadHtml();
  assert.equal(f.host.html, originalHtml);
  assert.ok(f.host.measureRevision > revision);
  assert.equal(f.host.bodyHeight, 32);
  const count = f.heightReads.length;
  f.config.pageHeight = 1800; oldCallbacks.forEach(callback => callback());
  assert.equal(f.heightReads.length, count);
  assert.equal(f.host.bodyHeight, 32);
  f.config.pageHeight = 240; f.callbacks.onPageEnd();
  assert.equal(f.host.bodyHeight, 240);
});

test('replacement measurement schedules invalidate old callbacks even when HTML is unchanged', () => {
  const f = fixture(); f.callbacks.onPageEnd();
  const oldCallbacks = Array.from(f.timers.values(), timer => timer.callback);
  f.config.pageHeight = 300; f.callbacks.onResourceLoad();
  const count = f.heightReads.length;
  f.config.pageHeight = 1200; oldCallbacks.forEach(callback => callback());
  assert.equal(f.heightReads.length, count);
  assert.equal(f.host.bodyHeight, 300);
  f.runTimer(Array.from(f.timers.keys())[0]);
  assert.equal(f.host.bodyHeight, 1200);
});

test('a wider viewport resets the old height before delayed measurement can read the newly wrapped content', () => {
  const f = fixture(); f.host.bodyWidth = 320;
  f.config.pageHeight = 1700; f.callbacks.onPageEnd();
  const oldCallbacks = Array.from(f.timers.values(), timer => timer.callback);
  const count = f.heightReads.length;
  f.callbacks.onAreaChange({ width: 320, height: 1700 }, { width: 640, height: 1700 });
  assert.equal(f.host.bodyWidth, 640);
  assert.equal(f.host.bodyHeight, 32);
  assert.equal(f.heightReads.length, count, 'Do not immediately reapply the old viewport height');
  oldCallbacks.forEach(callback => callback());
  assert.equal(f.host.bodyHeight, 32);
  assert.equal(f.heightReads.length, count);
  f.config.pageHeight = 500; f.runTimer(Array.from(f.timers.keys())[0]);
  assert.equal(f.host.bodyHeight, 500);
  assert.equal(f.heightReads.length, count + 1);
});

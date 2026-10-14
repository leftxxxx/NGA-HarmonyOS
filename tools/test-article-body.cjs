'use strict';
// Execute real ETS methods and declarative builder events with local UI/native substitutes.
// Only UI construction is rewritten; parser, guards and layout expressions remain application code.
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
  const result = ts.transpileModule(source, { fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
  assert.deepEqual((result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error)
    .map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
  return result.outputText;
}
require.extensions['.ets'] = (module, filename) => {
  module._compile(transpile(fs.readFileSync(filename, 'utf8'), filename), filename);
};
const articleHelpers = require('../entry/src/main/ets/model/ArticleHtml.ets');
const nativeParser = require('../entry/src/main/ets/model/ArticleNativeContent.ets');
const { renderArticleContent } = articleHelpers;
// SDK declarations supply enum values. Unknown names fail immediately instead
// of returning undefined and hiding a compiler/API compatibility error.
function realSdkEnums() {
  const names = new Set(['FontWeight', 'FontStyle', 'TextAlign', 'ImageFit', 'TextDecorationType',
    'ModalTransition', 'GesturePriority', 'HorizontalAlign', 'Alignment', 'ButtonType', 'Color',
    'ImageSpanAlignment', 'WordBreak', 'CopyOptions']);
  const declarations = ['enums.d.ts', 'button.d.ts', 'common.d.ts', 'gesture.d.ts'].flatMap(file => {
    const filename = path.join(loaderRoot, '../../component', file);
    const ast = ts.createSourceFile(filename, fs.readFileSync(filename, 'utf8'), ts.ScriptTarget.Latest, true);
    return ast.statements.filter(node => ts.isEnumDeclaration(node) && names.has(node.name.getText(ast)))
      .map(node => node.getText(ast).replace(/^declare /, ''));
  });
  assert.equal(declarations.length, names.size, 'All enum mocks come from actual SDK declarations');
  const context = vm.createContext({});
  vm.runInContext(transpile(declarations.join('\n') +
    '\nglobalThis.enumValues={' + Array.from(names).join(',') + '};', 'ActualSdkEnums.ts'), context);
  return Object.fromEntries(Object.entries(context.enumValues).map(([name, value]) => [name,
    new Proxy(value, { get(target, key) {
      if (typeof key === 'string') assert.ok(Object.hasOwn(target, key), 'No SDK member ' + name + '.' + key);
      return target[key];
    } })]));
}
const sdkEnums = realSdkEnums();
function realClass(name, filename, globals) {
  const source = fs.readFileSync(filename, 'utf8');
  const ast = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS);
  const subject = ast.statements.find(node => ts.isClassDeclaration(node) && node.name?.getText(ast) === name);
  assert.ok(subject, 'Actual model class ' + name);
  const context = vm.createContext({ exports: {}, Observed: target => target, ...globals });
  vm.runInContext(transpile(subject.getText(ast), filename), context, { filename });
  return context.exports[name];
}
function realComponent(name, globals) {
  const filename = path.join(root, 'entry/src/main/ets/components', name + '.ets');
  const source = fs.readFileSync(filename, 'utf8');
  const ast = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS,
    { ets: { components: Object.keys(componentMap.COMPONENT_MAP).concat([
      'ArticleImageViewer', 'ArticleNativeImage', 'ArticleNativeParagraph', 'ArticleNativeBlock'
    ]) } });
  assert.deepEqual(ast.parseDiagnostics.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
  const subject = ast.statements.find(node => node.name?.getText(ast) === name);
  assert.ok(subject, 'Actual native component ' + name);
  const builtComponents = new Set();
  function fragment(node) {
    if (ts.SyntaxKind[node.kind] === 'EtsComponentExpression') {
      const kind = node.expression.getText(ast); builtComponents.add(kind);
      return 'ui(' + JSON.stringify(kind) + ', [' + node.arguments.map(fragment).join(',') + ']' +
        (node.body ? ', () => ' + fragment(node.body) : '') + ')';
    }
    if (ts.isIdentifier(node) && node.getText(ast) === '$$this') return 'this';
    let result = node.getText(ast), offset = node.getStart(ast);
    const children = []; ts.forEachChild(node, child => { children.push(child); });
    for (const child of children.reverse()) {
      const next = fragment(child);
      if (next !== child.getText(ast)) result = result.substring(0, child.getStart(ast) - offset) +
        next + result.substring(child.end - offset);
    }
    return result;
  }
  const declarations = subject.members.filter(node => ts.isPropertyDeclaration(node) || ts.isMethodDeclaration(node))
    .map(member => {
      let result = fragment(member);
      for (const decorator of (member.modifiers || []).filter(node => node.kind === ts.SyntaxKind.Decorator))
        result = result.replace(decorator.getText(ast), '');
      return result;
    }).join('\n');
  const constants = ast.statements.filter(ts.isVariableStatement).map(node => node.getText(ast)).join('\n');
  const extraClasses = ast.statements.filter(ts.isClassDeclaration).map(node => node.getText(ast)).join('\n');
  const context = vm.createContext({ exports: {}, ...globals });
  vm.runInContext(transpile(constants + '\n' + extraClasses + '\nclass RealComponent {\n' + declarations +
    '\n}\nglobalThis.RealComponent=RealComponent;', filename + '.ts'), context, { filename });
  return { host: new context.RealComponent(), builtComponents };
}
function recorder() {
  const roots = [], stack = [], iterations = [];
  function ui(kind, args, children) {
    if (kind === 'ForEach') {
      const keys = args[0].map((item, index) => args[2] ? args[2](item, index) : index);
      assert.equal(new Set(keys).size, keys.length, 'Rendered sibling keys are unique');
      iterations.push(Array.from(keys));
      args[0].forEach((item, index) => args[1](item, index)); return {};
    }
    const node = { kind, args, props: {}, children: [] };
    (stack.length ? stack.at(-1).children : roots).push(node);
    if (children) { stack.push(node); try { children(); } finally { stack.pop(); } }
    const proxy = new Proxy(node, { get(target, key) {
      if (Object.hasOwn(target, key)) return target[key];
      return (...values) => { target.props[key] = values; return proxy; };
    } });
    return proxy;
  }
  function flatten() {
    const all = []; function visit(node) { all.push(node); node.children.forEach(visit); }
    roots.forEach(visit); return all;
  }
  return { ui, roots, iterations, reset: () => { roots.length = 0; iterations.length = 0; }, flatten,
    find: kind => flatten().filter(node => node.kind === kind) };
}
const IMAGE = 'https://img.nga.cn/attachments/mon_202610/08/fixture.png';
const OTHER_IMAGE = 'https://img.nga.cn/attachments/mon_202610/08/second.png';
const document = content => '<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>' +
  renderArticleContent(content) + '</body></html>';
const themedDocument = (content, night) => {
  const bg = night ? '#192333' : '#ffffff', text = night ? '#e9eff8' : '#182538';
  const accent = night ? '#8dbeff' : '#1765c1';
  return '<!DOCTYPE html><html><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1.0"><style>' +
    'html{background:' + bg + ';}body{background:' + bg + ';color:' + text +
    ';font-size:16px;line-height:1.75;padding:0;margin:0;}' +
    'blockquote{margin:8px 0;padding:8px;border-left:3px solid ' + accent + ';}' +
    (night ? 'img.invertFilter{filter:invert(100%);}' : '') + 'a{color:' + accent + ';}' +
    '</style></head><body>' + renderArticleContent(content) + '</body></html>';
};
function defer() {
  let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture(html = document('正文[img]' + IMAGE + '[/img]')) {
  const saves = [], toasts = [], warnings = [], navigation = [], ui = recorder();
  const config = { context: undefined, navigationError: false,
    save: async () => ({ success: true, cancelled: false, message: '已保存到图库' }) };
  const hostContext = { localFixture: true, startAbility: async want => {
    navigation.push({ ...want }); if (config.navigationError) throw new Error('local browser failure');
  } }; config.context = hostContext;
  const globals = { ...articleHelpers, ...nativeParser,
    NgaArticleBodyBlock: realClass('NgaArticleBodyBlock',
      path.join(root, 'entry/src/main/ets/components/ArticleNativeBlock.ets'), {}),
    COLOR_DAY_CARD: '#ffffffff', COLOR_DAY_TEXT: '#ff182538', COLOR_NIGHT_TEXT: '#ffe9eff8',
    COLOR_DAY_SUB: '#ff53647a', COLOR_NIGHT_SUB: '#ffb0bfd2', COLOR_ACCENT_BLUE: '#ff1765c1',
    ui: ui.ui, ForEach: (items, build, key) => ui.ui('ForEach', [items, build, key]),
    ...sdkEnums,
    LongPressGesture: options => ui.ui('LongPressGesture', [options]),
    $rawfile: name => ({ rawfile: name }),
    ColorFilter: class { constructor(matrix) { this.matrix = Array.from(matrix); } },
    Observed: target => target,
    ArticleImageSaver: { save(url, nativeContext, isCurrent) {
      saves.push({ url, nativeContext, isCurrent }); return config.save();
    } }, console: { warn: message => warnings.push(message) }
  };
  const result = realComponent('ArticleBody', globals), host = result.host;
  host.html = html; host.getUIContext = () => ({ getHostContext: () => config.context,
    getPromptAction: () => ({ showToast: toast => toasts.push({ ...toast }) }) });
  host.aboutToAppear();
  function render() { ui.reset(); host.build(); return ui; }
  return { host, config, hostContext, saves, toasts, warnings, navigation, ui, render, globals,
    builtComponents: result.builtComponents };
}
test('viewing accepts only a rendered current HTTPS image', () => {
  const f = fixture(); f.host.openImage(IMAGE, f.host.loadedHtml);
  assert.equal(f.host.showImageViewer, true); assert.equal(f.host.activeImageUrl, IMAGE);
  for (const target of [OTHER_IMAGE, 'javascript:alert(1)', 'file:///private/photo.png',
    'data:image/png;base64,YQ==', 'nga-image:%invalid', 'https://bbs.nga.cn/']) {
    const f = fixture(); f.host.openImage(target, f.host.loadedHtml);
    assert.equal(f.host.showImageViewer, false); assert.equal(f.host.activeImageUrl, '');
  }
  for (const body of ['没有图片', '[code][img]' + IMAGE + '[/img][/code]', '[img]javascript:alert(1)[/img]']) {
    const f = fixture(document(body)); f.host.openImage(IMAGE, f.host.loadedHtml); assert.equal(f.host.showImageViewer, false);
  }
});
test('destruction closes cover and rejects late open/reload events', () => {
  const f = fixture(); f.host.openImage(IMAGE, f.host.loadedHtml); f.host.aboutToDisappear();
  assert.equal(f.host.attached, false); assert.equal(f.host.showImageViewer, false);
  const snapshot = JSON.stringify(f.host.document);
  f.host.openImage(IMAGE, f.host.loadedHtml); f.host.html = document('迟到正文'); f.host.reloadHtml();
  assert.equal(f.host.showImageViewer, false); assert.equal(JSON.stringify(f.host.document), snapshot);
});
test('save serializes duplicate taps and reports allowed URL/context result once', async () => {
  const f = fixture(), result = defer(); f.config.save = () => result.promise;
  const operation = f.host.saveImage(IMAGE, f.host.loadedHtml);
  assert.equal(f.host.isSavingImage, true); assert.equal(f.saves.length, 1);
  assert.equal(f.saves[0].url, IMAGE); assert.equal(f.saves[0].nativeContext, f.hostContext);
  assert.equal(f.saves[0].isCurrent(), true); await f.host.saveImage(IMAGE, f.host.loadedHtml); assert.equal(f.saves.length, 1);
  result.resolve({ success: true, cancelled: false, message: '已保存到图库' }); await operation;
  assert.equal(f.host.isSavingImage, false); assert.deepEqual(f.toasts, [{ message: '已保存到图库' }]);
});
test('missing context, detached body, busy save and absent URLs never reach save API', async () => {
  for (const change of [f => { f.config.context = undefined; }, f => { f.host.aboutToDisappear(); },
    f => { f.host.isSavingImage = true; }, f => { f.host.html = document('没有图片'); f.host.reloadHtml(); }]) {
    const f = fixture(); change(f); await f.host.saveImage(IMAGE, f.host.loadedHtml);
    assert.equal(f.saves.length, 0); assert.equal(f.toasts.length, 0);
  }
  for (const target of [OTHER_IMAGE, 'javascript:alert(1)', 'file:///private/photo.png', 'data:image/png;base64,YQ==']) {
    const f = fixture(); await f.host.saveImage(target, f.host.loadedHtml); assert.equal(f.saves.length, 0);
  }
});
test('cancelled save and empty native feedback unlock without misleading toast', async () => {
  for (const result of [{ success: false, cancelled: true, message: '用户已取消' },
    { success: true, cancelled: false, message: '' }]) {
    const f = fixture(); f.config.save = async () => result; await f.host.saveImage(IMAGE, f.host.loadedHtml);
    assert.equal(f.host.isSavingImage, false); assert.equal(f.toasts.length, 0);
  }
});
test('visible save failure releases lock and permits retry', async () => {
  const f = fixture(); f.config.save = async () => { throw new Error('local save failure'); };
  await f.host.saveImage(IMAGE, f.host.loadedHtml); assert.equal(f.host.isSavingImage, false);
  assert.equal(f.toasts.length, 1); assert.match(f.toasts[0].message, /保存失败/);
  f.config.save = async () => ({ success: true, cancelled: false, message: '已保存到图库' });
  await f.host.saveImage(IMAGE, f.host.loadedHtml); assert.equal(f.saves.length, 2); assert.equal(f.toasts.length, 2);
});
test('late save success/failure after destruction cannot change visible state', async () => {
  for (const rejected of [false, true]) {
    const f = fixture(), result = defer(); f.config.save = () => result.promise;
    f.host.openImage(IMAGE, f.host.loadedHtml); const operation = f.host.saveImage(IMAGE, f.host.loadedHtml); f.host.aboutToDisappear();
    const snapshot = [f.host.attached, f.host.showImageViewer, f.host.activeImageUrl, f.host.isSavingImage];
    assert.equal(f.saves[0].isCurrent(), false);
    if (rejected) result.reject(new Error('late save failure'));
    else result.resolve({ success: true, cancelled: false, message: '迟到成功' });
    await operation; assert.deepEqual(
      [f.host.attached, f.host.showImageViewer, f.host.activeImageUrl, f.host.isSavingImage], snapshot);
    assert.equal(f.toasts.length, 0);
  }
});
test('replacement invalidates save even when new body shares image URL', async () => {
  const f = fixture(), result = defer(); f.config.save = () => result.promise;
  f.host.openImage(IMAGE, f.host.loadedHtml); const operation = f.host.saveImage(IMAGE, f.host.loadedHtml);
  f.host.html = document('完全不同正文[img]' + IMAGE + '[/img]'); f.host.reloadHtml();
  assert.equal(f.host.showImageViewer, false); assert.equal(f.host.activeImageUrl, '');
  assert.equal(f.saves[0].isCurrent(), false);
  result.resolve({ success: true, cancelled: false, message: '旧正文反馈' }); await operation;
  assert.equal(f.toasts.length, 0); assert.equal(f.host.isSavingImage, false);
});
test('color-only changes preserve viewer and pending save in either theme direction', async () => {
  const body = '正文[img]' + IMAGE + '[/img]';
  for (const night of [false, true]) {
    const f = fixture(themedDocument(body, night)), result = defer(); f.config.save = () => result.promise;
    f.host.openImage(IMAGE, f.host.loadedHtml); const operation = f.host.saveImage(IMAGE, f.host.loadedHtml);
    f.host.html = themedDocument(body, !night); f.host.reloadHtml();
    assert.equal(f.host.showImageViewer, true); assert.equal(f.host.activeImageUrl, IMAGE);
    assert.equal(f.saves[0].isCurrent(), true);
    result.resolve({ success: true, cancelled: false, message: '已保存到图库' }); await operation;
    assert.equal(f.host.isSavingImage, false); assert.deepEqual(f.toasts, [{ message: '已保存到图库' }]);
  }
});
test('replacement after theme transition still invalidates save and viewer', async () => {
  const body = '正文[img]' + IMAGE + '[/img]', f = fixture(themedDocument(body, false)), result = defer();
  f.config.save = () => result.promise; f.host.openImage(IMAGE, f.host.loadedHtml); const operation = f.host.saveImage(IMAGE, f.host.loadedHtml);
  f.host.html = themedDocument(body, true); f.host.reloadHtml(); assert.equal(f.saves[0].isCurrent(), true);
  f.host.html = themedDocument('完全不同的正文', true); f.host.reloadHtml();
  assert.equal(f.saves[0].isCurrent(), false); assert.equal(f.host.showImageViewer, false);
  result.resolve({ success: true, cancelled: false, message: '旧正文反馈' }); await operation;
  assert.equal(f.toasts.length, 0);
});



function imageFixture(options = {}) {
  const f = fixture(), result = realComponent('ArticleNativeImage', f.globals), host = result.host;
  const opened = [], saved = [];
  Object.assign(host, { imageSrc: IMAGE, imageId: 'fixture', imageAlt: '附件', openUrl: IMAGE,
    articleHtml: f.host.html, onOpen: (url, html) => opened.push({ url, html }),
    onSave: (url, html) => saved.push({ url, html }), ...options });
  host.aboutToAppear();
  function render() { f.ui.reset(); host.build(); return f.ui; }
  return { ...f, host, opened, saved, render, builtComponents: result.builtComponents };
}
function imageNode(f) { const node = f.render().find('Image')[0]; assert.ok(node, 'Actual native attachment Image'); return node; }
function completeImage(node, width = 1600, height = 1000) { node.props.onComplete[0]({ width, height }); }
function areaNode(f) { const node = f.render().roots[0]; assert.ok(node.props.onAreaChange); return node; }
function longPress(node) {
  const gesture = node.props.gesture[0]; assert.equal(gesture.kind, 'LongPressGesture');
  assert.equal(gesture.args[0].duration, 600); gesture.props.onAction[0]();
}
test('actual attachment builder waits for decode before opening or saving', () => {
  const f = imageFixture(), node = imageNode(f);
  node.props.onClick[0](); longPress(node);
  assert.equal(f.opened.length, 0); assert.equal(f.saved.length, 0);
  completeImage(node); node.props.onClick[0](); longPress(node);
  assert.deepEqual(f.opened, [{ url: IMAGE, html: f.host.articleHtml }]);
  assert.deepEqual(f.saved, [{ url: IMAGE, html: f.host.articleHtml }]);
  assert.equal(node.props.draggable[0], false); assert.equal(node.props.objectFit[0], f.globals.ImageFit.Contain);
});
test('native attachment width and height follow decoded aspect ratio and live container width', () => {
  const f = imageFixture();
  areaNode(f).props.onAreaChange[0]({ width: 0 }, { width: 320 });
  completeImage(imageNode(f), 1600, 1000);
  let node = imageNode(f); assert.equal(node.props.width[0], 320); assert.equal(node.props.height[0], 200);
  areaNode(f).props.onAreaChange[0]({ width: 320 }, { width: 720 });
  node = imageNode(f); assert.equal(node.props.width[0], 720); assert.equal(node.props.height[0], 450);
  assert.equal(node.args[0], IMAGE); assert.equal(node.props.accessibilityText[0], '附件');
});
test('small attachments keep natural dimensions and tall attachments are not capped or cropped', () => {
  const small = imageFixture(); areaNode(small).props.onAreaChange[0]({}, { width: 400 });
  completeImage(imageNode(small), 200, 100);
  assert.equal(imageNode(small).props.width[0], 200); assert.equal(imageNode(small).props.height[0], 100);
  const tall = imageFixture(); areaNode(tall).props.onAreaChange[0]({}, { width: 350 });
  completeImage(imageNode(tall), 1000, 20000);
  assert.equal(imageNode(tall).props.height[0], 7000);
  assert.equal(imageNode(tall).props.objectFit[0], tall.globals.ImageFit.Contain);
});
test('invalid area and image dimensions cannot introduce NaN, infinity or collapse valid layout', () => {
  const f = imageFixture(); areaNode(f).props.onAreaChange[0]({}, { width: 320 });
  completeImage(imageNode(f), 1600, 1000);
  const onArea = areaNode(f).props.onAreaChange[0], onComplete = imageNode(f).props.onComplete[0];
  for (const width of [0, -1, NaN, Infinity, undefined, 'bad']) {
    assert.doesNotThrow(() => onArea({}, { width })); assert.equal(imageNode(f).props.width[0], 320);
  }
  for (const [width, height] of [[0, 1000], [1600, -1], [NaN, 1000], [Infinity, Infinity]]) {
    onComplete({ width, height }); assert.equal(imageNode(f).props.height[0], 200);
  }
});
test('failed attachment exposes retry and fresh request ignores all callbacks from the failed load', () => {
  const f = imageFixture(), old = imageNode(f); old.props.onError[0]();
  assert.equal(f.host.imageFailed, true); assert.equal(f.render().find('Image').length, 0);
  const retry = f.render().find('Button')[0]; assert.ok(retry.props.onClick);
  retry.props.onClick[0](); assert.equal(f.host.imageFailed, false);
  const current = imageNode(f); completeImage(current, 1000, 600);
  const snapshot = [f.host.imageLoaded, f.host.imageFailed, f.host.naturalWidth, f.host.naturalHeight];
  old.props.onComplete[0]({ width: 20, height: 40 }); old.props.onError[0]();
  old.props.onClick[0](); longPress(old);
  assert.deepEqual([f.host.imageLoaded, f.host.imageFailed, f.host.naturalWidth, f.host.naturalHeight], snapshot);
  assert.equal(f.opened.length, 0); assert.equal(f.saved.length, 0);
  current.props.onClick[0](); longPress(current); assert.equal(f.opened.length, 1); assert.equal(f.saved.length, 1);
});
test('replacing image source invalidates old decode, click and long-press events', () => {
  const f = imageFixture(), old = imageNode(f); completeImage(old);
  f.host.imageSrc = OTHER_IMAGE; f.host.openUrl = OTHER_IMAGE; f.host.resetImage();
  const current = imageNode(f); completeImage(current, 200, 300);
  old.props.onComplete[0]({ width: 999, height: 999 }); old.props.onError[0]();
  old.props.onClick[0](); longPress(old);
  assert.equal(f.host.naturalWidth, 200); assert.equal(f.host.naturalHeight, 300);
  assert.equal(f.host.imageFailed, false); assert.equal(f.opened.length, 0); assert.equal(f.saved.length, 0);
  current.props.onClick[0](); longPress(current);
  assert.equal(f.opened[0].url, OTHER_IMAGE); assert.equal(f.saved[0].url, OTHER_IMAGE);
});
test('destroyed attachment cannot accept callbacks, resize, retry, view or save', () => {
  const f = imageFixture(), node = imageNode(f), onArea = areaNode(f).props.onAreaChange[0];
  completeImage(node); f.host.aboutToDisappear();
  const snapshot = [f.host.requestKey, f.host.availableWidth, f.host.naturalWidth, f.host.naturalHeight,
    f.host.imageLoaded, f.host.imageFailed];
  node.props.onComplete[0]({ width: 20, height: 40 }); node.props.onError[0]();
  node.props.onClick[0](); longPress(node); onArea({}, { width: 720 }); f.host.retryImage();
  assert.deepEqual([f.host.requestKey, f.host.availableWidth, f.host.naturalWidth, f.host.naturalHeight,
    f.host.imageLoaded, f.host.imageFailed], snapshot);
  assert.equal(f.opened.length, 0); assert.equal(f.saved.length, 0);
});
test('local emoticon or preview with no original target never opens or saves as remote attachment', () => {
  for (const options of [{ imageSrc: 'data:image/png;base64,YQ==', openUrl: '' },
    { rawfilePath: 'emoticon/ac/11.png', openUrl: '' }]) {
    const f = imageFixture(options), node = imageNode(f); completeImage(node);
    node.props.onClick[0](); longPress(node); assert.equal(f.opened.length, 0); assert.equal(f.saved.length, 0);
  }
});


function blockFixture(parent, index = 0) {
  const nodes = parent.render().find('ArticleNativeBlock'), props = nodes[index]?.args[0];
  assert.ok(props, 'Actual native block props from ArticleBody builder');
  const result = realComponent('ArticleNativeBlock', parent.globals), host = result.host;
  Object.assign(host, props); host.aboutToAppear();
  function render() { parent.ui.reset(); host.build(); return parent.ui; }
  return { ...parent, parent: parent.host, host, render, builtComponents: result.builtComponents };
}
const settle = async () => { for (let index = 0; index < 6; index++) await Promise.resolve(); };
test('actual body and child builders display complete long text with native nodes and no Web', () => {
  const content = '完整正文&字形'.repeat(2000) + '最后一句保留', f = fixture(document(content));
  const nodes = f.render().find('ArticleNativeBlock');
  assert.equal(nodes.length, f.host.document.blocks.length); assert.ok(nodes.length > 1);
  const displayed = nodes.map((node, index) => blockFixture(f, index).render().find('Span')
    .map(span => span.args[0]).join('')).join('');
  assert.equal(displayed, content);
  assert.equal(f.builtComponents.has('Web'), false);
  for (let index = 0; index < nodes.length; index++) {
    const block = blockFixture(f, index); assert.equal(block.builtComponents.has('Web'), false);
    const text = block.render().find('Text')[0]; assert.equal(text.props.width[0], '100%');
    assert.equal(text.props.height, undefined, 'Native text has natural multi-line height');
    assert.equal(text.props.copyOption[0], f.globals.CopyOptions.LocalDevice);
  }
});
test('actual inline builders retain bold, italic, underline, strike, color, size and quote styling', () => {
  const f = fixture(document('[quote][b]粗体[/b][i]斜体[/i][u]下划线[/u][del]删除[/del]' +
    '[color=#cc3300]彩色[/color][size=150]大字[/size][/quote]'));
  const block = blockFixture(f), ui = block.render(), spans = ui.find('Span');
  const span = label => { const node = spans.find(item => item.args[0] === label); assert.ok(node, label); return node; };
  assert.equal(span('粗体').props.fontWeight[0], f.globals.FontWeight.Bold);
  assert.equal(span('斜体').props.fontStyle[0], f.globals.FontStyle.Italic);
  assert.equal(span('下划线').props.decoration[0].type, f.globals.TextDecorationType.Underline);
  assert.equal(span('删除').props.decoration[0].type, f.globals.TextDecorationType.LineThrough);
  assert.equal(span('彩色').props.fontColor[0], '#cc3300');
  assert.equal(span('大字').props.fontSize[0], f.host.document.fontSize * 1.5);
  assert.equal(ui.roots[0].props.border[0].width.left, 3); assert.equal(ui.roots[0].props.padding[0].left, 8);
});
test('actual paragraphs preserve alignment and escaped code as text, never interactive images', () => {
  const f = fixture(document('[align=center]居中[/align][align=right]右对齐[/align]' +
    '[code]<div>[img]' + IMAGE + '[/img]&literal</div>[/code]'));
  const paragraphs = f.host.document.blocks.map((block, index) => ({ block, view: blockFixture(f, index) }));
  for (const { block, view } of paragraphs) {
    const ui = view.render(), text = ui.find('Text')[0];
    assert.equal(text.props.textAlign[0], block.align === 'center' ? f.globals.TextAlign.Center :
      block.align === 'right' ? f.globals.TextAlign.End : f.globals.TextAlign.Start);
    if (block.code) {
      assert.equal(text.props.fontFamily[0], 'monospace'); assert.equal(ui.find('ArticleNativeImage').length, 0);
      assert.match(ui.find('Span').map(span => span.args[0]).join(''), /<div>\[img\].*&literal<\/div>/);
    }
  }
});
test('actual inline link click opens only its rendered HTTPS URL with the platform view action', async () => {
  const url = 'https://example.test/read?a=1&b=2', f = fixture(document('[url=' + url + ']链接[/url]'));
  const block = blockFixture(f), span = block.render().find('Span').find(node => node.args[0] === '链接');
  span.props.onClick[0](); await settle();
  assert.equal(f.navigation.length, 1); assert.equal(f.navigation[0].action, 'ohos.want.action.viewData');
  assert.equal(f.navigation[0].uri, url);
  for (const target of ['https://absent.test/read', 'javascript:alert(1)', 'file:///private/a',
    'data:text/plain,text', 'https://example.test/read\"', 'https://example.test/read\nbad']) {
    await f.host.openLink(target, f.host.loadedHtml);
  }
  assert.equal(f.navigation.length, 1);
});
test('missing context and stale or destroyed link callbacks never invoke browser', async () => {
  const url = 'https://example.test/read', html = document('[url=' + url + ']旧链接[/url]'), f = fixture(html);
  const old = blockFixture(f).render().find('Span')[0];
  f.config.context = undefined; old.props.onClick[0](); await settle(); assert.equal(f.navigation.length, 0);
  f.config.context = f.hostContext;
  f.host.html = document('新正文[url=' + url + ']同地址新链接[/url]'); f.host.reloadHtml();
  old.props.onClick[0](); await settle(); assert.equal(f.navigation.length, 0);
  f.host.aboutToDisappear(); await f.host.openLink(url, f.host.loadedHtml); assert.equal(f.navigation.length, 0);
});
test('browser failure reports for current article and ignores rejection after leaving it', async () => {
  const url = 'https://example.test/read', html = document('[url=' + url + ']链接[/url]');
  const f = fixture(html); f.config.navigationError = true;
  await f.host.openLink(url, f.host.loadedHtml); assert.equal(f.toasts.length, 1); assert.match(f.toasts[0].message, /无法打开/);
  const late = fixture(html), pending = defer();
  late.hostContext.startAbility = () => pending.promise;
  const opening = late.host.openLink(url, late.host.loadedHtml);
  late.host.aboutToDisappear(); pending.reject(new Error('late browser failure')); await opening;
  assert.equal(late.toasts.length, 0);
});
test('same-shape new article replaces wrapper identities and rejects old child image/save events', async () => {
  const f = fixture(document('旧正文[img]' + IMAGE + '[/img]')), oldNodes = f.render().find('ArticleNativeBlock');
  const oldBlocks = Array.from(f.host.renderBlocks), oldKeys = oldBlocks.map(block => block.renderKey);
  const imageNode = oldNodes.find(node => node.args[0].renderBlock.block.kind === 'image'), props = imageNode.args[0];
  f.host.html = document('新正文[img]' + IMAGE + '[/img]'); f.host.reloadHtml();
  assert.equal(f.host.renderBlocks.length, oldBlocks.length);
  for (let index = 0; index < oldBlocks.length; index++) {
    assert.notEqual(f.host.renderBlocks[index], oldBlocks[index]); assert.notEqual(f.host.renderBlocks[index].renderKey, oldKeys[index]);
  }
  props.onOpenImage(IMAGE, oldBlocks[0].articleHtml); props.onSaveImage(IMAGE, oldBlocks[0].articleHtml);
  await settle(); assert.equal(f.host.showImageViewer, false); assert.equal(f.saves.length, 0);
});
test('theme keeps wrapper identity and native attachment dimensions while publishing new colors/html', () => {
  const content = '正文[img]' + IMAGE + '[/img]', f = fixture(themedDocument(content, false));
  const blocks = Array.from(f.host.renderBlocks), keys = blocks.map(block => block.renderKey);
  const index = blocks.findIndex(block => block.block.kind === 'image'), block = blockFixture(f, index);
  const attachmentProps = block.render().find('ArticleNativeImage')[0].args[0];
  const image = realComponent('ArticleNativeImage', f.globals).host;
  Object.assign(image, attachmentProps); image.aboutToAppear(); image.availableWidth = 320;
  image.acceptImageLoad(image.requestKey, 1600, 1000); const request = image.requestKey;
  f.host.html = themedDocument(content, true); f.host.bodyBackground = '#ff192333'; f.host.reloadHtml();
  for (let i = 0; i < blocks.length; i++) {
    assert.equal(f.host.renderBlocks[i], blocks[i]); assert.equal(f.host.renderBlocks[i].renderKey, keys[i]);
    assert.equal(f.host.renderBlocks[i].articleHtml, f.host.html);
  }
  const current = f.render().find('ArticleNativeBlock')[index].args[0]; Object.assign(block.host, current);
  const nextProps = block.render().find('ArticleNativeImage')[0].args[0];
  assert.equal(nextProps.imageSrc, attachmentProps.imageSrc); Object.assign(image, nextProps);
  assert.equal(image.requestKey, request); assert.equal(image.imageDisplayHeight(), 200);
  assert.equal(current.articleTextColor, '#e9eff8'); assert.equal(current.articleLinkColor, '#8dbeff');
});
test('actual emoticon ImageSpan changes its inversion key/filter with theme and falls back to a readable label', () => {
  const content = '文字[s:ac:哭笑]', f = fixture(themedDocument(content, false)), block = blockFixture(f);
  const day = block.render(), daySpan = day.find('ImageSpan')[0]; assert.ok(daySpan);
  const dayKey = day.iterations[0].join('|'), dayFilter = Array.from(daySpan.props.colorFilter[0].matrix);
  assert.equal(daySpan.args[0].rawfile.startsWith('emoticon/'), true);
  f.host.html = themedDocument(content, true); f.host.reloadHtml();
  Object.assign(block.host, f.render().find('ArticleNativeBlock')[0].args[0]);
  const night = block.render(), nightSpan = night.find('ImageSpan')[0], nightKey = night.iterations[0].join('|');
  assert.ok(nightSpan); assert.notEqual(nightKey, dayKey);
  assert.notDeepEqual(Array.from(nightSpan.props.colorFilter[0].matrix), dayFilter);
  nightSpan.props.onError[0](); const fallback = block.render();
  assert.equal(fallback.find('ImageSpan').length, 0);
  assert.ok(fallback.find('Span').some(node => node.args[0] === '［哭笑］'));
  const fragment = f.host.document.blocks[0].inlines.find(inline => inline.kind === 'emoticon');
  assert.equal(block.host.emoticonLabel({ ...fragment, image: { ...fragment.image, alt: '[s:2]' } }), '［表情］');
  assert.equal(block.host.emoticonLabel({ ...fragment, image: { ...fragment.image, alt: '图片' } }), '［表情］');
  block.host.aboutToDisappear(); const failed = Array.from(block.host.failedEmoticonIds);
  nightSpan.props.onError[0](); assert.deepEqual(Array.from(block.host.failedEmoticonIds), failed);
});
test('actual viewer builder exposes close/save and closing cover keeps authorized save current', async () => {
  const f = fixture(), result = defer(); f.host.openImage(IMAGE, f.host.loadedHtml); f.config.save = () => result.promise;
  f.ui.reset(); f.host.ImageViewer(); const props = f.ui.find('ArticleImageViewer')[0].args[0];
  assert.equal(props.imageUrl, IMAGE); assert.equal(props.viewerBackground, f.host.bodyBackground);
  props.onSave(); assert.equal(f.saves.length, 1); props.onClose(); assert.equal(f.host.showImageViewer, false);
  assert.equal(f.saves[0].isCurrent(), true);
  result.resolve({ success: true, cancelled: false, message: '已保存到图库' }); await settle();
  assert.equal(f.host.isSavingImage, false); assert.deepEqual(f.toasts, [{ message: '已保存到图库' }]);
});
test('old completion cannot release a new article save lock or publish its feedback', async () => {
  const f = fixture(), oldResult = defer(), newResult = defer();
  f.config.save = () => oldResult.promise; const oldSave = f.host.saveImage(IMAGE, f.host.loadedHtml);
  f.host.html = document('新正文[img]' + OTHER_IMAGE + '[/img]'); f.host.reloadHtml();
  f.config.save = () => newResult.promise; const newSave = f.host.saveImage(OTHER_IMAGE, f.host.loadedHtml);
  assert.equal(f.host.isSavingImage, true); assert.equal(f.saves.length, 2); assert.equal(f.saves[0].isCurrent(), false);
  oldResult.resolve({ success: true, cancelled: false, message: '旧正文反馈' }); await oldSave;
  assert.equal(f.host.isSavingImage, true); assert.equal(f.toasts.length, 0);
  newResult.resolve({ success: true, cancelled: false, message: '新正文已保存' }); await newSave;
  assert.equal(f.host.isSavingImage, false); assert.deepEqual(f.toasts, [{ message: '新正文已保存' }]);
});


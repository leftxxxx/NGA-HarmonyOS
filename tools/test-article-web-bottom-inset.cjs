'use strict';

// Execute the real ArkTS methods and injected script against a small DOM fixture.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const loaderRoot = path.join(process.env.DEVECO_HOME || 'D:/software/DevEco Studio',
  'sdk/default/openharmony/ets/build-tools/ets-loader');
const ts = require(process.env.TYPESCRIPT_PATH || path.join(loaderRoot, 'node_modules/typescript'));
const componentMap = require(path.join(loaderRoot, 'lib/component_map.js'));
const filename = path.resolve(__dirname, '../entry/src/main/ets/components/ArticleWebFallback.ets');
const source = fs.readFileSync(filename, 'utf8');
const ast = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS,
  { ets: { components: Object.keys(componentMap.COMPONENT_MAP) } });
assert.deepEqual(ast.parseDiagnostics, []);
const subject = ast.statements.find(node => node.name?.getText(ast) === 'ArticleWebFallback');
assert.ok(subject);
const methods = subject.members.filter(node => ts.isMethodDeclaration(node) && node.name.getText(ast) !== 'build');
const output = ts.transpileModule('class RealReader {\n' + methods.map(node => node.getText(ast)).join('\n') +
  '\n}\nglobalThis.RealReader=RealReader;', { fileName: filename, reportDiagnostics: true,
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } });
assert.deepEqual((output.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error), []);

const DOMAIN = 'https://forum.invalid';
const TID = 44191387;
const topicUrl = page => DOMAIN + '/read.php?tid=' + TID + '&page=' + page;
const settle = () => new Promise(resolve => setImmediate(resolve));
const SPACER_ID = 'nga-harmony-gesture-end-spacer';

function fixture() {
  const config = { currentUrl: topicUrl(1), documentUrl: undefined, innerWidth: 980, scriptFailure: false };
  const scripts = [], elements = new Map();
  const lastLink = { href: '#last-reply', style: { color: 'blue' }, textContent: 'Last reply' };
  const body = { style: { background: 'white' }, children: [lastLink], appendChild(node) {
    const oldIndex = this.children.indexOf(node);
    if (oldIndex >= 0) this.children.splice(oldIndex, 1);
    this.children.push(node); elements.set(node.id, node); return node;
  } };
  const document = { body, getElementById: id => elements.get(id) || null, createElement: tag => ({
    tagName: tag, id: '', style: {}, attributes: {}, setAttribute(name, value) { this.attributes[name] = value; }
  }) };
  const dom = vm.createContext({ document, window: { location: { href: config.currentUrl }, innerWidth: 980 } });
  const context = vm.createContext({ HttpClient: { getDomain: () => DOMAIN }, clearTimeout() {} });
  vm.runInContext(output.outputText, context, { filename });
  const host = new context.RealReader();
  Object.assign(host, { tid: TID, page: 1, selectedDomain: DOMAIN, currentWebPage: 1,
    readerActive: true, controllerAttached: true, webLoading: false, webFailureMessage: '',
    webViewportWidth: 400, bottomSafeAreaInset: 32, loadTimeout: -1,
    readerController: { getUrl: () => config.currentUrl, runJavaScript(script) {
      scripts.push(script);
      if (config.scriptFailure) return Promise.reject(new Error('Fixture closing controller'));
      dom.window.location.href = config.documentUrl ?? config.currentUrl;
      dom.window.innerWidth = config.innerWidth;
      vm.runInContext(script, dom);
      return Promise.resolve('');
    } }
  });
  const height = () => Number(elements.get(SPACER_ID)?.style.cssText.match(/(?:^|;)height:([0-9]+)px;/)?.[1]);
  return { host, config, scripts, elements, body, lastLink, height };
}

test('permitted page finish adds only a hidden scroll-tail spacer with vp-to-CSS viewport conversion', async () => {
  const f = fixture(); f.host.webLoading = true;
  f.host.onPageFinished({ url: topicUrl(1) }); await settle();
  const spacer = f.elements.get(SPACER_ID);
  assert.ok(spacer);
  assert.equal(spacer.attributes['aria-hidden'], 'true');
  assert.equal(f.height(), 79); // ceil(32 vp * 980 CSS px / 400 vp)
  assert.equal(f.body.children.at(-1), spacer);
  assert.equal(f.body.children.length, 2);
  assert.deepEqual(f.body.style, { background: 'white' });
  assert.deepEqual(f.lastLink, { href: '#last-reply', style: { color: 'blue' }, textContent: 'Last reply' });
});

test('inset and viewport changes resize the same tail element, including indicator disappearance', async () => {
  const f = fixture(); await f.host.updateBottomDocumentInset();
  const original = f.elements.get(SPACER_ID);
  f.host.bottomSafeAreaInset = 16; f.host.onBottomInsetChanged(); await settle();
  assert.equal(f.height(), 40);
  f.host.onWebViewportChanged({ width: 800 }); await settle();
  assert.equal(f.height(), 20);
  f.host.bottomSafeAreaInset = 0; f.host.onBottomInsetChanged(); await settle();
  assert.equal(f.height(), 0);
  assert.equal(f.elements.get(SPACER_ID), original);
  assert.equal(f.body.children.length, 2);
});

test('native guard prevents injection into blank, other topics, origins, or unsupported actions', async () => {
  for (const url of ['about:blank', 'https://other.invalid/read.php?tid=' + TID,
    DOMAIN + '/read.php?tid=1&page=1', topicUrl(1) + '&action=reply', topicUrl(1) + '&tid=' + TID]) {
    const f = fixture(); f.config.currentUrl = url;
    await f.host.updateBottomDocumentInset();
    assert.equal(f.scripts.length, 0, url);
    assert.equal(f.elements.size, 0, url);
  }
});

test('script rechecks exact document URL when navigation races the native current-URL guard', async () => {
  const f = fixture(); f.config.documentUrl = 'https://other.invalid/';
  await f.host.updateBottomDocumentInset();
  assert.equal(f.scripts.length, 1);
  assert.equal(f.elements.size, 0);
  assert.deepEqual(f.body.children, [f.lastLink]);
});

test('same-document pagination moves the existing spacer after newly added reply content', async () => {
  const f = fixture(); await f.host.updateBottomDocumentInset();
  const spacer = f.elements.get(SPACER_ID);
  const newReplyLink = { href: '#new-reply', textContent: 'New reply' };
  f.body.children.push(newReplyLink); f.config.currentUrl = topicUrl(2);
  f.host.onNavigationCommitted({ isMainFrame: true, isSameDocument: true, url: topicUrl(2) });
  await settle();
  assert.equal(f.host.currentWebPage, 2);
  assert.deepEqual(f.body.children, [f.lastLink, newReplyLink, spacer]);
  assert.equal(f.elements.size, 1);
});

test('loading, closed, failed, and invalid-size states skip controller script execution', async () => {
  for (const overrides of [{ readerActive: false }, { controllerAttached: false }, { webLoading: true },
    { webFailureMessage: 'offline' }, { webViewportWidth: 0 }, { webViewportWidth: NaN },
    { bottomSafeAreaInset: -1 }, { bottomSafeAreaInset: Infinity }]) {
    const f = fixture(); Object.assign(f.host, overrides);
    await f.host.updateBottomDocumentInset();
    assert.equal(f.scripts.length, 0);
    assert.equal(f.elements.size, 0);
  }
});

test('invalid or unchanged width events preserve the valid viewport without redundant injection', async () => {
  const f = fixture();
  for (const width of [0, NaN, -1, 400, 'auto']) f.host.onWebViewportChanged({ width });
  await settle();
  assert.equal(f.host.webViewportWidth, 400);
  assert.equal(f.scripts.length, 0);
});

test('a script failure during navigation leaves the current reader state readable', async () => {
  const f = fixture(); f.config.scriptFailure = true;
  await assert.doesNotReject(() => f.host.updateBottomDocumentInset());
  assert.equal(f.host.webLoading, false);
  assert.equal(f.host.webFailureMessage, '');
  assert.equal(f.host.readerActive, true);
});

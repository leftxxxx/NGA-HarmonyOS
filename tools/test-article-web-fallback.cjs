'use strict';

/* Run the real Web reader methods and its actual ArkUI event callbacks in a
 * local VM. Cookie values below are fabricated fixtures. No network requests,
 * real account reads, device operations or Web Cookie store access occur. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const devecoHome = process.env.DEVECO_HOME || 'D:/software/DevEco Studio';
const loaderRoot = path.join(devecoHome, 'sdk/default/openharmony/ets/build-tools/ets-loader');
const compilerPath = process.env.TYPESCRIPT_PATH || path.join(loaderRoot, 'node_modules/typescript');
assert.ok(fs.existsSync(compilerPath), 'Set DEVECO_HOME or TYPESCRIPT_PATH to the DevEco SDK compiler');
const ts = require(compilerPath);
const componentMap = require(path.join(loaderRoot, 'lib/component_map.js'));

function transpile(source, filename) {
  const result = ts.transpileModule(source, {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  const errors = (result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
  assert.deepEqual(errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
  return result.outputText;
}

const sourcePath = path.join(root, 'entry/src/main/ets/components/ArticleWebFallback.ets');
const source = fs.readFileSync(sourcePath, 'utf8');
const ast = ts.createSourceFile(sourcePath, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS,
  { ets: { components: Object.keys(componentMap.COMPONENT_MAP).concat(['ArticleWebFallback']) } });
assert.deepEqual(ast.parseDiagnostics.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
const component = ast.statements.find(node => node.name && node.name.getText(ast) === 'ArticleWebFallback');
assert.ok(component, 'Actual ArticleWebFallback component');
const methods = component.members.filter(ts.isMethodDeclaration);
const build = methods.find(node => node.name.getText(ast) === 'build');
assert.ok(build, 'Actual component build method');
const events = new Map();
let webOptions;
function inspectBuild(node) {
  if (ts.isEtsComponentExpression(node) && ts.isIdentifier(node.expression) &&
    node.expression.getText(ast) === 'Web') {
    assert.ok(!webOptions, 'A single actual Web component');
    webOptions = node.arguments[0].getText(ast);
  }
  if (ts.isCallExpression(node)) {
    if (ts.isPropertyAccessExpression(node.expression)) {
      const name = node.expression.name.getText(ast);
      if (name.startsWith('on') && node.arguments.length === 1 && ts.isArrowFunction(node.arguments[0])) {
        if (['onControllerAttached', 'onLoadIntercept', 'onPageBegin', 'onPageEnd', 'onErrorReceive',
          'onHttpErrorReceive', 'onSslErrorEventReceive', 'onRenderExited', 'onNavigationEntryCommitted'].includes(name)) {
          assert.ok(!events.has(name), 'A single actual Web event callback for ' + name);
          events.set(name, node.arguments[0].getText(ast));
        }
        if (name === 'onClick') {
          let returnsNative = false;
          function inspectReturn(child) {
            if (ts.isPropertyAccessExpression(child) && child.expression.kind === ts.SyntaxKind.ThisKeyword &&
              child.name.getText(ast) === 'onRetryNative') returnsNative = true;
            ts.forEachChild(child, inspectReturn);
          }
          inspectReturn(node.arguments[0]);
          if (returnsNative) {
            assert.ok(!events.has('onReturnNative'), 'A single actual return-to-native action');
            events.set('onReturnNative', node.arguments[0].getText(ast));
          }
        }
      }
    } else if (ts.isIdentifier(node.expression) && node.expression.getText(ast) === 'Web') {
      assert.ok(!webOptions, 'A single actual Web component');
      webOptions = node.arguments[0].getText(ast);
    }
  }
  ts.forEachChild(node, inspectBuild);
}
inspectBuild(build);
for (const event of ['onControllerAttached', 'onLoadIntercept', 'onPageBegin', 'onPageEnd',
  'onErrorReceive', 'onHttpErrorReceive', 'onSslErrorEventReceive', 'onRenderExited', 'onReturnNative',
  'onNavigationEntryCommitted']) {
  assert.ok(events.has(event), 'Actual Web callback ' + event);
}
assert.ok(webOptions, 'Actual Web creation options');
const constants = ast.statements.filter(ts.isVariableStatement).map(node => node.getText(ast)).join('\n');
const realClass = transpile(constants + '\nclass RealWebReader {\n' +
  methods.filter(node => node !== build).map(node => node.getText(ast)).join('\n') +
  '\ncreateRealCallbacks() { return {\n' +
  Array.from(events, ([name, callback]) => name + ': ' + callback).join(',\n') +
  '\n}; }\ncreateRealWebOptions() { return ' + webOptions + '; }\n' +
  '}\nglobalThis.RealWebReader = RealWebReader;', 'ArticleWebFallbackMethods.ts');

const DOMAIN = 'https://forum.invalid';
const TID = 44191387;
function topicUrl(page = 1, domain = DOMAIN) { return domain + '/read.php?tid=' + TID + '&page=' + page; }

function fixture() {
  const config = { domain: DOMAIN, cookie: '', cookieFailure: false, loadFailure: false };
  const cookieCalls = [], loads = [], stops = [], logs = [], retries = [], timerDelays = [], clearedTimers = [];
  const timers = new Map();
  let nextTimer = 0;
  const onlyCookieApi = new Proxy({ configCookieSync(url, cookie, incognito) {
    cookieCalls.push({ url, cookie, incognito });
    if (config.cookieFailure) throw new Error('synthetic-cookie-API-detail');
  } }, { get(target, name) {
    assert.ok(Object.hasOwn(target, name), 'Unexpected Web Cookie API: ' + String(name));
    return target[name];
  } });
  const context = vm.createContext({
    HttpClient: { getDomain: () => config.domain },
    LoginStore: new Proxy({ getCookie: () => config.cookie }, { get(target, name) {
      assert.ok(Object.hasOwn(target, name), 'Unexpected account operation: ' + String(name));
      return target[name];
    } }),
    webview: { WebCookieManager: onlyCookieApi },
    setTimeout(callback, delay) {
      const timer = ++nextTimer; timers.set(timer, callback); timerDelays.push(delay); return timer;
    },
    clearTimeout(timer) { timers.delete(timer); clearedTimers.push(timer); },
    console: Object.fromEntries(['info', 'warn', 'error', 'log', 'debug'].map(name => [name,
      (...args) => logs.push({ name, args })]))
  });
  vm.runInContext(realClass, context);
  const host = new context.RealWebReader();
  const controller = {
    stop() { stops.push(true); },
    loadUrl(url) {
      loads.push(url);
      if (config.loadFailure) throw new Error('synthetic-controller-API-detail');
    }
  };
  Object.assign(host, {
    tid: TID, page: 1, nightMode: false, webLoading: true, webFailureMessage: '', navigationNotice: '',
    readerController: controller, controllerAttached: false, readerActive: false,
    selectedDomain: '', loadTimeout: -1, currentWebPage: 1,
    initialBlankFinished: false, initialTopicStarted: false,
    onRetryNative: page => retries.push(page)
  });
  const callbacks = host.createRealCallbacks();
  function open() {
    host.aboutToAppear();
    callbacks.onControllerAttached();
    callbacks.onPageEnd({ url: 'about:blank' });
  }
  function fireTimer(timer = host.loadTimeout) {
    assert.ok(timers.has(timer), 'Expected an active Web loading timer');
    const callback = timers.get(timer); timers.delete(timer); callback();
  }
  return { host, config, controller, callbacks, cookieCalls, loads, stops, logs, retries,
    timerDelays, clearedTimers, timers, open, fireTimer };
}

function request(url = topicUrl(), method = 'GET', mainFrame = true) {
  return { getRequestUrl: () => url, getRequestMethod: () => method, isMainFrame: () => mainFrame };
}
function intercept(f, url = topicUrl(), method = 'GET', mainFrame = true) {
  return f.callbacks.onLoadIntercept({ data: request(url, method, mainFrame) });
}
function expectPrivateCurrentOrigin(f) {
  for (const call of f.cookieCalls) {
    assert.equal(call.url, DOMAIN);
    assert.equal(call.incognito, true);
    assert.doesNotMatch(call.cookie, /(?:^|;)\s*Domain=/i, 'Cookie must not expand its domain');
  }
  assert.deepEqual(f.logs, [], 'Credential handling must not print Cookie values or API exceptions');
}
function expectExpiredAuthOnly(calls) {
  assert.equal(calls.length, 2);
  assert.deepEqual(calls.map(call => call.cookie.split(';')[0]), ['ngaPassportUid=', 'ngaPassportCid=']);
  for (const call of calls) {
    assert.match(call.cookie, /(?:^|;)\s*Max-Age=0(?:;|$)/);
    assert.match(call.cookie, /(?:^|;)\s*Path=\/(?:;|$)/);
    assert.match(call.cookie, /(?:^|;)\s*Secure(?:;|$)/);
    assert.match(call.cookie, /(?:^|;)\s*HttpOnly(?:;|$)/);
  }
}

test('Web starts blank in a private jar and waits for both controller and blank completion before loading credentials', () => {
  const f = fixture();
  const options = f.host.createRealWebOptions();
  assert.equal(options.src, 'about:blank');
  assert.equal(options.incognitoMode, true);
  assert.equal(options.controller, f.controller);
  f.host.loadCurrentTopic();
  assert.equal(f.loads.length, 0);
  assert.equal(f.cookieCalls.length, 0);
  f.host.aboutToAppear();
  f.host.loadCurrentTopic();
  assert.equal(f.loads.length, 0);
  assert.equal(f.cookieCalls.length, 0);
  f.callbacks.onControllerAttached();
  assert.equal(f.loads.length, 0);
  assert.equal(f.cookieCalls.length, 0);
  assert.equal(f.host.controllerAttached, true);
  f.callbacks.onPageEnd({ url: 'about:blank' });
  assert.deepEqual(f.loads, [topicUrl()]);
  assert.equal(f.host.readerActive, true);
  assert.equal(f.host.controllerAttached, true);
  expectPrivateCurrentOrigin(f);
});

test('both attachment and blank-completion orders start the initial topic exactly once', () => {
  for (const order of ['attach-first', 'blank-first']) {
    const f = fixture(); f.host.aboutToAppear();
    if (order === 'attach-first') f.callbacks.onControllerAttached();
    else f.callbacks.onPageEnd({ url: 'about:blank' });
    assert.equal(f.loads.length, 0, order);
    assert.equal(f.cookieCalls.length, 0, order);
    assert.equal(f.host.initialTopicStarted, false, order);
    if (order === 'attach-first') f.callbacks.onPageEnd({ url: 'about:blank' });
    else f.callbacks.onControllerAttached();
    assert.deepEqual(f.loads, [topicUrl()], order);
    expectExpiredAuthOnly(f.cookieCalls);
    assert.equal(f.host.initialBlankFinished, true, order);
    assert.equal(f.host.initialTopicStarted, true, order);
    assert.equal(f.timers.size, 1, order);
  }
});

test('repeated or late blank and attached events never restart an already started topic', () => {
  const f = fixture(); f.open();
  const initialTimer = f.host.loadTimeout;
  for (let eventCount = 0; eventCount < 3; eventCount++) {
    f.callbacks.onPageEnd({ url: 'about:blank' });
    f.callbacks.onControllerAttached();
    assert.equal(f.loads.length, 1);
    assert.equal(f.cookieCalls.length, 2);
    assert.equal(f.host.loadTimeout, initialTimer);
  }
  f.callbacks.onPageEnd({ url: topicUrl() });
  f.callbacks.onPageEnd({ url: 'about:blank' });
  f.callbacks.onControllerAttached();
  assert.equal(f.loads.length, 1);
  assert.equal(f.cookieCalls.length, 2);
  assert.equal(f.host.webLoading, false);
  assert.equal(f.timers.size, 0);
});

test('leaving before either initialization event makes both late orders inert', () => {
  for (const priorEvent of ['none', 'attached', 'blank']) {
    const f = fixture(); f.host.aboutToAppear();
    if (priorEvent === 'attached') f.callbacks.onControllerAttached();
    if (priorEvent === 'blank') f.callbacks.onPageEnd({ url: 'about:blank' });
    f.host.aboutToDisappear();
    f.callbacks.onControllerAttached();
    f.callbacks.onPageEnd({ url: 'about:blank' });
    f.host.tryStartInitialTopic();
    assert.equal(f.loads.length, 0, priorEvent);
    assert.equal(f.cookieCalls.length, 0, priorEvent);
    assert.equal(f.timers.size, 0, priorEvent);
    assert.equal(f.host.readerActive, false, priorEvent);
    assert.equal(f.host.controllerAttached, false, priorEvent);
    assert.equal(f.host.initialBlankFinished, false, priorEvent);
    assert.equal(f.host.initialTopicStarted, false, priorEvent);
  }
});

test('target changes during initial blank loading defer to a single load of the latest target', () => {
  const f = fixture(); f.host.aboutToAppear(); f.callbacks.onControllerAttached();
  f.host.page = 3; f.host.onTargetChanged();
  assert.equal(f.loads.length, 0);
  assert.equal(f.cookieCalls.length, 0);
  f.callbacks.onPageEnd({ url: 'about:blank' });
  assert.deepEqual(f.loads, [topicUrl(3)]);
  assert.equal(f.host.currentWebPage, 3);
  assert.equal(f.cookieCalls.length, 2);
});

test('waiting for initial blank completion has a bounded watchdog and a late completion can recover', () => {
  const f = fixture(); f.host.aboutToAppear(); f.callbacks.onControllerAttached();
  assert.deepEqual(f.timerDelays, [20000]);
  assert.equal(f.loads.length, 0);
  f.fireTimer();
  assert.equal(f.host.webLoading, false);
  assert.match(f.host.webFailureMessage, /超时/);
  f.callbacks.onPageEnd({ url: 'about:blank' });
  assert.deepEqual(f.loads, [topicUrl()]);
  assert.equal(f.host.webLoading, true);
  assert.equal(f.host.webFailureMessage, '');
  assert.equal(f.timers.size, 1);
});

test('an empty login expires exactly the two authentication names for the current private origin', () => {
  const f = fixture(); f.open();
  expectExpiredAuthOnly(f.cookieCalls);
  expectPrivateCurrentOrigin(f);
  assert.deepEqual(f.loads, [topicUrl()]);
});

test('the active account replaces authentication entries individually without copying unrelated cookies', () => {
  const f = fixture();
  f.config.cookie = ' unrelated=fixture; ngaPassportUid=fixture-user; ngaPassportCid=fixture-token ; other=ignored';
  f.open();
  expectExpiredAuthOnly(f.cookieCalls.slice(0, 2));
  assert.deepEqual(f.cookieCalls.slice(2).map(call => call.cookie.split(';')[0]),
    ['ngaPassportUid=fixture-user', 'ngaPassportCid=fixture-token']);
  assert.equal(f.cookieCalls.length, 4);
  for (const call of f.cookieCalls.slice(2)) {
    assert.match(call.cookie, /; Path=\/; Secure; HttpOnly$/);
    assert.doesNotMatch(call.cookie, /Max-Age=0/);
  }
  expectPrivateCurrentOrigin(f);
});

test('reload after logout removes private authentication left by the previous account', () => {
  const f = fixture(); f.config.cookie = 'ngaPassportUid=old-fixture; ngaPassportCid=old-token'; f.open();
  f.callbacks.onPageEnd({ url: topicUrl() });
  f.config.cookie = '';
  f.host.loadCurrentTopic();
  expectExpiredAuthOnly(f.cookieCalls.slice(4));
  assert.deepEqual(f.loads, [topicUrl(), topicUrl()]);
  expectPrivateCurrentOrigin(f);
});

test('reload after account switch replaces the old private authentication before the next document', () => {
  const f = fixture(); f.config.cookie = 'ngaPassportUid=old-fixture; ngaPassportCid=old-token'; f.open();
  f.config.cookie = 'ngaPassportUid=new-fixture; ngaPassportCid=new-token';
  f.host.loadCurrentTopic();
  expectExpiredAuthOnly(f.cookieCalls.slice(4, 6));
  assert.deepEqual(f.cookieCalls.slice(6).map(call => call.cookie.split(';')[0]),
    ['ngaPassportUid=new-fixture', 'ngaPassportCid=new-token']);
  expectPrivateCurrentOrigin(f);
});

test('malformed or non-authentication Cookie pairs cannot inject Cookie attributes', () => {
  const f = fixture();
  f.config.cookie = 'ngaPassportUid=; ngaPassportCid=line\r\nbreak; Domain=elsewhere.invalid; Path=/other; unrelated=x';
  f.open();
  expectExpiredAuthOnly(f.cookieCalls);
  expectPrivateCurrentOrigin(f);
});

test('a changed selected domain stops loading before any Cookie destination or account access', () => {
  const f = fixture(); f.host.aboutToAppear(); f.config.domain = 'https://changed.invalid';
  f.callbacks.onControllerAttached();
  f.callbacks.onPageEnd({ url: 'about:blank' });
  assert.equal(f.cookieCalls.length, 0);
  assert.equal(f.loads.length, 0);
  assert.match(f.host.webFailureMessage, /地址已变化/);
  assert.equal(f.host.webLoading, false);
  assert.equal(f.timers.size, 0);
});

test('invalid origins, thread identifiers and page numbers never configure credentials', () => {
  for (const domain of ['http://forum.invalid', 'https://forum.invalid/', 'https://forum.invalid/path',
    'https://forum.invalid:443', 'https://user@forum.invalid', 'https://forum.invalid?x=1']) {
    const f = fixture(); f.config.domain = domain; f.open();
    assert.equal(f.cookieCalls.length, 0, domain);
    assert.equal(f.loads.length, 0, domain);
    assert.equal(f.host.webLoading, false);
  }
  for (const field of ['tid', 'page']) {
    for (const value of [0, -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
      const f = fixture(); f.host[field] = value; f.open();
      assert.equal(f.cookieCalls.length, 0, field + '=' + value);
      assert.equal(f.loads.length, 0, field + '=' + value);
      assert.equal(f.host.webLoading, false);
    }
  }
});

test('Cookie or controller failures show a generic recoverable error and expose no API details', () => {
  for (const failure of ['cookieFailure', 'loadFailure']) {
    const f = fixture(); f.config[failure] = true; f.open();
    assert.equal(f.host.webLoading, false);
    assert.match(f.host.webFailureMessage, /暂时无法打开/);
    assert.doesNotMatch(f.host.webFailureMessage, /synthetic|fixture/);
    assert.equal(f.timers.size, 0);
    expectPrivateCurrentOrigin(f);
    f.config[failure] = false;
    f.host.loadCurrentTopic();
    assert.equal(f.loads.at(-1), topicUrl());
    assert.equal(f.host.webLoading, true);
    assert.equal(f.host.webFailureMessage, '');
  }
});

test('only current-origin current-thread GET main-frame pagination passes the navigation guard', () => {
  const f = fixture(); f.open();
  for (const url of [topicUrl(), topicUrl(28), DOMAIN + '/read.php?tid=' + TID,
    DOMAIN + '/read.php?page=2&tid=' + TID, topicUrl(2) + '#reply']) {
    assert.equal(intercept(f, url), false, url);
  }
  assert.equal(intercept(f, topicUrl(), 'get'), false);
  assert.equal(f.host.navigationNotice, '');
});

test('cross-origin, another thread and non-reader routes are blocked without loading a document', () => {
  const f = fixture(); f.open();
  const priorLoads = f.loads.length;
  for (const url of [topicUrl(1, 'https://other.invalid'), topicUrl().replace(String(TID), '44191388'),
    DOMAIN + '/thread.php?fid=-7', DOMAIN + '/post.php?tid=' + TID,
    DOMAIN + '.other.invalid/read.php?tid=' + TID, 'http://forum.invalid/read.php?tid=' + TID,
    'https://forum.invalid:443/read.php?tid=' + TID, 'javascript:alert(1)', 'data:text/html,test']) {
    assert.equal(intercept(f, url), true, url);
  }
  assert.equal(f.loads.length, priorLoads);
  assert.match(f.host.navigationNotice, /仅查看当前话题/);
});

test('POST and other non-GET main-frame methods cannot perform forum actions even at a permitted URL', () => {
  const f = fixture(); f.open();
  for (const method of ['POST', 'post', 'PUT', 'DELETE', 'HEAD']) {
    assert.equal(intercept(f, topicUrl(), method), true, method);
  }
  assert.match(f.host.navigationNotice, /其他操作请返回应用/);
  assert.equal(f.loads.length, 1);
});

test('duplicate, action, encoded and invalid pagination parameters cannot widen the reader scope', () => {
  const f = fixture(); f.open();
  for (const suffix of ['&action=reply', '&tid=' + TID, '&page=2', '&x=1', '&=', '&empty', '&']) {
    assert.equal(intercept(f, topicUrl() + suffix), true, suffix);
  }
  for (const query of ['tid=' + TID + '&page=0', 'tid=' + TID + '&page=-1',
    'tid=' + TID + '&page=1.5', 'tid=' + TID + '&page=01', 'tid=' + TID + '&page=%32',
    'tid=' + TID + '&page=9007199254740992',
    'tid=%34' + String(TID).slice(1), 'page=2', 'tid=' + TID + '%26action=reply']) {
    assert.equal(intercept(f, DOMAIN + '/read.php?' + query), true, query);
  }
});

test('initial blank and subresource loads do not display an unrelated navigation warning', () => {
  const f = fixture(); f.open();
  assert.equal(intercept(f, 'about:blank'), false);
  assert.equal(intercept(f, 'https://image.invalid/image.png', 'GET', false), false);
  assert.equal(f.host.navigationNotice, '');
});

test('domain switching while open immediately blocks even a formerly permitted topic navigation', () => {
  const f = fixture(); f.open(); f.config.domain = 'https://changed.invalid';
  assert.equal(intercept(f), true);
  assert.equal(f.cookieCalls.length, 2);
  assert.equal(f.loads.length, 1);
});

test('current-topic page begin and successful end update loading and cancel the watchdog', () => {
  const f = fixture(); f.open();
  f.host.webFailureMessage = 'previous fixture failure';
  f.callbacks.onPageBegin({ url: topicUrl(2) });
  assert.equal(f.host.webLoading, true);
  assert.equal(f.host.webFailureMessage, '');
  assert.equal(f.timers.size, 1);
  f.callbacks.onPageEnd({ url: topicUrl(2) });
  assert.equal(f.host.webLoading, false);
  assert.equal(f.timers.size, 0);
  assert.equal(f.host.loadTimeout, -1);
  assert.equal(f.host.currentWebPage, 2);
});

test('returning to native reading uses the last successful same-topic web page', () => {
  const f = fixture(); f.host.page = 3; f.open();
  assert.equal(f.host.currentWebPage, 3);
  f.callbacks.onPageEnd({ url: topicUrl(3) });
  f.callbacks.onPageBegin({ url: topicUrl(5) });
  f.callbacks.onPageEnd({ url: topicUrl(5) });
  f.callbacks.onReturnNative();
  assert.deepEqual(f.retries, [5]);
  assert.equal(f.host.page, 3, 'Web pagination must not mutate the native target prop');
  assert.equal(f.loads.length, 1);
});

test('NGA same-document AJAX pagination updates the return page without a new page-end event', () => {
  const f = fixture(); f.open(); f.callbacks.onPageEnd({ url: topicUrl() });
  assert.equal(f.host.webLoading, false);
  const priorCookieCalls = f.cookieCalls.length;
  f.callbacks.onNavigationEntryCommitted({
    url: topicUrl(2), isMainFrame: true, isSameDocument: true
  });
  assert.equal(f.host.currentWebPage, 2);
  f.callbacks.onReturnNative();
  assert.deepEqual(f.retries, [2]);
  assert.equal(f.host.page, 1, 'AJAX navigation must not change the native target prop');
  assert.equal(f.host.webLoading, false, 'A committed same-document navigation does not restart loading');
  assert.equal(f.timers.size, 0);
  assert.equal(f.loads.length, 1);
  assert.equal(f.cookieCalls.length, priorCookieCalls);
});

test('same-document history and fragment commits keep the validated current page for native return', () => {
  const f = fixture(); f.open(); f.callbacks.onPageEnd({ url: topicUrl(3) });
  for (const [url, page] of [[topicUrl(4) + '#reply', 4],
    [DOMAIN + '/read.php?page=2&tid=' + TID, 2], [DOMAIN + '/read.php?tid=' + TID + '#first', 1]]) {
    f.callbacks.onNavigationEntryCommitted({ url, isMainFrame: true, isSameDocument: true });
    f.callbacks.onReturnNative();
    assert.equal(f.host.currentWebPage, page);
    assert.equal(f.retries.at(-1), page);
  }
  assert.equal(f.loads.length, 1);
});

test('subframe, new-document, cross-origin and invalid topic commits cannot change the native return page', () => {
  const f = fixture(); f.open(); f.callbacks.onPageEnd({ url: topicUrl(3) });
  for (const details of [
    { url: topicUrl(2), isMainFrame: false, isSameDocument: true },
    { url: topicUrl(2), isMainFrame: true, isSameDocument: false },
    { url: topicUrl(2, 'https://other.invalid'), isMainFrame: true, isSameDocument: true },
    { url: topicUrl(2).replace(String(TID), '44191388'), isMainFrame: true, isSameDocument: true },
    { url: topicUrl(2) + '&action=reply', isMainFrame: true, isSameDocument: true },
    { url: 'about:blank', isMainFrame: true, isSameDocument: true }
  ]) {
    f.callbacks.onNavigationEntryCommitted(details);
    assert.equal(f.host.currentWebPage, 3, JSON.stringify(details));
  }
  f.callbacks.onReturnNative();
  assert.deepEqual(f.retries, [3]);
  assert.equal(f.host.webLoading, false);
  assert.equal(f.timers.size, 0);
});

test('an unsuccessful web pagination keeps the last completed page for native retry', () => {
  const f = fixture(); f.open();
  f.callbacks.onPageEnd({ url: topicUrl(2) });
  f.callbacks.onPageBegin({ url: topicUrl(3) });
  f.callbacks.onErrorReceive({ request: request(topicUrl(3)) });
  f.callbacks.onReturnNative();
  assert.deepEqual(f.retries, [2]);
  assert.equal(f.host.currentWebPage, 2);
});

test('a same-thread URL without an explicit page returns to native page one', () => {
  const f = fixture(); f.host.page = 3; f.open();
  f.callbacks.onPageEnd({ url: DOMAIN + '/read.php?tid=' + TID + '#reply' });
  f.callbacks.onReturnNative();
  assert.deepEqual(f.retries, [1]);
});

test('blank, foreign and another-thread page events cannot complete the current topic load', () => {
  const f = fixture(); f.open();
  const initialTimer = f.host.loadTimeout;
  for (const url of ['about:blank', topicUrl(1, 'https://other.invalid'),
    topicUrl().replace(String(TID), '44191388')]) {
    f.callbacks.onPageBegin({ url });
    f.callbacks.onPageEnd({ url });
    assert.equal(f.host.webLoading, true);
    assert.equal(f.host.loadTimeout, initialTimer);
    assert.equal(f.timers.size, 1);
  }
});

test('image and other resource errors leave the main document available to complete', () => {
  const f = fixture(); f.open();
  f.callbacks.onErrorReceive({ request: request('https://image.invalid/image.png', 'GET', false) });
  f.callbacks.onHttpErrorReceive({ request: request('https://image.invalid/image.png', 'GET', false),
    response: { getResponseCode: () => 404 } });
  assert.equal(f.host.webFailureMessage, '');
  assert.equal(f.host.webLoading, true);
  assert.equal(f.timers.size, 1);
  f.callbacks.onPageEnd({ url: topicUrl() });
  assert.equal(f.host.webLoading, false);
  assert.equal(f.host.webFailureMessage, '');
});

test('main-frame network and HTTP failures clear loading and offer a retry without leaking request details', () => {
  for (const eventType of ['onErrorReceive', 'onHttpErrorReceive']) {
    const f = fixture(); f.open();
    f.callbacks[eventType]({ request: request(), response: { getResponseCode: () => 503 } });
    assert.equal(f.host.webLoading, false);
    assert.equal(f.timers.size, 0);
    assert.ok(f.host.webFailureMessage.length > 0);
    assert.doesNotMatch(f.host.webFailureMessage, /forum\.invalid|ngaPassport/);
    if (eventType === 'onHttpErrorReceive') assert.match(f.host.webFailureMessage, /HTTP 503/);
    f.host.loadCurrentTopic();
    assert.equal(f.host.webLoading, true);
    assert.equal(f.host.webFailureMessage, '');
    assert.deepEqual(f.loads, [topicUrl(), topicUrl()]);
    expectPrivateCurrentOrigin(f);
  }
});

test('the initial blank document network error cannot replace the topic with an error overlay', () => {
  const f = fixture(); f.open();
  f.callbacks.onErrorReceive({ request: request('about:blank') });
  assert.equal(f.host.webFailureMessage, '');
  assert.equal(f.host.webLoading, true);
  assert.equal(f.timers.size, 1);
});

test('a bounded loading watchdog reports a stalled document and supports a fresh retry', () => {
  const f = fixture(); f.open();
  assert.ok(f.timerDelays.length > 0);
  assert.ok(f.timerDelays.every(delay => delay === 20000));
  f.fireTimer();
  assert.equal(f.host.webLoading, false);
  assert.match(f.host.webFailureMessage, /超时/);
  assert.equal(f.timers.size, 0);
  f.host.loadCurrentTopic();
  assert.equal(f.host.webLoading, true);
  assert.equal(f.host.webFailureMessage, '');
  assert.equal(f.timers.size, 1);
});

test('SSL certificate failures are cancelled and a renderer exit produces a recoverable failure', () => {
  const f = fixture(); f.open();
  let cancelled = 0;
  f.callbacks.onSslErrorEventReceive({ handler: { handleCancel() { cancelled++; } } });
  assert.equal(cancelled, 1);
  f.callbacks.onRenderExited();
  assert.equal(f.host.webLoading, false);
  assert.match(f.host.webFailureMessage, /已中断/);
  assert.equal(f.timers.size, 0);
  assert.deepEqual(f.logs, []);
});

test('changing the native target loads its new page with current-origin private credentials', () => {
  const f = fixture(); f.open();
  f.host.page = 3; f.host.onTargetChanged();
  assert.deepEqual(f.loads, [topicUrl(), topicUrl(3)]);
  assert.equal(f.timers.size, 1);
  expectPrivateCurrentOrigin(f);
});

test('leaving stops the Web controller and cancels loading without logging out or clearing global cookies', () => {
  const f = fixture(); f.config.cookie = 'ngaPassportUid=fixture-user; ngaPassportCid=fixture-token'; f.open();
  const priorCookieCalls = f.cookieCalls.length;
  const priorStops = f.stops.length;
  f.host.aboutToDisappear();
  assert.equal(f.host.readerActive, false);
  assert.equal(f.host.controllerAttached, false);
  assert.equal(f.host.loadTimeout, -1);
  assert.equal(f.timers.size, 0);
  assert.equal(f.stops.length, priorStops + 1);
  assert.equal(f.cookieCalls.length, priorCookieCalls);
  expectPrivateCurrentOrigin(f);
});

test('page, error, renderer and cancelled timeout events arriving after exit cannot mutate the closed reader', () => {
  const f = fixture(); f.open();
  const lateTimer = f.timers.get(f.host.loadTimeout);
  f.host.aboutToDisappear();
  const state = [f.host.webLoading, f.host.webFailureMessage, f.host.navigationNotice, f.host.currentWebPage];
  f.callbacks.onPageBegin({ url: topicUrl(2) });
  f.callbacks.onPageEnd({ url: topicUrl(2) });
  f.callbacks.onErrorReceive({ request: request() });
  f.callbacks.onHttpErrorReceive({ request: request(), response: { getResponseCode: () => 500 } });
  f.callbacks.onRenderExited();
  f.callbacks.onNavigationEntryCommitted({ url: topicUrl(2), isMainFrame: true, isSameDocument: true });
  lateTimer();
  f.host.onTargetChanged();
  f.host.loadCurrentTopic();
  assert.equal(intercept(f), true);
  assert.deepEqual([f.host.webLoading, f.host.webFailureMessage, f.host.navigationNotice, f.host.currentWebPage], state);
  assert.equal(f.loads.length, 1);
  assert.equal(f.cookieCalls.length, 2);
  assert.equal(f.timers.size, 0);
  assert.equal(f.retries.length, 0);
});

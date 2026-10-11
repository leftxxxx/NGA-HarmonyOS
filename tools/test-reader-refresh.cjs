'use strict';

/* Execute the actual reader methods with the DevEco ETS compiler.
 * HTTP, cached responses, timers and touch events are local fixtures.
 * This test never requests a forum page or operates a connected device.
 */
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

require.extensions['.ets'] = (module, filename) => {
  module._compile(transpile(fs.readFileSync(filename, 'utf8'), filename), filename);
};
const { NgaJsonParser } = require('../entry/src/main/ets/model/NgaJsonParser.ets');

function isolatedModel(name, dependencies) {
  const filename = path.join(root, 'entry/src/main/ets/model', name + '.ets');
  const module = { exports: {} };
  const evaluate = vm.runInThisContext('(function(require, module, exports) {\n' +
    transpile(fs.readFileSync(filename, 'utf8'), filename) + '\n})', { filename });
  evaluate(id => {
    assert.ok(Object.hasOwn(dependencies, id), 'Unexpected model dependency: ' + id);
    return dependencies[id];
  }, module, module.exports);
  return module.exports[name];
}
const UrlBuilder = isolatedModel('UrlBuilder', {
  './HttpClient': { HttpClient: { getDomain: () => 'https://forum.invalid' } }
});

const pagePath = path.join(root, 'entry/src/main/ets/pages/ArticleListPage.ets');
const pageSource = fs.readFileSync(pagePath, 'utf8');
const localComponents = ['ArticleBody', 'ArticleImageViewer', 'ArticleWebFallback'];
const pageAst = ts.createSourceFile(pagePath, pageSource, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS,
  { ets: { components: Object.keys(componentMap.COMPONENT_MAP).concat(localComponents) } });
assert.deepEqual(pageAst.parseDiagnostics.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
const component = pageAst.statements.find(node => node.name && node.name.getText(pageAst) === 'ArticleListPage');
assert.ok(component, 'Actual ArticleListPage component');
const pageMethods = new Map(component.members.filter(ts.isMethodDeclaration)
  .map(method => [method.name.getText(pageAst), method]));
const constants = pageAst.statements.filter(ts.isVariableStatement).map(node => node.getText(pageAst)).join('\n');

function realMethods(names, globals) {
  const selected = new Map();
  function add(name) {
    if (selected.has(name)) return;
    const method = pageMethods.get(name);
    assert.ok(method, 'Missing actual page method ' + name);
    selected.set(name, method);
    function visit(node) {
      if (ts.isPropertyAccessExpression(node) && node.expression.kind === ts.SyntaxKind.ThisKeyword) {
        const dependency = node.name.getText(pageAst);
        if (pageMethods.has(dependency)) add(dependency);
      }
      ts.forEachChild(node, visit);
    }
    visit(method.body);
  }
  names.forEach(add);
  const context = vm.createContext(globals);
  vm.runInContext(transpile(constants + '\nclass RealPage {\n' +
    Array.from(selected.values(), method => method.getText(pageAst)).join('\n') +
    '\n}\nglobalThis.RealPage = RealPage;', 'ReaderRefreshMethods.ts'), context);
  return new context.RealPage();
}

const TID = 47664817;
const TouchType = { Down: 0, Up: 1, Move: 2, Cancel: 3 };
const ScrollSource = { DRAG: 1, FLING: 2, EDGE_EFFECT: 3, SCROLLER: 4, SCROLLER_ANIMATION: 5, NONE: 0 };
function response(content = '刷新后的本地正文', totalRows = 60) {
  return { success: true, body: JSON.stringify({ data: {
    __T: { tid: TID, subject: '本地测试话题' }, __ROWS: totalRows,
    __R: [{ tid: TID, pid: 0, lou: 0, content }]
  } }) };
}

function incompleteResponse() {
  return { success: true, body: '{"data":{"__T":{"tid":' + TID +
    '},"__R":[{"tid":' + TID + ',"content":"正文已经返回","attachs' };
}

function fixture() {
  const requests = [], requestOptions = [], toasts = [], timers = [], timerDelays = [], cacheReads = [], cacheChecks = [];
  const cached = new Map();
  const config = { get: async () => response(), atEnd: true };
  const host = realMethods(['pullRefreshArticle', 'readerTouch', 'readerScroll', 'turnNextPage',
    'reportReadError', 'loadArticleData', 'aboutToDisappear', 'refreshArticle', 'changePage',
    'openWebFallback', 'retryNativeReading'], {
    NgaJsonParser, UrlBuilder, TouchType, ScrollSource,
    HttpClient: { get: (url, extraHeaders, usingCache) => {
      requests.push(url);
      requestOptions.push({ extraHeaders, usingCache });
      return config.get(url, extraHeaders, usingCache);
    } },
    ArticleCacheStore: {
      hasCachePage: (tid, page) => {
        cacheChecks.push({ tid, page }); return cached.has(tid + ':' + page);
      },
      loadCachePage: (tid, page) => {
        cacheReads.push({ tid, page }); return cached.get(tid + ':' + page) || '';
      }
    },
    setTimeout: (callback, delay) => {
      timers.push({ callback, delay }); timerDelays.push(delay); return timerDelays.length;
    },
    console: { info() {}, warn() {}, error() {} }
  });
  const originalRows = [{ content: '已有本地正文', pid: 0 }];
  Object.assign(host, {
    tid: TID, fid: -7, title: '本地测试话题', currentPage: 2, requestedPage: 2,
    totalPages: 3, totalRows: 60, isLoading: false, isRefreshing: false, isTurningPage: false,
    rowList: originalRows, rawData: '已有响应', attachmentBase: '', articleRevision: 0,
    loadError: '', pageTurnFeedback: '', currentPageCached: false, isCacheMode: false,
    webFallbackPage: 0, webFallbackAvailable: false, webFallbackTargetPage: 1,
    readerMounted: true, loadVersion: 0, readerAtEnd: false, refreshRequest: false,
    pageTurnDistance: 0, turnGestureConsumed: false, showPageSheet: false, pageInputError: '',
    articleScroller: { isAtEnd: () => config.atEnd },
    getUIContext: () => ({ getPromptAction: () => ({ showToast: toast => { toasts.push({ ...toast }); } }) })
  });
  function touch(type) { host.readerTouch({ type, touches: [], changedTouches: [] }); }
  function runTimers() { while (timers.length) timers.shift().callback(); }
  function runNextTimer() {
    assert.ok(timers.length > 0, 'Expected a scheduled retry or page-turn timer');
    timers.shift().callback();
  }
  return { host, config, requests, requestOptions, toasts, timers, timerDelays, cached, cacheReads, cacheChecks,
    originalRows, touch, runTimers, runNextTimer };
}

function requestedPage(url) { return new URL(url).searchParams.get('page'); }
function pendingRequest(f) {
  let complete;
  f.config.get = () => new Promise(resolve => { complete = resolve; });
  return result => complete(result);
}
async function settle() { for (let i = 0; i < 8; i++) await Promise.resolve(); }

async function settleTimers(f) {
  await settle();
  for (let timerCount = 0; f.timers.length > 0; timerCount++) {
    assert.ok(timerCount < 10, 'Automatic retries must be bounded');
    f.runNextTimer(); await settle();
  }
}

function sequenceResponses(f, results) {
  let next = 0;
  f.config.get = async () => {
    assert.ok(next < results.length, 'Unexpected extra HTTP request');
    return results[next++];
  };
}

function assertFreshReads(f) {
  assert.ok(f.requests.length > 0, 'The exercised reader path must send a request');
  assert.equal(f.requestOptions.length, f.requests.length);
  for (const options of f.requestOptions) assert.equal(options.usingCache, false);
}

test('initial, manual refresh, pull refresh and both page controls bypass a poisoned HTTP cache', async () => {
  const f = fixture();
  const damagedCachedResponse = { success: true, body: '{"data":{"__R":' };
  f.config.get = async (url, extraHeaders, usingCache) => usingCache === false ?
    response('网络第 ' + requestedPage(url) + ' 页正文') : damagedCachedResponse;
  await f.host.loadArticleData(1);
  assert.equal(f.host.currentPage, 1);
  assert.equal(f.host.rowList[0].content, '网络第 1 页正文');
  f.host.refreshArticle(); await settle();
  f.host.pullRefreshArticle(); await settle();
  assert.equal(f.host.currentPage, 1);
  assert.equal(f.host.rowList[0].content, '网络第 1 页正文');
  f.host.changePage(2); await settle();
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.rowList[0].content, '网络第 2 页正文');
  f.host.turnNextPage(); await settle();
  assert.equal(f.host.currentPage, 3);
  assert.equal(f.host.rowList[0].content, '网络第 3 页正文');
  assert.deepEqual(f.requests.map(requestedPage), ['1', '1', '1', '2', '3']);
  assertFreshReads(f);
  assert.equal(f.host.loadError, '');
  assert.equal(f.host.isLoading, false);
  assert.equal(f.host.isRefreshing, false);
  assert.equal(f.host.isTurningPage, false);
});

test('pull refresh requests the visible page and keeps its content while waiting', async () => {
  const f = fixture();
  f.host.requestedPage = 3;
  const complete = pendingRequest(f);
  f.host.pullRefreshArticle();
  assert.equal(f.host.isRefreshing, true);
  assert.equal(f.host.isLoading, true);
  assert.equal(requestedPage(f.requests[0]), '2');
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.rowList, f.originalRows);
  assert.equal(f.host.rawData, '已有响应');
  complete(response()); await settle();
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.rowList[0].content, '刷新后的本地正文');
  assert.equal(f.host.articleRevision, 1);
  assert.equal(f.host.isRefreshing, false);
  assert.equal(f.host.isLoading, false);
});

test('a repeated pending refresh preserves its active indicator and makes no extra request', async () => {
  const f = fixture();
  const complete = pendingRequest(f);
  f.host.pullRefreshArticle();
  f.host.pullRefreshArticle();
  assert.equal(f.requests.length, 1);
  assert.equal(f.host.isRefreshing, true);
  assert.equal(f.host.rowList, f.originalRows);
  complete(response()); await settle();
  assert.equal(f.host.isRefreshing, false);
});

test('failed refresh preserves current content and reports a refresh failure', async () => {
  for (const get of [
    async () => ({ success: false, body: '' }),
    async () => ({ success: true, body: '{"error":{"0":"读取失败"}}' }),
    async () => ({ success: true, body: '{"data":{"__R": @}}' }),
    async () => { throw new Error('local transport failure'); }
  ]) {
    const f = fixture(); f.config.get = get;
    f.host.pullRefreshArticle(); await settle();
    assert.equal(f.host.currentPage, 2);
    assert.equal(f.host.rowList, f.originalRows);
    assert.equal(f.host.rawData, '已有响应');
    assert.equal(f.host.articleRevision, 0);
    assert.equal(f.host.loadError, '');
    assert.equal(f.host.pageTurnFeedback, '');
    assert.equal(f.host.isRefreshing, false);
    assert.equal(f.host.isLoading, false);
    assert.match(f.toasts[0].message, /^刷新失败/);
    f.config.get = async () => response('重新读取后的正文');
    f.host.pullRefreshArticle(); await settle();
    assert.equal(f.requests.length, 2);
    assertFreshReads(f);
    assert.equal(f.host.currentPage, 2);
    assert.equal(f.host.rowList[0].content, '重新读取后的正文');
    assert.equal(f.host.isRefreshing, false);
    assert.equal(f.host.isLoading, false);
  }
});

test('refresh while another operation is loading never starts another request', () => {
  const f = fixture();
  f.host.isLoading = true; f.host.isTurningPage = true;
  f.host.isRefreshing = true; // A Refresh two-way binding can set this first.
  f.host.pullRefreshArticle();
  assert.equal(f.requests.length, 0);
  assert.equal(f.host.isTurningPage, true);
});

test('an unmounted reader cannot refresh or start an automatic turn', () => {
  const f = fixture(); f.host.readerMounted = false;
  f.host.pullRefreshArticle(); f.host.turnNextPage();
  f.host.readerAtEnd = true; f.host.readerScroll(100, ScrollSource.DRAG);
  assert.equal(f.requests.length, 0);
  assert.equal(f.timers.length, 0);
  assert.equal(f.host.isRefreshing, false);
});

test('48 vp of direct drag at the page end schedules exactly one next-page load', async () => {
  const f = fixture(); f.touch(TouchType.Down); f.host.readerAtEnd = true;
  const complete = pendingRequest(f);
  f.host.readerScroll(20, ScrollSource.DRAG);
  f.host.readerScroll(27, ScrollSource.DRAG);
  assert.equal(f.timers.length, 0);
  f.host.readerScroll(1, ScrollSource.DRAG);
  assert.equal(f.requests.length, 0, 'Loading waits for the scroll callback to finish');
  assert.equal(f.timers.length, 1);
  assert.equal(f.timers[0].delay, 0);
  f.host.readerScroll(200, ScrollSource.DRAG);
  assert.equal(f.timers.length, 1);
  f.runTimers();
  assert.equal(f.requests.length, 1);
  assert.equal(requestedPage(f.requests[0]), '3');
  assert.equal(f.host.isTurningPage, true);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.rowList, f.originalRows);
  f.host.readerScroll(300, ScrollSource.DRAG); f.host.turnNextPage();
  assert.equal(f.requests.length, 1);
  complete(response('下一页正文')); await settle();
  assert.equal(f.host.currentPage, 3);
  assert.equal(f.host.rowList[0].content, '下一页正文');
  assert.equal(f.host.isTurningPage, false);
  assert.equal(f.host.readerAtEnd, false);
  assert.equal(f.host.pageTurnDistance, 0);
});

test('ordinary scrolling before the end does not accumulate a page-turn drag', () => {
  const f = fixture(); f.touch(TouchType.Down);
  f.host.readerScroll(300, ScrollSource.DRAG);
  assert.equal(f.host.pageTurnDistance, 0);
  f.host.readerAtEnd = true; f.host.readerScroll(47, ScrollSource.DRAG);
  assert.equal(f.timers.length, 0);
  assert.equal(f.requests.length, 0);
});

test('initial callbacks, fling, spring return and programmatic scrolling do not turn pages', () => {
  for (const source of [ScrollSource.NONE, ScrollSource.FLING, ScrollSource.EDGE_EFFECT,
    ScrollSource.SCROLLER, ScrollSource.SCROLLER_ANIMATION]) {
    const f = fixture(); f.host.readerAtEnd = true;
    f.host.readerScroll(200, source);
    assert.equal(f.host.pageTurnDistance, 0);
    assert.equal(f.timers.length, 0);
    assert.equal(f.requests.length, 0);
  }
});

test('up, cancel and a new touch prevent distance from leaking between gestures', () => {
  for (const ending of [TouchType.Up, TouchType.Cancel]) {
    const f = fixture(); f.touch(TouchType.Down); f.host.readerAtEnd = true;
    f.host.readerScroll(30, ScrollSource.DRAG);
    f.touch(ending);
    assert.equal(f.host.pageTurnDistance, 0);
    f.touch(TouchType.Down); f.host.readerScroll(18, ScrollSource.DRAG);
    assert.equal(f.timers.length, 0);
    f.host.turnGestureConsumed = true; f.touch(TouchType.Down);
    assert.equal(f.host.turnGestureConsumed, false);
    assert.equal(f.host.pageTurnDistance, 0);
  }
});

test('reversing direction clears the edge and accumulated distance', () => {
  const f = fixture(); f.touch(TouchType.Down); f.host.readerAtEnd = true;
  f.host.readerScroll(30, ScrollSource.DRAG);
  f.host.readerScroll(-1, ScrollSource.DRAG);
  assert.equal(f.host.readerAtEnd, false);
  assert.equal(f.host.pageTurnDistance, 0);
  f.host.readerScroll(100, ScrollSource.DRAG);
  assert.equal(f.timers.length, 0);
  f.host.readerAtEnd = true; f.host.readerScroll(48, ScrollSource.DRAG);
  assert.equal(f.timers.length, 1);
});

test('late article growth invalidates a cached end event and its partial page-turn distance', async () => {
  const f = fixture(); f.touch(TouchType.Down); f.host.readerAtEnd = true;
  f.host.readerScroll(47, ScrollSource.DRAG);
  assert.equal(f.host.pageTurnDistance, 47);
  f.config.atEnd = false; // A late image increases the List's content height.
  f.host.readerScroll(1, ScrollSource.DRAG);
  assert.equal(f.host.readerAtEnd, false);
  assert.equal(f.host.pageTurnDistance, 0);
  assert.equal(f.timers.length, 0);
  assert.equal(f.requests.length, 0);
  f.config.atEnd = true;
  f.host.readerScroll(100, ScrollSource.DRAG);
  assert.equal(f.timers.length, 0, 'A fresh onReachEnd is required after content growth');
  f.host.readerAtEnd = true;
  f.host.readerScroll(48, ScrollSource.DRAG);
  f.runTimers(); await settle();
  assert.equal(f.requests.length, 1);
  assert.equal(f.host.currentPage, 3);
});

test('article growth after scheduling a page turn prevents the queued callback from navigating mid-page', () => {
  const f = fixture(); f.touch(TouchType.Down); f.host.readerAtEnd = true;
  f.host.readerScroll(48, ScrollSource.DRAG);
  assert.equal(f.timers.length, 1);
  f.config.atEnd = false;
  f.runTimers();
  assert.equal(f.requests.length, 0);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.readerAtEnd, false);
  assert.equal(f.host.pageTurnDistance, 0);
});

test('busy, refreshing, consumed, empty and last-page readers ignore end drags', () => {
  for (const patch of [{ isLoading: true }, { isRefreshing: true }, { turnGestureConsumed: true },
    { rowList: [] }, { currentPage: 3 }]) {
    const f = fixture(); f.host.readerAtEnd = true; Object.assign(f.host, patch);
    f.host.readerScroll(100, ScrollSource.DRAG);
    assert.equal(f.timers.length, 0);
    assert.equal(f.requests.length, 0);
  }
  const last = fixture(); last.host.currentPage = 3; last.host.turnNextPage();
  assert.equal(last.requests.length, 0);
});

test('a queued page turn is discarded after destruction, another page or another load version', () => {
  for (const change of [f => f.host.aboutToDisappear(), f => { f.host.currentPage = 1; },
    f => { f.host.loadVersion++; }, f => { f.host.isLoading = true; }]) {
    const f = fixture(); f.touch(TouchType.Down); f.host.readerAtEnd = true;
    f.host.readerScroll(48, ScrollSource.DRAG); change(f); f.runTimers();
    assert.equal(f.requests.length, 0);
  }
});

test('a failed next page retains the visible page and can be retried by a new gesture', async () => {
  const f = fixture(); f.config.get = async () => ({ success: false, body: '' });
  f.touch(TouchType.Down); f.host.readerAtEnd = true; f.host.readerScroll(48, ScrollSource.DRAG);
  f.runTimers(); await settle();
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.rowList, f.originalRows);
  assert.equal(f.host.rawData, '已有响应');
  assert.equal(f.host.loadError, '');
  assert.match(f.host.pageTurnFeedback, /第 3 页.*重试/);
  assert.equal(f.host.isLoading, false);
  assert.equal(f.host.isTurningPage, false);
  f.host.readerScroll(100, ScrollSource.DRAG); assert.equal(f.timers.length, 0);
  f.touch(TouchType.Down); f.host.readerScroll(48, ScrollSource.DRAG);
  assert.equal(f.timers.length, 1);
  f.config.get = async () => response('重试成功'); f.runTimers(); await settle();
  assert.equal(f.requests.length, 2);
  assertFreshReads(f);
  assert.equal(f.host.currentPage, 3);
  assert.equal(f.host.pageTurnFeedback, '');
});

test('offline refresh reads the current cached page without a network request', () => {
  const f = fixture(); f.host.isCacheMode = true;
  f.cached.set(TID + ':2', response('缓存正文', 20).body);
  f.host.pullRefreshArticle();
  assert.equal(f.requests.length, 0);
  assert.deepEqual(f.cacheReads, [{ tid: TID, page: 2 }]);
  assert.equal(f.host.rowList[0].content, '缓存正文');
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.totalPages, 3, 'An older cache does not shrink known readable pages');
  assert.equal(f.host.totalRows, 60);
  assert.equal(f.host.isRefreshing, false);
});

test('offline next page reads only an existing cached page and resets the view', () => {
  const f = fixture(); f.host.isCacheMode = true;
  f.cached.set(TID + ':3', response('缓存下一页').body);
  f.touch(TouchType.Down); f.host.readerAtEnd = true; f.host.readerScroll(48, ScrollSource.DRAG);
  f.runTimers();
  assert.equal(f.requests.length, 0);
  assert.deepEqual(f.cacheReads, [{ tid: TID, page: 3 }]);
  assert.equal(f.host.currentPage, 3);
  assert.equal(f.host.rowList[0].content, '缓存下一页');
  assert.equal(f.host.articleRevision, 1);
  assert.equal(f.host.isTurningPage, false);
});

test('a missing offline next page keeps the current page and never falls back to the network', () => {
  const f = fixture(); f.host.isCacheMode = true;
  f.touch(TouchType.Down); f.host.readerAtEnd = true; f.host.readerScroll(48, ScrollSource.DRAG);
  f.runTimers();
  assert.equal(f.requests.length, 0);
  assert.equal(f.cacheReads.length, 0);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.rowList, f.originalRows);
  assert.match(f.host.pageTurnFeedback, /第 3 页尚未缓存/);
  assert.equal(f.host.isLoading, false);
  assert.equal(f.host.isTurningPage, false);
});

test('empty or malformed offline refresh preserves readable content and ends its indicator', () => {
  for (const cachedBody of ['', 'broken local cache']) {
    const f = fixture(); f.host.isCacheMode = true;
    f.cached.set(TID + ':2', cachedBody); f.host.pullRefreshArticle();
    assert.equal(f.requests.length, 0);
    assert.equal(f.host.rowList, f.originalRows);
    assert.equal(f.host.currentPage, 2);
    assert.equal(f.host.loadError, '');
    assert.equal(f.host.isRefreshing, false);
    assert.equal(f.host.isLoading, false);
    assert.equal(f.toasts.length, 1);
  }
});

test('responses and errors arriving after reader destruction have no visible effects', async () => {
  for (const result of [response('迟到正文'), { success: false, body: '' }]) {
    const f = fixture(); const complete = pendingRequest(f);
    f.host.pullRefreshArticle(); f.host.aboutToDisappear();
    complete(result); await settle();
    assert.equal(f.host.readerMounted, false);
    assert.equal(f.host.rowList, f.originalRows);
    assert.equal(f.host.currentPage, 2);
    assert.equal(f.host.articleRevision, 0);
    assert.equal(f.toasts.length, 0);
    assert.equal(f.host.loadError, '');
    assert.equal(f.host.isRefreshing, false);
    assert.equal(f.host.isLoading, false);
  }
  const f = fixture(); let fail;
  f.config.get = () => new Promise((resolve, reject) => { fail = reject; });
  f.host.pullRefreshArticle(); f.host.aboutToDisappear(); fail(new Error('late local error'));
  await settle(); assert.equal(f.toasts.length, 0); assert.equal(f.host.rowList, f.originalRows);
});

test('a stale response cannot override a newer load or release its pending state', async () => {
  const f = fixture(); const finishFirst = pendingRequest(f);
  const first = f.host.loadArticleData(1, true);
  f.host.loadVersion++; f.host.isLoading = false;
  const finishSecond = pendingRequest(f);
  const second = f.host.loadArticleData(3, true);
  finishFirst(response('旧请求正文')); await first;
  assert.equal(f.host.rowList, f.originalRows);
  assert.equal(f.host.isLoading, true);
  finishSecond(response('新请求正文')); await second;
  assert.equal(f.host.currentPage, 3);
  assert.equal(f.host.rowList[0].content, '新请求正文');
  assert.equal(f.host.isLoading, false);
});

test('initial transport, API and parse failures retry the target page with a fresh request', async () => {
  for (const rejected of [
    { success: false, body: '' },
    { success: true, body: '{"error":{"0":"读取失败"}}' },
    { success: true, body: '{"data":{"__R": @}}' }
  ]) {
    const f = fixture(); f.host.rowList = []; f.host.rawData = '';
    f.config.get = async () => rejected;
    await f.host.loadArticleData(3);
    assert.equal(f.host.currentPage, 2);
    assert.equal(f.host.requestedPage, 3);
    assert.ok(f.host.loadError.length > 0);
    assert.equal(f.host.rowList.length, 0);
    assert.equal(f.host.rawData, '');
    assert.equal(f.host.isLoading, false);
    f.config.get = async () => response('第 3 页重试正文');
    f.host.refreshArticle(); await settle();
    assert.deepEqual(f.requests.map(requestedPage), ['3', '3']);
    assertFreshReads(f);
    assert.equal(f.host.currentPage, 3);
    assert.equal(f.host.rowList[0].content, '第 3 页重试正文');
    assert.equal(f.host.loadError, '');
    assert.equal(f.host.isLoading, false);
  }
});

test('an incomplete initial response is recovered by one fresh request after 300 ms', async () => {
  const f = fixture();
  sequenceResponses(f, [incompleteResponse(), response('首轮补请求正文')]);
  const loading = f.host.loadArticleData(1);
  await settle();
  assert.equal(f.requests.length, 1);
  assert.equal(f.host.isLoading, true);
  assert.equal(f.host.rowList, f.originalRows);
  assert.equal(f.host.rawData, '已有响应');
  assert.equal(f.host.articleRevision, 0);
  assert.equal(f.host.loadError, '');
  assert.deepEqual(f.timers.map(timer => timer.delay), [300]);
  await f.host.loadArticleData(3);
  assert.equal(f.requests.length, 1, 'The loading lock covers the retry backoff');
  await settleTimers(f); await loading;
  assert.equal(f.requests.length, 2);
  assert.equal(f.requests[0], f.requests[1], 'A retry must read the same topic and page');
  assert.deepEqual(f.timerDelays, [300]);
  assertFreshReads(f);
  assert.equal(f.host.currentPage, 1);
  assert.equal(f.host.rowList[0].content, '首轮补请求正文');
  assert.equal(f.host.rawData, response('首轮补请求正文').body);
  assert.equal(f.host.articleRevision, 1);
  assert.equal(f.host.isLoading, false);
  assert.equal(f.host.loadError, '');
});

test('two incomplete responses are recovered by a second fresh request after 900 ms', async () => {
  const f = fixture();
  sequenceResponses(f, [incompleteResponse(), incompleteResponse(), response('第二轮补请求正文')]);
  const loading = f.host.loadArticleData(3, true);
  await settle(); f.runNextTimer(); await settle();
  assert.equal(f.requests.length, 2);
  assert.equal(f.host.isLoading, true);
  assert.equal(f.host.rowList, f.originalRows);
  assert.equal(f.host.currentPage, 2);
  assert.deepEqual(f.timers.map(timer => timer.delay), [900]);
  f.runNextTimer(); await loading;
  assert.equal(f.requests.length, 3);
  assert.equal(new Set(f.requests).size, 1);
  assert.deepEqual(f.timerDelays, [300, 900]);
  assertFreshReads(f);
  assert.equal(f.host.currentPage, 3);
  assert.equal(f.host.rowList[0].content, '第二轮补请求正文');
  assert.equal(f.host.articleRevision, 1);
  assert.equal(f.host.isLoading, false);
  assert.equal(f.host.pageTurnFeedback, '');
});

test('a persistently incomplete response stops after three requests and releases the loading lock', async () => {
  const f = fixture(); f.host.rowList = []; f.host.rawData = '';
  f.config.get = async () => incompleteResponse();
  const loading = f.host.loadArticleData(3);
  await settleTimers(f); await loading;
  assert.equal(f.requests.length, 3);
  assert.equal(new Set(f.requests).size, 1);
  assert.deepEqual(f.timerDelays, [300, 900]);
  assertFreshReads(f);
  assert.equal(f.timers.length, 0);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.requestedPage, 3);
  assert.equal(f.host.rowList.length, 0);
  assert.equal(f.host.rawData, '');
  assert.equal(f.host.articleRevision, 0);
  assert.match(f.host.loadError, /不完整/);
  assert.equal(f.host.isLoading, false);
  assert.equal(f.host.isRefreshing, false);
  assert.equal(f.host.isTurningPage, false);
  assert.equal(f.toasts.length, 0);
  assert.equal(f.host.webFallbackAvailable, true);
  assert.equal(f.host.webFallbackTargetPage, 3);
  assert.equal(f.host.webFallbackPage, 3);
});

test('complete permission errors and illegal JSON never trigger automatic GET retries', async () => {
  for (const rejected of [
    { success: true, body: '{"error":{"0":"权限不足"}}' },
    { success: true, body: '{"data":{"__R": @}}' },
    { success: true, body: '{"data":{"__R":[],"x":true,,"y":0}}' },
    { success: true, body: '{"data":{"__T":{"tid":1}}}' },
    { success: false, body: incompleteResponse().body }
  ]) {
    const f = fixture(); f.config.get = async () => rejected;
    await f.host.loadArticleData(1);
    assert.equal(f.requests.length, 1);
    assert.equal(f.timers.length, 0);
    assert.equal(f.host.rowList, f.originalRows);
    assert.equal(f.host.articleRevision, 0);
    assert.ok(f.host.loadError.length > 0);
    assert.equal(f.host.isLoading, false);
    assert.equal(f.host.webFallbackAvailable, false);
    assert.equal(f.host.webFallbackPage, 0);
    assertFreshReads(f);
  }
});

test('a retry stops immediately when the new response has a transport, permission or ordinary syntax failure', async () => {
  for (const rejected of [
    { success: false, body: '' },
    { success: true, body: '{"error":{"0":"权限不足"}}' },
    { success: true, body: '{"data":{"__R": @}}' }
  ]) {
    const f = fixture(); sequenceResponses(f, [incompleteResponse(), rejected]);
    const loading = f.host.loadArticleData(1);
    await settleTimers(f); await loading;
    assert.equal(f.requests.length, 2);
    assert.deepEqual(f.timerDelays, [300]);
    assert.equal(f.timers.length, 0);
    assert.equal(f.host.articleRevision, 0);
    assert.ok(f.host.loadError.length > 0);
    assert.equal(f.host.isLoading, false);
    assert.equal(f.host.webFallbackAvailable, false);
    assert.equal(f.host.webFallbackPage, 0);
    assertFreshReads(f);
  }
});

test('leaving the reader during either backoff cancels the next retry', async () => {
  for (const leavingDelay of [300, 900]) {
    const f = fixture(); f.config.get = async () => incompleteResponse();
    const loading = f.host.loadArticleData(1, true);
    await settle();
    if (leavingDelay === 900) { f.runNextTimer(); await settle(); }
    assert.equal(f.timers[0].delay, leavingDelay);
    const startedRequests = f.requests.length;
    f.host.aboutToDisappear();
    f.runNextTimer(); await loading;
    assert.equal(f.requests.length, startedRequests);
    assert.equal(f.timers.length, 0);
    assert.equal(f.host.readerMounted, false);
    assert.equal(f.host.rowList, f.originalRows);
    assert.equal(f.host.rawData, '已有响应');
    assert.equal(f.host.articleRevision, 0);
    assert.equal(f.host.loadError, '');
    assert.equal(f.toasts.length, 0);
    assert.equal(f.host.isLoading, false);
    assert.equal(f.host.webFallbackAvailable, false);
    assert.equal(f.host.webFallbackPage, 0);
  }
});

test('a newer load version during backoff prevents another GET and keeps the newer pending state', async () => {
  const f = fixture(); f.config.get = async () => incompleteResponse();
  const first = f.host.loadArticleData(1, true);
  await settle();
  f.host.loadVersion++; f.host.isLoading = false;
  const finishSecond = pendingRequest(f);
  const second = f.host.loadArticleData(3, true);
  f.runNextTimer(); await first;
  assert.equal(f.requests.length, 2, 'Only the original and the newer user request have started');
  assert.equal(f.host.isLoading, true);
  assert.equal(f.host.rowList, f.originalRows);
  assert.equal(f.toasts.length, 0);
  assert.equal(f.host.webFallbackAvailable, false);
  assert.equal(f.host.webFallbackPage, 0);
  finishSecond(response('较新的阅读请求')); await second;
  assert.equal(f.host.currentPage, 3);
  assert.equal(f.host.rowList[0].content, '较新的阅读请求');
  assert.equal(f.host.isLoading, false);
});

test('an in-flight retry cannot overwrite a newer response or release its loading state', async () => {
  const f = fixture(); f.config.get = async () => incompleteResponse();
  const first = f.host.loadArticleData(1, true);
  await settle();
  const finishRetry = pendingRequest(f);
  f.runNextTimer(); await settle();
  assert.equal(f.requests.length, 2);
  f.host.loadVersion++; f.host.isLoading = false;
  const finishNewer = pendingRequest(f);
  const newer = f.host.loadArticleData(3, true);
  finishRetry(response('过期的补请求正文')); await first;
  assert.equal(f.host.isLoading, true);
  assert.equal(f.host.rowList, f.originalRows);
  assert.equal(f.host.articleRevision, 0);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.toasts.length, 0);
  assert.equal(f.timers.length, 0);
  assert.equal(f.host.webFallbackAvailable, false);
  assert.equal(f.host.webFallbackPage, 0);
  finishNewer(response('新页正文')); await newer;
  assert.equal(f.requests.length, 3);
  assert.equal(f.host.currentPage, 3);
  assert.equal(f.host.rowList[0].content, '新页正文');
  assert.equal(f.host.articleRevision, 1);
  assert.equal(f.host.isLoading, false);
  assertFreshReads(f);
});

test('an in-flight retry arriving after destruction neither submits content nor retries again', async () => {
  for (const lateResponse of [response('退出后的正文'), incompleteResponse()]) {
    const f = fixture(); f.config.get = async () => incompleteResponse();
    const loading = f.host.loadArticleData(1, true);
    await settle();
    const finishRetry = pendingRequest(f);
    f.runNextTimer(); await settle();
    f.host.aboutToDisappear();
    finishRetry(lateResponse); await loading;
    assert.equal(f.requests.length, 2);
    assert.equal(f.timers.length, 0);
    assert.equal(f.host.readerMounted, false);
    assert.equal(f.host.rowList, f.originalRows);
    assert.equal(f.host.rawData, '已有响应');
    assert.equal(f.host.articleRevision, 0);
    assert.equal(f.host.loadError, '');
    assert.equal(f.toasts.length, 0);
    assert.equal(f.host.isLoading, false);
    assert.equal(f.host.webFallbackAvailable, false);
    assert.equal(f.host.webFallbackPage, 0);
  }
});

test('an exhausted incomplete refresh retains the visible page and can immediately refresh again', async () => {
  const f = fixture(); f.config.get = async () => incompleteResponse();
  f.host.pullRefreshArticle();
  await settle();
  assert.equal(f.host.isRefreshing, true);
  assert.equal(f.host.isLoading, true);
  assert.equal(f.host.rowList, f.originalRows);
  await settleTimers(f);
  assert.equal(f.requests.length, 3);
  assert.deepEqual(f.requests.map(requestedPage), ['2', '2', '2']);
  assert.deepEqual(f.timerDelays, [300, 900]);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.rowList, f.originalRows);
  assert.equal(f.host.rawData, '已有响应');
  assert.equal(f.host.articleRevision, 0);
  assert.equal(f.host.loadError, '');
  assert.equal(f.host.pageTurnFeedback, '');
  assert.equal(f.host.isLoading, false);
  assert.equal(f.host.isRefreshing, false);
  assert.equal(f.toasts.length, 1);
  assert.equal(f.host.webFallbackAvailable, true);
  assert.equal(f.host.webFallbackTargetPage, 2);
  assert.equal(f.host.webFallbackPage, 0, 'A failed refresh keeps the native content visible');
  assert.match(f.toasts[0].message, /^刷新失败.*不完整/);
  f.config.get = async () => response('恢复后的刷新正文');
  f.host.pullRefreshArticle(); await settle();
  assert.equal(f.requests.length, 4);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.rowList[0].content, '恢复后的刷新正文');
  assert.equal(f.host.articleRevision, 1);
  assert.equal(f.host.isLoading, false);
  assert.equal(f.host.isRefreshing, false);
  assert.equal(f.host.webFallbackAvailable, false);
  assert.equal(f.host.webFallbackPage, 0);
  assertFreshReads(f);
});

test('a manual page change falls back to the requested page while keeping the last successful native page', async () => {
  const f = fixture(); f.config.get = async () => incompleteResponse();
  f.host.showPageSheet = true;
  f.host.changePage(3);
  await settleTimers(f);
  assert.equal(f.requests.length, 3);
  assert.deepEqual(f.requests.map(requestedPage), ['3', '3', '3']);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.rowList, f.originalRows);
  assert.equal(f.host.rawData, '已有响应');
  assert.equal(f.host.webFallbackTargetPage, 3);
  assert.equal(f.host.webFallbackPage, 3);
  assert.equal(f.host.webFallbackAvailable, true);
  assert.equal(f.host.showPageSheet, false);
  assert.equal(f.host.isLoading, false);
});

test('an exhausted automatic page turn retains the native page and offers the next page explicitly', async () => {
  const f = fixture(); f.config.get = async () => incompleteResponse();
  f.host.turnNextPage();
  await settleTimers(f);
  assert.equal(f.requests.length, 3);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.rowList, f.originalRows);
  assert.equal(f.host.rawData, '已有响应');
  assert.equal(f.host.articleRevision, 0);
  assert.equal(f.host.loadError, '');
  assert.match(f.host.pageTurnFeedback, /第 3 页.*不完整/);
  assert.equal(f.host.webFallbackAvailable, true);
  assert.equal(f.host.webFallbackTargetPage, 3);
  assert.equal(f.host.webFallbackPage, 0);
  assert.equal(f.host.isTurningPage, false);
  assert.equal(f.toasts.length, 0);
  f.host.showPageSheet = true;
  f.host.openWebFallback();
  assert.equal(f.host.webFallbackPage, 3, 'The explicit entry reads the failed next page');
  assert.equal(f.host.showPageSheet, false);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.requests.length, 3, 'Opening the web component does not issue another API request');
});

test('an exhausted refresh offers the same page explicitly and native retry clears fallback state on success', async () => {
  const f = fixture(); f.config.get = async () => incompleteResponse();
  f.host.pullRefreshArticle(); await settleTimers(f);
  assert.equal(f.host.webFallbackAvailable, true);
  assert.equal(f.host.webFallbackPage, 0);
  f.host.openWebFallback();
  assert.equal(f.host.webFallbackPage, 2);
  const finishNative = pendingRequest(f);
  f.host.retryNativeReading(); await settle();
  assert.equal(f.requests.length, 4);
  assert.equal(requestedPage(f.requests[3]), '2');
  assert.equal(f.host.webFallbackPage, 0);
  assert.equal(f.host.webFallbackAvailable, false);
  assert.equal(f.host.isLoading, true);
  f.host.retryNativeReading(); await settle();
  assert.equal(f.requests.length, 4, 'The loading lock also guards the return-to-native action');
  finishNative(response('恢复后的同页正文')); await settle();
  assert.equal(f.host.rowList[0].content, '恢复后的同页正文');
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.webFallbackPage, 0);
  assert.equal(f.host.webFallbackAvailable, false);
  assert.equal(f.host.loadError, '');
  assert.equal(f.host.pageTurnFeedback, '');
  assert.equal(f.host.isLoading, false);
  assertFreshReads(f);
});

test('returning to native reading retries the web target instead of the old native page', async () => {
  const f = fixture(); f.config.get = async () => incompleteResponse();
  const initial = f.host.loadArticleData(3); await settleTimers(f); await initial;
  assert.equal(f.host.webFallbackPage, 3);
  f.config.get = async () => response('第三页原生正文');
  f.host.retryNativeReading(); await settle();
  assert.equal(f.requests.length, 4);
  assert.equal(requestedPage(f.requests[3]), '3');
  assert.equal(f.host.currentPage, 3);
  assert.equal(f.host.rowList[0].content, '第三页原生正文');
  assert.equal(f.host.webFallbackPage, 0);
  assert.equal(f.host.webFallbackAvailable, false);
});

test('a native retry that is still incomplete reopens the same bounded web fallback', async () => {
  const f = fixture(); f.config.get = async () => incompleteResponse();
  const initial = f.host.loadArticleData(3); await settleTimers(f); await initial;
  f.host.retryNativeReading(); await settleTimers(f);
  assert.equal(f.requests.length, 6);
  assert.deepEqual(f.requests.map(requestedPage), Array(6).fill('3'));
  assert.deepEqual(f.timerDelays, [300, 900, 300, 900]);
  assert.equal(f.host.webFallbackPage, 3);
  assert.equal(f.host.webFallbackTargetPage, 3);
  assert.equal(f.host.webFallbackAvailable, true);
  assert.equal(f.host.isLoading, false);
  assert.equal(f.host.rowList, f.originalRows);
});

test('an ordinary native retry failure cannot reuse an earlier incomplete-response web entry', async () => {
  const f = fixture(); f.config.get = async () => incompleteResponse();
  const initial = f.host.loadArticleData(3); await settleTimers(f); await initial;
  f.config.get = async () => ({ success: true, body: '{"error":{"0":"权限不足"}}' });
  f.host.retryNativeReading(); await settle();
  assert.equal(f.requests.length, 4);
  assert.equal(f.host.webFallbackAvailable, false);
  assert.equal(f.host.webFallbackPage, 0);
  assert.match(f.host.loadError, /权限不足/);
  f.host.openWebFallback();
  assert.equal(f.host.webFallbackPage, 0);
  assert.equal(f.requests.length, 4);
});

test('offline or unavailable web entries never switch away from native reading', () => {
  for (const state of [{ isCacheMode: true, webFallbackAvailable: true },
    { isCacheMode: false, webFallbackAvailable: false }]) {
    const f = fixture(); Object.assign(f.host, state, { webFallbackTargetPage: 3, showPageSheet: true });
    f.host.openWebFallback();
    assert.equal(f.host.webFallbackPage, 0);
    assert.equal(f.host.showPageSheet, true);
    assert.equal(f.requests.length, 0);
  }
});

test('unmounted or invalid-page web entries cannot activate the fallback', () => {
  for (const state of [{ readerMounted: false },
    ...[0, -1, 1.5, NaN, Infinity].map(webFallbackTargetPage => ({ webFallbackTargetPage }))]) {
    const f = fixture();
    Object.assign(f.host, { webFallbackAvailable: true, webFallbackTargetPage: 3,
      showPageSheet: true }, state);
    f.host.openWebFallback();
    assert.equal(f.host.webFallbackPage, 0);
    assert.equal(f.host.showPageSheet, true);
    assert.equal(f.requests.length, 0);
  }
});

test('inactive, offline, unmounted or invalid-page native retries issue no API request', async () => {
  for (const state of [{ readerMounted: false }, { isCacheMode: true },
    ...[0, -1, 1.5, NaN, Infinity].map(webFallbackPage => ({ webFallbackPage }))]) {
    const f = fixture();
    Object.assign(f.host, { webFallbackPage: 3, webFallbackAvailable: true }, state);
    const priorPage = f.host.webFallbackPage;
    f.host.retryNativeReading(); await settle();
    assert.equal(f.requests.length, 0);
    assert.equal(f.host.webFallbackPage, priorPage);
    assert.equal(f.host.webFallbackAvailable, true);
    assert.equal(f.host.isLoading, false);
  }
});

test('returning from web pagination requests the last successfully displayed web page', async () => {
  const f = fixture();
  Object.assign(f.host, { webFallbackPage: 1, webFallbackAvailable: true });
  f.host.retryNativeReading(3); await settle();
  assert.deepEqual(f.requests.map(requestedPage), ['3']);
  assert.equal(f.host.currentPage, 3);
  assert.equal(f.host.webFallbackPage, 0);
  assert.equal(f.host.webFallbackAvailable, false);
});

test('invalid pages supplied by a stale web callback issue no native request', async () => {
  for (const page of [0, -1, 1.5, NaN, Infinity]) {
    const f = fixture(); f.host.webFallbackPage = 1;
    f.host.retryNativeReading(page); await settle();
    assert.equal(f.requests.length, 0);
    assert.equal(f.host.webFallbackPage, 1);
  }
});

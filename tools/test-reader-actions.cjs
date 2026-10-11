'use strict';

/* Run: node --test tools/test-reader-actions.cjs
 * Execute actual page methods and models through the DevEco ETS compiler.
 * HTTP, cache storage and navigation stay local;
 * this test never reads accounts, sends forum requests or operates a device.
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
const parserOptions = { ets: { components: Object.keys(componentMap.COMPONENT_MAP).concat(['ArticleBody']) } };

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
const pageAst = ts.createSourceFile(pagePath, pageSource, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, parserOptions);
assert.deepEqual(pageAst.parseDiagnostics.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
const component = pageAst.statements.find(node => node.name && node.name.getText(pageAst) === 'ArticleListPage');
assert.ok(component, 'Actual ArticleListPage component');
const pageMethods = new Map(component.members.filter(ts.isMethodDeclaration)
  .map(method => [method.name.getText(pageAst), method]));
const constants = pageAst.statements.filter(ts.isVariableStatement)
  .map(node => node.getText(pageAst)).join('\n');

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
    '\n}\nglobalThis.RealPage = RealPage;', 'ReaderMethods.ts'), context);
  return new context.RealPage();
}

const TID = 47664817;
function fixture(methods) {
  const requests = [], cacheWrites = [], cacheChecks = [], routes = [], toasts = [], timers = [];
  const cachePages = new Set();
  const config = {
    loggedIn: true, cacheSucceeds: true,
    post: async () => ({ success: true, body: '{"data":{"0":"操作成功"}}' })
  };
  const host = realMethods(methods, {
    NgaJsonParser, UrlBuilder,
    LoginStore: { hasUser: () => config.loggedIn },
    HttpClient: { post: (url, fields, authenticated) => {
      requests.push({ url, fields: { ...fields }, authenticated });
      return config.post();
    } },
    ArticleCacheStore: {
      hasCachePage: (tid, page) => {
        cacheChecks.push({ tid, page });
        return cachePages.has(tid + ':' + page);
      },
      cachePage: (tid, page, rawData, topicInfoJson) => {
        cacheWrites.push({ tid, page, rawData, topicInfo: JSON.parse(topicInfoJson) });
        if (config.cacheSucceeds) cachePages.add(tid + ':' + page);
        return config.cacheSucceeds;
      }
    },
    setTimeout: (callback, delay) => { timers.push({ callback, delay }); },
    console: { info() {}, warn() {}, error() {} }
  });
  Object.assign(host, {
    tid: TID, fid: -7, title: '本地测试话题', currentPage: 1, requestedPage: 1,
    totalPages: 1, totalRows: 1, isLoading: false, isCacheMode: false,
    rowList: [], rawData: '', attachmentBase: '', articleRevision: 0, loadError: '',
    isFavorited: false, isPerformingAction: false, actionMsg: '', cacheMsg: '', currentPageCached: false,
    getUIContext: () => ({
      getRouter: () => ({ pushUrl: route => { routes.push(JSON.parse(JSON.stringify(route))); return Promise.resolve(); } }),
      getPromptAction: () => ({ showToast: toast => { toasts.push({ ...toast }); } })
    })
  });
  return { host, config, requests, cacheWrites, cacheChecks, cachePages, routes, toasts, timers };
}

function wrappedResult(message) {
  return '/*$js$*/window.script_muti_get_var_store=' + JSON.stringify({ data: { '0': message } }) + ';/*$js$*/';
}

test('favorite add and delete use actual URLs, authenticated fields and wrapped success responses', async () => {
  const f = fixture(['toggleFavorite']);
  f.config.post = async () => ({ success: true, body: wrappedResult('操作成功') });
  await f.host.toggleFavorite();
  assert.equal(f.host.isFavorited, true);
  assert.deepEqual(f.requests[0], {
    url: 'https://forum.invalid/nuke.php?__lib=topic_favor&lite=js&noprefix&__act=topic_favor&action=add&tid=' + TID,
    fields: {}, authenticated: true
  });
  await f.host.toggleFavorite();
  assert.equal(f.host.isFavorited, false);
  assert.deepEqual(f.requests[1], {
    url: 'https://forum.invalid/nuke.php', authenticated: true,
    fields: { __lib: 'topic_favor', __act: 'topic_favor', __output: '8', action: 'del', page: '1', tidarray: String(TID) }
  });
  assert.equal(f.host.isPerformingAction, false);
  assert.equal(f.toasts.length, 2);
});

test('already-favorited response confirms add without another state toggle', async () => {
  const f = fixture(['toggleFavorite']);
  f.config.post = async () => ({ success: true, body: wrappedResult('该话题已经收藏') });
  await f.host.toggleFavorite();
  assert.equal(f.host.isFavorited, true);
  assert.equal(f.requests.length, 1);
});

test('HTTP success with business errors or unknown responses never changes favorite state', async () => {
  const bodies = [
    '{"error":{"0":"请先登录"}}',
    '{"data":{"__MESSAGE":{"0":1,"1":"收藏失败"}}}',
    wrappedResult('收藏未成功'), wrappedResult('收藏成功但发生错误'),
    '{}', 'not-json', '<html>login required</html>'
  ];
  for (const isFavorited of [false, true]) {
    for (const body of bodies) {
      const f = fixture(['toggleFavorite']);
      f.host.isFavorited = isFavorited;
      f.config.post = async () => ({ success: true, body });
      await f.host.toggleFavorite();
      assert.equal(f.host.isFavorited, isFavorited, body);
      assert.equal(f.host.isPerformingAction, false);
      assert.ok(f.host.actionMsg.length > 0);
      assert.equal(f.toasts.length, 1);
    }
  }
});

test('transport failure cannot confirm a favorite even if its body claims success', async () => {
  const f = fixture(['toggleFavorite']);
  f.config.post = async () => ({ success: false, body: wrappedResult('操作成功') });
  await f.host.toggleFavorite();
  assert.equal(f.host.isFavorited, false);
  assert.equal(f.host.isPerformingAction, false);
});

test('anonymous, loading, busy and invalid-topic favorite actions never send requests', async () => {
  const anonymous = fixture(['toggleFavorite']);
  anonymous.config.loggedIn = false;
  await anonymous.host.toggleFavorite();
  assert.equal(anonymous.requests.length, 0);
  assert.equal(anonymous.host.isPerformingAction, false);
  assert.equal(anonymous.toasts.length, 1);
  for (const patch of [{ isLoading: true }, { isPerformingAction: true }, { tid: 0 }, { tid: -1 }]) {
    const f = fixture(['toggleFavorite']);
    Object.assign(f.host, patch);
    await f.host.toggleFavorite();
    assert.equal(f.requests.length, 0);
    assert.equal(f.toasts.length, 0);
  }
});

test('favorite exceptions release the action lock and allow retry', async () => {
  const f = fixture(['toggleFavorite']);
  f.config.post = async () => { throw new Error('local transport failure'); };
  await f.host.toggleFavorite();
  assert.equal(f.host.isFavorited, false);
  assert.equal(f.host.isPerformingAction, false);
  f.config.post = async () => ({ success: true, body: wrappedResult('收藏成功') });
  await f.host.toggleFavorite();
  assert.equal(f.requests.length, 2);
  assert.equal(f.host.isFavorited, true);
});

test('favorite pending requests cannot be duplicated and capture their original action', async () => {
  const f = fixture(['toggleFavorite']);
  let resolve;
  f.config.post = () => new Promise(done => { resolve = done; });
  const pending = f.host.toggleFavorite();
  assert.equal(f.host.isPerformingAction, true);
  await f.host.toggleFavorite();
  assert.equal(f.requests.length, 1);
  resolve({ success: true, body: wrappedResult('收藏成功') });
  await pending;
  assert.equal(f.host.isFavorited, true);
  assert.equal(f.host.isPerformingAction, false);
});

test('successful article loading refreshes cache status for the committed page only', () => {
  const f = fixture(['applyArticleData']);
  const parsed = NgaJsonParser.parseThreadData(JSON.stringify({ data: {
    __T: { tid: TID, subject: '实际解析的标题' }, __ROWS: 60,
    __R: [{ tid: TID, pid: 0, lou: 0, content: '本地正文' }]
  } }));
  assert.equal(parsed.success, true, parsed.error);
  f.cachePages.add(TID + ':2');
  f.host.applyArticleData(parsed, 'second-page-response', 2);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.currentPageCached, true);
  assert.deepEqual(f.cacheChecks.at(-1), { tid: TID, page: 2 });
  f.host.applyArticleData(parsed, 'third-page-response', 3);
  assert.equal(f.host.currentPage, 3);
  assert.equal(f.host.currentPageCached, false);
  assert.equal(f.host.rawData, 'third-page-response');
});

test('caching writes the visible page and topic metadata, then marks it saved and reports immediately', () => {
  const f = fixture(['cacheCurrentPage']);
  Object.assign(f.host, {
    currentPage: 3, totalRows: 65, rawData: 'actual-page-response',
    rowList: [{ author: '本地作者', authorId: 123 }]
  });
  f.host.cacheCurrentPage();
  assert.deepEqual(f.cacheWrites, [{
    tid: TID, page: 3, rawData: 'actual-page-response',
    topicInfo: { tid: TID, subject: '本地测试话题', author: '本地作者', authorid: 123, replies: 65, page: 3 }
  }]);
  assert.equal(f.host.currentPageCached, true);
  assert.equal(f.toasts.length, 1);
  assert.equal(f.toasts[0].message, f.host.cacheMsg);
  assert.equal(f.timers.length, 1);
  assert.equal(f.timers[0].delay, 2000);
  f.timers[0].callback();
  assert.equal(f.host.cacheMsg, '');
});

test('cache storage failures preserve saved status and report failure instead of marking saved', () => {
  for (const wasCached of [false, true]) {
    const f = fixture(['cacheCurrentPage']);
    f.host.rawData = 'local response';
    f.host.currentPageCached = wasCached;
    f.config.cacheSucceeds = false;
    f.host.cacheCurrentPage();
    assert.equal(f.cacheWrites.length, 1);
    assert.equal(f.host.currentPageCached, wasCached);
    assert.match(f.toasts[0].message, /失败/);
  }
});

test('loading, offline and empty-data cache actions never write or show a false success', () => {
  for (const patch of [{ isLoading: true }, { isCacheMode: true }, { rawData: '' }]) {
    const f = fixture(['cacheCurrentPage']);
    f.host.rawData = 'last successful page';
    Object.assign(f.host, patch);
    f.host.cacheCurrentPage();
    assert.equal(f.cacheWrites.length, 0);
    assert.equal(f.host.currentPageCached, false);
    assert.equal(f.toasts.length, 0);
    assert.equal(f.timers.length, 0);
  }
});

test('reply navigation preserves topic, board and title without a floor target', () => {
  const f = fixture(['goToReply']);
  f.host.goToReply();
  assert.deepEqual(f.routes, [{
    url: 'pages/ReplyPage', params: { action: 'reply', tid: TID, fid: -7, title: '本地测试话题' }
  }]);
});

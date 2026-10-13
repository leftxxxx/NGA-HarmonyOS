'use strict';

/* Execute the actual board-list methods with the DevEco ETS compiler.
 * Native HTTP/cache and account/publication state are local fixtures.
 * This test does not access account storage, the network, or a device.
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

const pagePath = path.join(root, 'entry/src/main/ets/pages/TopicListPage.ets');
const pageSource = fs.readFileSync(pagePath, 'utf8');
const pageAst = ts.createSourceFile(pagePath, pageSource, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS,
  { ets: { components: Object.keys(componentMap.COMPONENT_MAP) } });
assert.deepEqual(pageAst.parseDiagnostics.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
const component = pageAst.statements.find(node => node.name && node.name.getText(pageAst) === 'TopicListPage');
assert.ok(component, 'Actual TopicListPage component');
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
    '\n}\nglobalThis.RealPage = RealPage;', 'TopicListRefreshMethods.ts'), context);
  return new context.RealPage();
}

function row(tid, subject = '本地话题 ' + tid) {
  return { tid, subject, author: '测试作者', authorid: 10, replies: 3, lastposter: '测试回复者', postdate: 1700000000 };
}
function response(rows) {
  return { success: true, body: JSON.stringify({ data: { __F: { name: '本地板块' }, __T: rows } }) };
}
const ids = host => Array.from(host.threadList, thread => thread.tid);
const requestedPage = url => Number(new URL(url).searchParams.get('page'));

function fixture() {
  const requests = [];
  const config = { account: 'account-a', revision: 0, get: async () => response([row(201)]) };
  const host = realMethods(['loadTopicList', 'onRefresh', 'onLoadMore', 'refreshPublishedTopics',
    'isBoardRecommendation', 'recommendedThreads', 'latestThreads'], {
    NgaJsonParser, UrlBuilder,
    HttpClient: { get: (url, extraHeaders, usingCache) => {
      requests.push({ url, extraHeaders, usingCache });
      return config.get(url, extraHeaders, usingCache);
    } },
    LoginStore: { getUser: () => ({ uid: config.account }) },
    TopicPostStore: { getRevision: () => config.revision }
  });
  const originalRows = [row(101, '原来的首条'), row(102, '原来的第二条')];
  Object.assign(host, {
    fid: -7, stid: 0, threadList: originalRows,
    currentPage: 1, hasMore: true,
    isLoading: false, isRefreshing: false, isLoadingMore: false,
    loadError: '', loadMoreError: '', refreshFeedback: '',
    publishAccountKey: config.account, publishRevision: config.revision
  });
  return { host, config, requests, originalRows };
}

async function settle() { for (let index = 0; index < 12; index++) await Promise.resolve(); }
function pendingRequest(f) {
  let resolve;
  f.config.get = () => new Promise(complete => { resolve = complete; });
  return result => { assert.ok(resolve, 'Expected an in-flight request'); resolve(result); };
}
function assertFreshReads(f) {
  assert.ok(f.requests.length > 0, 'Exercised board-list path must request data');
  for (const request of f.requests) assert.equal(request.usingCache, false,
    'Online board-list reads must bypass the native HTTP cache');
}
function assertIdle(host) {
  assert.equal(host.isLoading, false);
  assert.equal(host.isLoadingMore, false);
  assert.equal(host.isRefreshing, false);
}

test('initial load and pull refresh bypass stale native cache and replace the old first topic', async () => {
  const f = fixture();
  let freshRows = [row(201, '最新首条'), row(202)];
  const stale = response(f.originalRows);
  f.config.get = async (url, extraHeaders, usingCache) => usingCache === false ? response(freshRows) : stale;
  await f.host.loadTopicList(1);
  assert.deepEqual(ids(f.host), [201, 202]);
  assert.equal(f.host.threadList[0].subject, '最新首条');
  f.host.currentPage = 4;
  freshRows = [row(301, '刷新后的首条'), row(302)];
  f.host.onRefresh();
  await settle();
  assert.deepEqual(ids(f.host), [301, 302]);
  assert.equal(f.host.threadList[0].subject, '刷新后的首条');
  assert.equal(f.host.currentPage, 1);
  assert.equal(f.requests.length, 2);
  assert.ok(f.requests.every(request => requestedPage(request.url) === 1));
  assertFreshReads(f);
  assertIdle(f.host);
});

test('pagination preserves the first page, deduplicates incoming topics, and stops at a duplicate-only page', async () => {
  const f = fixture();
  f.config.get = async url => requestedPage(url) === 2 ?
    response([row(102, '跨页重复'), row(103), row(103, '同页重复')]) : response([row(101), row(103)]);
  f.host.onLoadMore();
  await settle();
  assert.deepEqual(ids(f.host), [101, 102, 103]);
  assert.equal(f.host.threadList[0], f.originalRows[0]);
  assert.equal(f.host.threadList[1], f.originalRows[1]);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.hasMore, true);
  f.host.onLoadMore();
  await settle();
  assert.deepEqual(ids(f.host), [101, 102, 103]);
  assert.equal(f.host.currentPage, 3);
  assert.equal(f.host.hasMore, false);
  f.host.onLoadMore();
  assert.equal(f.requests.length, 2);
  assertFreshReads(f);
  assertIdle(f.host);
});

for (const [failureName, getFailure] of [
  ['HTTP failure', async () => ({ success: false, body: '', error: 'HTTP 503' })],
  ['API rejection', async () => ({ success: true, body: JSON.stringify({ error: '没有权限' }) })],
  ['invalid JSON', async () => ({ success: true, body: '{"data":' })],
  ['thrown request', async () => { throw new Error('local simulated network error'); }]
]) {
  test('failed first-page refresh preserves existing topics and page, then retries: ' + failureName, async () => {
    const f = fixture();
    f.host.currentPage = 3;
    f.host.hasMore = false;
    f.config.get = getFailure;
    f.host.onRefresh();
    await settle();
    assert.equal(f.host.threadList, f.originalRows);
    assert.deepEqual(ids(f.host), [101, 102]);
    assert.equal(f.host.currentPage, 3);
    assert.equal(f.host.hasMore, false);
    assert.equal(f.host.loadError, '');
    assert.ok(f.host.refreshFeedback.length > 0);
    assertIdle(f.host);
    f.config.get = async () => response([row(401)]);
    f.host.onRefresh();
    await settle();
    assert.deepEqual(ids(f.host), [401]);
    assert.equal(f.host.currentPage, 1);
    assert.equal(f.host.hasMore, true);
    assert.equal(f.host.refreshFeedback, '');
    assertFreshReads(f);
    assertIdle(f.host);
  });
}

test('initial-load error has an explicit error state and retry requests fresh content', async () => {
  const f = fixture();
  f.host.threadList = [];
  f.config.get = async () => ({ success: false, body: '' });
  await f.host.loadTopicList(1);
  assert.deepEqual(ids(f.host), []);
  assert.ok(f.host.loadError.length > 0);
  assert.equal(f.host.refreshFeedback, '');
  assertIdle(f.host);
  f.config.get = async () => response([row(501)]);
  // The loading/error buttons call this same actual method.
  await f.host.loadTopicList(1);
  assert.deepEqual(ids(f.host), [501]);
  assert.equal(f.host.loadError, '');
  assertFreshReads(f);
  assertIdle(f.host);
});

test('pagination failure preserves content and page and explicit retry requests the failed page again', async () => {
  const f = fixture();
  f.host.currentPage = 2;
  f.config.get = async () => ({ success: true, body: JSON.stringify({ error: '分页读取失败' }) });
  f.host.onLoadMore();
  await settle();
  assert.equal(f.host.threadList, f.originalRows);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.hasMore, true);
  assert.ok(f.host.loadMoreError.length > 0);
  assertIdle(f.host);
  f.host.onLoadMore();
  assert.equal(f.requests.length, 1, 'Automatic pagination waits for the explicit retry');
  f.config.get = async () => response([row(102), row(103)]);
  // Match the page's retry button, without copying its loading implementation.
  await f.host.loadTopicList(f.host.currentPage + 1);
  assert.deepEqual(ids(f.host), [101, 102, 103]);
  assert.equal(f.host.currentPage, 3);
  assert.equal(f.host.loadMoreError, '');
  assert.deepEqual(f.requests.map(request => requestedPage(request.url)), [3, 3]);
  assertFreshReads(f);
  assertIdle(f.host);
});

test('in-flight first-page request blocks duplicate refresh and pagination, then accepts the next refresh', async () => {
  const f = fixture();
  const complete = pendingRequest(f);
  const loading = f.host.loadTopicList(1);
  assert.equal(f.host.isLoading, true);
  f.host.onRefresh();
  f.host.onLoadMore();
  await f.host.loadTopicList(1);
  assert.equal(f.requests.length, 1);
  assert.equal(f.host.threadList, f.originalRows);
  complete(response([row(601)]));
  await loading;
  assert.deepEqual(ids(f.host), [601]);
  assertIdle(f.host);
  f.config.get = async () => response([row(602)]);
  f.host.onRefresh();
  await settle();
  assert.deepEqual(ids(f.host), [602]);
  assert.equal(f.requests.length, 2);
  assertFreshReads(f);
  assertIdle(f.host);
});

test('in-flight pagination blocks refresh and duplicate next-page requests', async () => {
  const f = fixture();
  const complete = pendingRequest(f);
  f.host.onLoadMore();
  assert.equal(f.host.isLoadingMore, true);
  f.host.onRefresh();
  f.host.onLoadMore();
  await f.host.loadTopicList(1);
  await f.host.loadTopicList(2);
  assert.equal(f.requests.length, 1);
  assert.equal(f.host.currentPage, 1);
  complete(response([row(103)]));
  await settle();
  assert.deepEqual(ids(f.host), [101, 102, 103]);
  assert.equal(f.host.currentPage, 2);
  assertFreshReads(f);
  assertIdle(f.host);
});

test('publication and account refreshes request fresh first-page data only once per state change', async () => {
  const f = fixture();
  const stale = response(f.originalRows);
  f.config.get = async (url, extraHeaders, usingCache) => usingCache === false ?
    response([row(f.config.account === 'account-a' ? 701 : 702)]) : stale;
  f.config.revision++;
  f.host.refreshPublishedTopics();
  await settle();
  assert.deepEqual(ids(f.host), [701]);
  assert.equal(f.host.publishRevision, 1);
  f.host.refreshPublishedTopics();
  assert.equal(f.requests.length, 1);
  f.config.account = 'account-b';
  f.host.refreshPublishedTopics();
  await settle();
  assert.deepEqual(ids(f.host), [702]);
  assert.equal(f.host.publishAccountKey, 'account-b');
  f.host.refreshPublishedTopics();
  assert.equal(f.requests.length, 2);
  assert.ok(f.requests.every(request => requestedPage(request.url) === 1));
  assertFreshReads(f);
  assertIdle(f.host);
});

test('publication during pagination waits for completion and then refreshes instead of retaining the old first topic', async () => {
  const f = fixture();
  const complete = pendingRequest(f);
  f.host.onLoadMore();
  f.config.revision++;
  f.host.refreshPublishedTopics();
  assert.equal(f.requests.length, 1);
  assert.equal(f.host.publishRevision, 0);
  f.config.get = async () => response([row(801)]);
  complete(response([row(103)]));
  await settle();
  assert.deepEqual(ids(f.host), [801]);
  assert.equal(f.host.currentPage, 1);
  assert.equal(f.host.publishRevision, 1);
  assert.deepEqual(f.requests.map(request => requestedPage(request.url)), [2, 1]);
  assertFreshReads(f);
  assertIdle(f.host);
});

test('main fid -7 separates only its first high-recommend topic and retains later topics in response order', async () => {
  const f = fixture();
  f.config.get = async () => response([
    { ...row(901, '推荐话题'), recommend: 10 },
    { ...row(902, '普通话题'), recommend: 0 },
    { ...row(903, '推荐数九的普通话题'), recommend: 9 },
    row(904, '没有推荐字段的普通话题'),
    { ...row(905, '非首条高推荐话题'), recommend: 11 }
  ]);
  await f.host.loadTopicList(1);
  assert.deepEqual(ids(f.host), [901, 902, 903, 904, 905], 'Classification does not delete any topic');
  assert.deepEqual(Array.from(f.host.recommendedThreads(), thread => thread.tid), [901]);
  assert.deepEqual(Array.from(f.host.latestThreads(), thread => thread.tid), [902, 903, 904, 905]);
});

test('recommend classification ignores type, title and topic_misc and uses the numeric recommendation', () => {
  const f = fixture();
  for (const recommend of [0, 9]) {
    const ordinary = { ...row(911, 'iOS客户端闪退问题，请下载恩基爱社区app。'), recommend,
      type: 32768, title: '置顶公告', topic_misc: '置顶 推荐 公告' };
    f.host.threadList = [ordinary];
    assert.equal(f.host.isBoardRecommendation(ordinary), false);
  }
  for (const recommended of [
    { ...row(912, '普通标题'), recommend: 10, type: 0, title: '', topic_misc: '' },
    { ...row(913, '其他普通标题'), recommend: 11, type: 16, title: '其他', topic_misc: '其他' }
  ]) {
    f.host.threadList = [recommended];
    assert.equal(f.host.isBoardRecommendation(recommended), true);
  }
});

test('ordinary first topic does not promote a later high-recommend topic into recommendations', async () => {
  const f = fixture();
  f.config.get = async () => response([
    { ...row(914, '普通首条'), recommend: 0 },
    { ...row(915, '之后的高推荐话题'), recommend: 10 },
    { ...row(916, '之后的另一个高推荐话题'), recommend: 20 }
  ]);
  await f.host.loadTopicList(1);
  assert.deepEqual(ids(f.host), [914, 915, 916]);
  assert.deepEqual(Array.from(f.host.recommendedThreads(), thread => thread.tid), []);
  assert.deepEqual(Array.from(f.host.latestThreads(), thread => thread.tid), [914, 915, 916]);
});

test('recommend topics in other boards and sub-boards remain in the normal list', async () => {
  for (const [fid, stid] of [[7, 0], [414, 0], [0, 12007887], [-7, 12007887]]) {
    const f = fixture();
    f.host.fid = fid;
    f.host.stid = stid;
    f.config.get = async () => response([{ ...row(921), recommend: 10 }, row(922)]);
    await f.host.loadTopicList(1);
    assert.equal(f.host.isBoardRecommendation(f.host.threadList[0]), false, `fid=${fid}, stid=${stid}`);
    assert.deepEqual(Array.from(f.host.recommendedThreads(), thread => thread.tid), []);
    assert.deepEqual(Array.from(f.host.latestThreads(), thread => thread.tid), [921, 922]);
    assert.deepEqual(ids(f.host), [921, 922]);
  }
});

test('first-page refresh replaces the first recommendation and reclassifies its changed value without dropping topics', async () => {
  const f = fixture();
  f.config.get = async () => response([{ ...row(931), recommend: 10 }, row(932)]);
  await f.host.loadTopicList(1);
  assert.deepEqual(Array.from(f.host.recommendedThreads(), thread => thread.tid), [931]);
  assert.deepEqual(Array.from(f.host.latestThreads(), thread => thread.tid), [932]);
  f.host.currentPage = 3;
  f.config.get = async () => response([
    { ...row(933, '新推荐话题'), recommend: 20 },
    { ...row(931, '推荐取消后的同一话题'), recommend: 0 },
    { ...row(934, '普通话题'), recommend: 9 }
  ]);
  f.host.onRefresh();
  await settle();
  assert.deepEqual(ids(f.host), [933, 931, 934]);
  assert.deepEqual(Array.from(f.host.recommendedThreads(), thread => thread.tid), [933]);
  assert.deepEqual(Array.from(f.host.latestThreads(), thread => thread.tid), [931, 934]);
  assert.equal(f.host.currentPage, 1);
  f.config.get = async () => response([
    { ...row(933, '首条同一话题取消推荐'), recommend: 0 },
    { ...row(935, '后续的高推荐话题'), recommend: 10 }
  ]);
  f.host.onRefresh();
  await settle();
  assert.deepEqual(ids(f.host), [933, 935]);
  assert.deepEqual(Array.from(f.host.recommendedThreads(), thread => thread.tid), []);
  assert.deepEqual(Array.from(f.host.latestThreads(), thread => thread.tid), [933, 935]);
  assertFreshReads(f);
});

test('pagination deduplicates the repeated first recommendation and keeps later high-recommend topics in normal order', async () => {
  const f = fixture();
  f.config.get = async url => requestedPage(url) === 1 ?
    response([{ ...row(941, '首页推荐'), recommend: 10 }, row(942)]) :
    response([{ ...row(941, '下一页重复推荐'), recommend: 10 }, row(942),
      { ...row(943, '新的推荐'), recommend: 10 }, { ...row(943, '同页重复推荐'), recommend: 10 }, row(944)]);
  await f.host.loadTopicList(1);
  f.host.onLoadMore();
  await settle();
  assert.deepEqual(ids(f.host), [941, 942, 943, 944]);
  assert.deepEqual(Array.from(f.host.recommendedThreads(), thread => thread.tid), [941]);
  assert.deepEqual(Array.from(f.host.latestThreads(), thread => thread.tid), [942, 943, 944]);
  assert.equal(f.host.threadList[0].subject, '首页推荐');
  assert.equal(f.host.currentPage, 2);
  assertFreshReads(f);
});

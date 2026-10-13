'use strict';

/*
 * Run: node tools/test-floor-vote.cjs
 * Loads actual .ets models and extracts actual page methods with the DevEco SDK
 * parser. HTTP and navigation are captured locally; no network request, forum
 * vote, account read, or device operation is performed.
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
const parserOptions = { ets: { components: Object.keys(componentMap.COMPONENT_MAP).concat([
  'AppSubPage', 'ArticleBody'
]) } };

require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    fileName: filename,
    reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  const errors = (result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n'));
  module._compile(result.outputText, filename);
};

const { NgaJsonParser } = require('../entry/src/main/ets/model/NgaJsonParser.ets');
const { ThreadRowInfo } = require('../entry/src/main/ets/model/ThreadRowInfo.ets');
const themeContext = vm.createContext({ exports: {}, require: () => ({}) });
const themePath = path.join(root, 'entry/src/main/ets/model/AppTheme.ets');
vm.runInContext(ts.transpileModule(fs.readFileSync(themePath, 'utf8'), {
  fileName: themePath,
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText, themeContext);
const theme = themeContext.exports;
const pagePath = path.join(root, 'entry/src/main/ets/pages/ArticleListPage.ets');
const pageSource = fs.readFileSync(pagePath, 'utf8');
const pageAst = ts.createSourceFile(pagePath, pageSource, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, parserOptions);
assert.deepEqual(pageAst.parseDiagnostics.map(diagnostic => {
  const pos = pageAst.getLineAndCharacterOfPosition(diagnostic.start || 0);
  return `${pos.line + 1}:${pos.character + 1} ${ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n')}`;
}), [], 'Real page must parse using the SDK ETS parser');
const component = pageAst.statements.find(node => node.name && node.name.getText(pageAst) === 'ArticleListPage');
assert.ok(component, 'ArticleListPage');
const pageMethods = new Map(component.members.filter(ts.isMethodDeclaration)
  .map(method => [method.name.getText(pageAst), method]));

// Include real helper dependencies instead of replacing their implementation.
function realMethods(names, globals) {
  const selected = new Map();
  function add(name) {
    if (selected.has(name)) return;
    const method = pageMethods.get(name);
    assert.ok(method, `Missing actual page method ${name}`);
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
  const result = ts.transpileModule('class RealPage {\n' +
    Array.from(selected.values(), method => method.getText(pageAst)).join('\n') +
    '\n}\nglobalThis.RealPage = RealPage;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
    reportDiagnostics: true
  });
  const errors = (result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n'));
  const context = vm.createContext(globals);
  vm.runInContext(result.outputText, context);
  return new context.RealPage();
}

const TID = 47664817;
function reply(overrides = {}) {
  return Object.assign(new ThreadRowInfo(), { tid: TID, pid: 881645206, lou: 3, content: '回复正文' }, overrides);
}
function voteFixture() {
  const requests = [], routes = [], toasts = [];
  const config = { uid: '1001',
    post: async () => ({ success: true, body: '{"data":{"0":"你对这个帖子表示支持"}}' }) };
  const host = realMethods(['likePost', 'isValidPostTarget', 'postKey', 'postTargetLabel',
    'voteMessage', 'formatVoteResult', 'replyToPost', 'isVoteSelected', 'voteIconColor',
    'voteButtonBackground'], {
    NgaJsonParser,
    ThreadRowInfo,
    LoginStore: { getUser: () => ({ uid: config.uid }) },
    themeAccentTextColor: theme.themeAccentTextColor,
    topicSecondarySurfaceColor: theme.themeSecondarySurfaceColor,
    COLOR_DAY_SUB: theme.COLOR_DAY_SUB,
    COLOR_NIGHT_SUB: theme.COLOR_NIGHT_SUB,
    Color: { Transparent: 'transparent' },
    UrlBuilder: { buildLikeUrl() { return 'https://forum.invalid/nuke.php'; } },
    HttpClient: { post(url, fields, authenticated) {
      requests.push({ url, fields: { ...fields }, authenticated });
      return config.post();
    } },
    console: { info() {}, warn() {}, error() {} }
  });
  Object.assign(host, { tid: TID, fid: 7, title: '测试主题', currentPage: 1, rowList: [],
    selectedVotes: new Map(), voteAccountUid: config.uid, readerMounted: true, nightMode: false,
    voteFeedback: new Map(), isPerformingAction: false, actionMsg: '原有收藏提示',
    getUIContext: () => ({
      getRouter: () => ({ pushUrl: route => { routes.push(JSON.parse(JSON.stringify(route))); return Promise.resolve(); } }),
      getPromptAction: () => ({ showToast: toast => { toasts.push({ ...toast }); } })
    })
  });
  return { host, config, requests, routes, toasts };
}
function parseReplies(rows) {
  const parsed = NgaJsonParser.parseThreadData(JSON.stringify({ data: {
    __T: { tid: TID, subject: '主题' }, __ROWS: rows.length,
    __R: rows.map(fields => ({ content: '回复正文', ...fields }))
  } }));
  assert.equal(parsed.success, true, parsed.error);
  assert.equal(parsed.rowList.length, rows.length);
  return parsed.rowList;
}
function assertTargetFeedback(host, row, expression) {
  const message = host.voteMessage(row);
  assert.match(message, expression);
  assert.ok(message.includes(host.postTargetLabel(row)), message);
  assert.doesNotMatch(message, /这个帖子/);
  assert.equal(host.actionMsg, '原有收藏提示', 'A reply vote must not replace the topic-level favorite banner');
  return message;
}

test('reply model defaults do not silently identify a missing post as the original post', () => {
  const row = new ThreadRowInfo();
  assert.equal(row.pid, -1);
  assert.equal(row.lou, -1);
});

test('actual parser preserves valid reply IDs, original-post zero, and topic fallback', () => {
  const rows = parseReplies([
    { pid: 0, lou: 0 },
    { pid: '881645206', lou: '3' },
    { pid: ' 881645207 ', lou: ' 21 ' },
    { pid: Number.MAX_SAFE_INTEGER, lou: Number.MAX_SAFE_INTEGER }
  ]);
  assert.deepEqual(rows.map(row => [row.tid, row.pid, row.lou]), [
    [TID, 0, 0], [TID, 881645206, 3], [TID, 881645207, 21],
    [TID, Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER]
  ]);
});

test('actual parser keeps absent or malformed pid/lou invalid instead of coercing to zero', () => {
  const invalid = [undefined, null, '', ' ', 'oops', '0oops', '1.5', '1e3', -1,
    '-1', 1.5, Number.MAX_SAFE_INTEGER + 1, '9007199254740992', true, false, {}, []];
  for (const value of invalid) {
    const [badPid, badFloor] = parseReplies([{ pid: value, lou: 1 }, { pid: 123, lou: value }]);
    assert.equal(badPid.pid, -1, `pid ${JSON.stringify(value)}`);
    assert.equal(badFloor.lou, -1, `lou ${JSON.stringify(value)}`);
  }
});

test('supported reply submits its own tid and pid exactly once and reports on that floor', async () => {
  const f = voteFixture(), row = reply();
  await f.host.likePost(row, 1);
  assert.equal(f.requests.length, 1);
  const { fields, authenticated } = f.requests[0];
  assert.deepEqual(fields, {
    __lib: 'topic_recommend', __act: 'add', raw: '3', __output: '8',
    value: '1', tid: String(TID), pid: String(row.pid)
  });
  assert.equal(authenticated, true);
  assertTargetFeedback(f.host, row, /支持/);
  assert.doesNotMatch(f.host.voteMessage(row), /未能确认|失败/);
  assert.equal(f.host.isPerformingAction, false);
});

test('opposed reply and original-post support use their respective IDs and independent feedback', async () => {
  const f = voteFixture(), first = reply(), second = reply({ pid: 881645207, lou: 4 });
  f.config.post = async () => ({ success: true, body: '{"data":{"0":"你对这个帖子表示反对"}}' });
  await f.host.likePost(second, -1);
  assert.equal(f.requests[0].fields.pid, '881645207');
  assert.equal(f.requests[0].fields.value, '-1');
  assertTargetFeedback(f.host, second, /反对/);
  assert.equal(f.host.voteMessage(first), '');
  const original = reply({ pid: 0, lou: 0 });
  f.config.post = async () => ({ success: true, body: '{"data":{"0":"你对这个帖子表示支持"}}' });
  await f.host.likePost(original, 1);
  assert.equal(f.requests[1].fields.pid, '0');
  assertTargetFeedback(f.host, original, /支持/);
  assertTargetFeedback(f.host, second, /反对/);
});

test('invalid or cross-topic replies never fall back to submitting a topic vote', async () => {
  const invalidRows = [
    reply({ pid: -1 }), reply({ pid: undefined }), reply({ pid: null }),
    reply({ pid: NaN }), reply({ pid: Infinity }), reply({ pid: 1.5 }),
    reply({ pid: '881645206' }), reply({ pid: Number.MAX_SAFE_INTEGER + 1 }),
    reply({ lou: -1 }), reply({ lou: undefined }), reply({ lou: NaN }),
    reply({ lou: '3' }), reply({ lou: 1.5 }),
    reply({ pid: 0, lou: 3 }), reply({ pid: 881645206, lou: 0 }),
    reply({ tid: TID + 1 }), reply({ tid: 0 }), reply({ tid: NaN })
  ];
  for (const row of invalidRows) {
    const f = voteFixture();
    f.host.rowList = [row];
    assert.equal(f.host.isValidPostTarget(row), false);
    await f.host.likePost(row, 1);
    assert.equal(f.requests.length, 0, JSON.stringify(row));
    assert.match(f.host.voteMessage(row), /无法确认|重新加载/);
    assert.equal(f.host.isPerformingAction, false);
    assert.equal(f.host.actionMsg, '原有收藏提示');
  }
});

test('invalid rows parsed from real models also cannot submit a vote', async () => {
  for (const row of parseReplies([{ lou: 1 }, { pid: 123 }, { pid: 'broken', lou: 2 }])) {
    const f = voteFixture();
    f.host.rowList = [row];
    await f.host.likePost(row, -1);
    assert.equal(f.requests.length, 0);
    assert.match(f.host.voteMessage(row), /无法确认|重新加载/);
  }
});

test('unknown reply identities keep feedback distinct by their actual position in the page', async () => {
  const f = voteFixture();
  const first = reply({ pid: -1, lou: -1 }), second = reply({ pid: -1, lou: -1 });
  f.host.rowList = [first, second];
  assert.notEqual(f.host.postKey(first), f.host.postKey(second));
  await f.host.likePost(first, 1);
  assert.equal(f.requests.length, 0);
  assert.match(f.host.voteMessage(first), /无法确认|重新加载/);
  assert.equal(f.host.voteMessage(second), '');
  const previousPageKey = f.host.postKey(first);
  f.host.currentPage = 2;
  assert.notEqual(f.host.postKey(first), previousPageKey);
  assert.equal(f.host.voteMessage(first), '', 'An unknown reply on another page must not inherit prior feedback');
});

test('unsupported directions and taps during page loading do not submit a vote', async () => {
  const f = voteFixture(), row = reply();
  for (const direction of [0, 2, NaN, Infinity]) await f.host.likePost(row, direction);
  assert.equal(f.requests.length, 0);
  f.host.isLoading = true;
  await f.host.likePost(row, 1);
  assert.equal(f.requests.length, 0);
  assert.equal(f.host.isPerformingAction, false);
});

test('vote gate rejects a second action while the first reply request is pending', async () => {
  const f = voteFixture(), first = reply(), second = reply({ pid: 881645207, lou: 4 });
  let complete;
  f.config.post = () => new Promise(resolve => { complete = resolve; });
  const pending = f.host.likePost(first, 1);
  assert.equal(f.host.isPerformingAction, true);
  await f.host.likePost(second, -1);
  assert.equal(f.requests.length, 1);
  complete({ success: true, body: '{"data":{"0":"你对这个帖子表示支持"}}' });
  await pending;
  assertTargetFeedback(f.host, first, /支持/);
  assert.equal(f.host.voteMessage(second), '');
  assert.equal(f.host.isPerformingAction, false);
});

test('an in-flight result remains attached to the frozen floor after row and page state changes', async () => {
  const f = voteFixture(), row = reply(), submitted = reply();
  const initialKey = f.host.postKey(submitted);
  let complete;
  f.config.post = () => new Promise(resolve => { complete = resolve; });
  const pending = f.host.likePost(row, 1);
  Object.assign(row, { tid: TID + 1, pid: 881645209, lou: 21 });
  f.host.tid = TID + 1;
  f.host.currentPage = 2;
  complete({ success: true, body: '{"data":{"0":"你对这个帖子表示支持"}}' });
  await pending;
  assert.deepEqual([f.requests[0].fields.tid, f.requests[0].fields.pid], [String(TID), '881645206']);
  assertTargetFeedback(f.host, submitted, /支持/);
  assert.equal(f.host.voteMessage(row), '', 'The newly displayed floor must not inherit the old reply response');
  assert.ok(f.host.voteFeedback.has(initialKey));
  assert.equal(f.host.isPerformingAction, false);
});

test('HTTP failure and thrown request both release the action gate and preserve per-floor failure', async () => {
  for (const response of [async () => ({ success: false, body: '' }), async () => { throw new Error('offline'); }]) {
    const f = voteFixture(), row = reply();
    f.config.post = response;
    await f.host.likePost(row, -1);
    assert.equal(f.host.isPerformingAction, false);
    assertTargetFeedback(f.host, row, /失败|重试/);
    f.config.post = async () => ({ success: true, body: '{"data":{"0":"你对这个帖子表示支持"}}' });
    await f.host.likePost(row, 1);
    assert.equal(f.requests.length, 2, 'After a failed request a later tap must be accepted');
    assertTargetFeedback(f.host, row, /支持/);
  }
});

test('wrapped JSON and root result messages are parsed without executing server JavaScript', () => {
  const f = voteFixture(), label = f.host.postTargetLabel(reply());
  for (const body of [
    '{"data":{"0":"你对这个帖子表示支持"}}',
    '/*$js$*/window.script_muti_get_var_store={"data":{"0":"你对这个帖子表示支持"}}/*$js$*/;',
    '{"0":"你对这个帖子表示支持"}'
  ]) {
    const result = f.host.formatVoteResult(body, label, 1);
    assert.match(result, /支持/);
    assert.doesNotMatch(result, /未能确认|失败/);
    assert.ok(result.includes(label), result);
    assert.doesNotMatch(result, /这个帖子/);
  }
  delete globalThis.floorVoteExecuted;
  const malformed = f.host.formatVoteResult(
    '{"data":{"0":"你对这个帖子表示支持"}};globalThis.floorVoteExecuted=true', label, 1);
  assert.equal(globalThis.floorVoteExecuted, undefined);
  assert.doesNotMatch(malformed, /已支持|支持成功/);
});

test('duplicate-vote and withdrawal wording retains the server action and the clicked floor', () => {
  const f = voteFixture(), label = f.host.postTargetLabel(reply());
  for (const [message, semantics] of [
    ['你已经对这个帖子表示支持', /已经|已/],
    ['你取消了对这个帖子的支持', /取消|撤回/],
    ['你已经对这个帖子表示反对', /已经|已/],
    ['你撤回了对这个帖子的反对', /取消|撤回/]
  ]) {
    const result = f.host.formatVoteResult(JSON.stringify({ data: { 0: message } }), label,
      message.includes('反对') ? -1 : 1);
    assert.match(result, semantics);
    assert.match(result, message.includes('反对') ? /反对/ : /支持/);
    assert.ok(result.includes(label), result);
    assert.doesNotMatch(result, /这个帖子/);
  }
});

test('HTTP-200 error envelopes keep their actual errors rather than claim vote success', async () => {
  const cases = [
    [{ error: '未登录' }, /未登录/],
    [{ error: ['没有权限'] }, /没有权限/],
    [{ error: { 0: '请稍后再试' } }, /请稍后再试/],
    [{ data: { error: '操作次数超过限制' } }, /操作次数超过限制/],
    [{ __MESSAGE: { 0: 1, 1: '未登录' } }, /未登录/],
    [{ data: { __MESSAGE: { 0: 1, 1: '没有权限' } } }, /没有权限/],
    [{ error: 403 }, /403/],
    [{ error: { 0: 403 } }, /403/],
    [{ error: '未登录', data: { 0: '你对这个帖子表示支持' } }, /未登录/],
    [{ data: { 0: '该帖子无法进行此操作' } }, /无法进行/]
  ];
  for (const [body, expected] of cases) {
    const f = voteFixture(), row = reply();
    f.config.post = async () => ({ success: true, body: JSON.stringify(body) });
    await f.host.likePost(row, 1);
    const message = f.host.voteMessage(row);
    assert.match(message, expected);
    assert.doesNotMatch(message, /已支持|支持成功/);
    assert.equal(f.host.isPerformingAction, false);
    assert.equal(f.host.actionMsg, '原有收藏提示');
  }
});

test('empty, malformed, unknown, or numeric-only results never manufacture successful votes', () => {
  const f = voteFixture(), label = f.host.postTargetLabel(reply());
  for (const body of ['', '{', '<html>Bad gateway</html>', 'null', '[]', '{}',
    '{"data":{}}', '{"data":{"0":0}}', '{"data":{"0":""}}']) {
    const result = f.host.formatVoteResult(body, label, 1);
    assert.ok(result.length > 0, JSON.stringify(body));
    assert.doesNotMatch(result, /已支持|支持成功/);
    assert.match(result, /未能确认|失败|异常/);
  }
});

test('reply navigation uses the same post target guard and the actual clicked reply ID', () => {
  const f = voteFixture(), valid = reply();
  f.host.replyToPost(valid);
  assert.equal(f.routes.length, 1);
  assert.equal(f.routes[0].url, 'pages/ReplyPage');
  assert.equal(f.routes[0].params.tid, TID);
  assert.equal(f.routes[0].params.pid, valid.pid);
  for (const row of [reply({ pid: -1 }), reply({ pid: 0, lou: 3 }),
    reply({ lou: -1 }), reply({ tid: TID + 1 })]) {
    f.host.replyToPost(row);
  }
  assert.equal(f.routes.length, 1, 'Malformed replies must not navigate with pid=0');
  assert.equal(f.toasts.length, 4);
  assert.ok(f.toasts.every(toast => /无法确认|重新加载/.test(toast.message)));
});

function confirmedVote(message) {
  return { success: true, body: JSON.stringify({ data: { 0: message } }) };
}
function assertSelection(host, row, expected) {
  assert.equal(host.isVoteSelected(row, 1), expected === 1, 'Support highlight');
  assert.equal(host.isVoteSelected(row, -1), expected === -1, 'Oppose highlight');
  assert.equal(host.isVoteSelected(row, 0), false, 'Cancellation is not a selected direction');
}

test('confirmed support and opposition are exclusive and scoped to the clicked floor', async () => {
  const f = voteFixture(), row = reply(), other = reply({ pid: 881645207, lou: 4 });
  assertSelection(f.host, row, 0);
  await f.host.likePost(row, 1);
  assertSelection(f.host, row, 1);
  assertSelection(f.host, other, 0);
  f.config.post = async () => confirmedVote('你对这个帖子表示反对');
  await f.host.likePost(row, -1);
  assertSelection(f.host, row, -1);
  await f.host.likePost(other, -1);
  assertSelection(f.host, row, -1);
  assertSelection(f.host, other, -1);
  assert.equal(f.host.selectedVotes.size, 2);
});

test('explicit support or opposition withdrawal clears both highlights', async () => {
  for (const [direction, message] of [[1, '你取消了对这个帖子的支持'], [-1, '你撤回了对这个帖子的反对']]) {
    const f = voteFixture(), row = reply();
    f.config.post = async () => confirmedVote(direction === 1 ? '你对这个帖子表示支持' : '你对这个帖子表示反对');
    await f.host.likePost(row, direction);
    assertSelection(f.host, row, direction);
    f.config.post = async () => confirmedVote(message);
    await f.host.likePost(row, direction);
    assertSelection(f.host, row, 0);
    assert.match(f.host.voteMessage(row), /取消|撤回/);
  }
});

test('already-voted response highlights the confirmed direction instead of the clicked direction', async () => {
  const f = voteFixture(), row = reply();
  f.config.post = async () => confirmedVote('你已经对这个帖子表示反对');
  await f.host.likePost(row, 1);
  assertSelection(f.host, row, -1);
  f.config.post = async () => confirmedVote('你已经对这个帖子表示支持');
  await f.host.likePost(row, -1);
  assertSelection(f.host, row, 1);
});

test('HTTP, business, malformed, ambiguous, and thrown failures preserve the prior highlight', async () => {
  const responses = [
    async () => ({ success: false, body: '' }),
    async () => { throw new Error('offline'); },
    async () => ({ success: true, body: '{"error":"未登录","data":{"0":"你对这个帖子表示反对"}}' }),
    async () => ({ success: true, body: '{"error":0,"data":{"error":"没有权限","0":"你对这个帖子表示反对"}}' }),
    async () => ({ success: true, body: '{"__MESSAGE":{"0":1,"1":"没有权限"},"data":{"0":"你对这个帖子表示反对"}}' }),
    async () => ({ success: true, body: '{' }),
    async () => confirmedVote('操作成功'),
    async () => confirmedVote('你没有对这个帖子表示反对')
  ];
  for (const response of responses) {
    const f = voteFixture(), row = reply();
    await f.host.likePost(row, 1);
    f.config.post = response;
    await f.host.likePost(row, -1);
    assertSelection(f.host, row, 1);
    assert.equal(f.host.isPerformingAction, false);
  }
});

test('a pending request preserves the current highlight until its response is confirmed', async () => {
  const f = voteFixture(), row = reply();
  await f.host.likePost(row, 1);
  let complete;
  f.config.post = () => new Promise(resolve => { complete = resolve; });
  const pending = f.host.likePost(row, -1);
  assertSelection(f.host, row, 1);
  complete(confirmedVote('你对这个帖子表示反对'));
  await pending;
  assertSelection(f.host, row, -1);
});

test('refresh and page reconstruction retain the confirmed highlight only for the same floor', async () => {
  const f = voteFixture(), row = reply();
  await f.host.likePost(row, 1);
  f.host.rowList = [];
  f.host.currentPage = 2;
  const reconstructed = reply();
  f.host.rowList = [reconstructed, reply({ pid: 881645208, lou: 22 })];
  assert.notEqual(reconstructed, row);
  assertSelection(f.host, reconstructed, 1);
  assertSelection(f.host, f.host.rowList[1], 0);
  assertSelection(f.host, reply({ tid: TID + 1 }), 0);
});

test('switching accounts isolates each confirmed highlight and signing out hides them', async () => {
  const f = voteFixture(), row = reply();
  await f.host.likePost(row, 1);
  f.config.uid = '1002';
  f.host.syncVoteAccount();
  assertSelection(f.host, row, 0);
  f.config.post = async () => confirmedVote('你对这个帖子表示反对');
  await f.host.likePost(row, -1);
  assertSelection(f.host, row, -1);
  f.config.uid = '';
  f.host.syncVoteAccount();
  assertSelection(f.host, row, 0);
  f.config.uid = '1001';
  f.host.syncVoteAccount();
  assertSelection(f.host, row, 1);
  f.config.uid = '1002';
  f.host.syncVoteAccount();
  assertSelection(f.host, row, -1);
});

test('an in-flight highlight stays with its captured account and floor', async () => {
  const f = voteFixture(), row = reply(), submitted = reply();
  let complete;
  f.config.post = () => new Promise(resolve => { complete = resolve; });
  const pending = f.host.likePost(row, 1);
  f.config.uid = '1002';
  f.host.syncVoteAccount();
  Object.assign(row, { pid: 881645207, lou: 4 });
  complete(confirmedVote('你对这个帖子表示支持'));
  await pending;
  assertSelection(f.host, submitted, 0);
  assertSelection(f.host, row, 0);
  f.config.uid = '1001';
  f.host.syncVoteAccount();
  assertSelection(f.host, submitted, 1);
  assertSelection(f.host, row, 0);
});

test('a response after reader unmount does not update highlights', async () => {
  const f = voteFixture(), row = reply();
  let complete;
  f.config.post = () => new Promise(resolve => { complete = resolve; });
  const pending = f.host.likePost(row, 1);
  f.host.readerMounted = false;
  complete(confirmedVote('你对这个帖子表示支持'));
  await pending;
  assert.equal(f.host.selectedVotes.size, 0);
  assert.equal(f.host.isPerformingAction, false);
});

test('a guest response cannot create a confirmed account highlight', async () => {
  const f = voteFixture(), row = reply();
  f.config.uid = '';
  f.host.syncVoteAccount();
  await f.host.likePost(row, 1);
  assertSelection(f.host, row, 0);
  assert.equal(f.host.selectedVotes.size, 0);
});

test('selected icons and backgrounds use the application theme in day and night modes', async () => {
  const f = voteFixture(), row = reply();
  await f.host.likePost(row, 1);
  const colors = [];
  for (const nightMode of [false, true]) {
    f.host.nightMode = nightMode;
    const accent = theme.themeAccentTextColor(nightMode);
    const surface = theme.themeSecondarySurfaceColor(nightMode);
    const subtext = nightMode ? theme.COLOR_NIGHT_SUB : theme.COLOR_DAY_SUB;
    assert.equal(f.host.voteIconColor(row, 1), accent);
    assert.equal(f.host.voteButtonBackground(row, 1), surface);
    assert.equal(f.host.voteIconColor(row, -1), subtext);
    assert.equal(f.host.voteButtonBackground(row, -1), 'transparent');
    assert.notEqual(accent, subtext);
    colors.push([accent, surface]);
  }
  assert.notDeepEqual(colors[0], colors[1]);
});

'use strict';

/*
 * Run: node tools/test-message-detail.cjs
 * Loads actual .ets models and extracts actual ArkUI page/component methods
 * through the DevEco SDK AST. HTTP/navigation are local captures only; no
 * network, credentials, device access, or server JavaScript execution occurs.
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

function transpile(source, filename) {
  const result = ts.transpileModule(source, {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  const errors = (result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n'));
  return result.outputText;
}

require.extensions['.ets'] = (module, filename) => {
  module._compile(transpile(fs.readFileSync(filename, 'utf8'), filename), filename);
};

const { MessageDetailParser } = require('../entry/src/main/ets/model/MessageDetailParser.ets');
const { NgaMessagePost, NgaMessageDetailData } = require('../entry/src/main/ets/model/MessageDetailInfo.ets');
const { MessageNotification } = require('../entry/src/main/ets/model/NotificationInfo.ets');

function realMethods(relativePath, name, names, globals, options = {}) {
  const filename = path.join(root, relativePath);
  const source = fs.readFileSync(filename, 'utf8');
  const ast = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, parserOptions);
  assert.deepEqual(ast.parseDiagnostics.map(item => {
    const pos = ast.getLineAndCharacterOfPosition(item.start || 0);
    return `${pos.line + 1}:${pos.character + 1} ${ts.flattenDiagnosticMessageText(item.messageText, '\n')}`;
  }), [], `${name} must parse with the DevEco ETS parser`);
  const component = ast.statements.find(node => node.name && node.name.getText(ast) === name);
  assert.ok(component, name);
  const methods = new Map(component.members.filter(ts.isMethodDeclaration).map(method => [method.name.getText(ast), method]));
  const selected = new Map();
  function add(methodName) {
    if (selected.has(methodName)) return;
    const method = methods.get(methodName);
    assert.ok(method, `Missing actual ${name} method ${methodName}`);
    selected.set(methodName, method);
    function visit(node) {
      if (ts.isPropertyAccessExpression(node) && node.expression.kind === ts.SyntaxKind.ThisKeyword) {
        const dependency = node.name.getText(ast);
        if (methods.has(dependency)) add(dependency);
      }
      ts.forEachChild(node, visit);
    }
    visit(method.body);
  }
  names.forEach(add);
  const helpers = ast.statements.filter(node => ts.isClassDeclaration(node) && node !== component)
    .map(node => node.getText(ast)).join('\n');
  const className = options.static ? name : 'RealSubject';
  const output = transpile(helpers + '\nclass ' + className + ' {\n' +
    Array.from(selected.values(), method => method.getText(ast)).join('\n') +
    `\n}\nglobalThis.RealSubject = ${className};`, filename);
  const context = vm.createContext(globals);
  vm.runInContext(output, context);
  return options.static ? context.RealSubject : new context.RealSubject();
}

const MID = 741123;
const body = payload => JSON.stringify({ data: { 0: payload } });
const post = (content = '最初发送的正文', overrides = {}) => ({
  content, subject: '最初发送的主题', from: '42', time: '1791216000', ...overrides
});
const conversation = (overrides = {}) => ({
  0: post(), userInfo: { 42: { username: '原发送者', avatar: 'https://img.invalid/42.png' } },
  currentPage: '1', nextPage: '0', rowsPerPage: '20', ...overrides
});
function parse(payload, mid = MID, page = 1) {
  return MessageDetailParser.parse(body(payload), mid, page);
}
function success(result) {
  assert.ok(result instanceof NgaMessageDetailData);
  assert.equal(result.success, true, result.errorMessage);
}
function failure(result, expression) {
  assert.equal(result.success, false);
  assert.equal(result.posts.length, 0, 'A failed response must not expose a partially parsed conversation');
  assert.ok(result.errorMessage.trim().length > 0, 'Failed details need a visible error');
  if (expression) assert.match(result.errorMessage, expression);
}

test('real detail parser reads the initial message, author, avatar, and timestamp', () => {
  const result = parse(conversation());
  success(result);
  assert.equal(result.mid, MID);
  assert.equal(result.subject, '最初发送的主题');
  assert.equal(result.currentPage, 1);
  assert.equal(result.nextPage, 0);
  assert.equal(result.posts.length, 1);
  const original = result.posts[0];
  assert.ok(original instanceof NgaMessagePost);
  assert.deepEqual([original.index, original.content, original.subject, original.authorId,
    original.author, original.avatar, original.time],
  [1, '最初发送的正文', '最初发送的主题', 42, '原发送者', 'https://img.invalid/42.png', 1791216000]);
});

test('message body keeps BBCode, image/emoticon tags, links, entities, and line breaks intact', () => {
  const content = '第一行\n[quote][pid=881/476,1]回复[/pid][/quote]\n' +
    '[img]https://img.invalid/a.jpg[/img][s:ac:good]\n[url=https://bbs.invalid/read.php?tid=476]原帖[/url]&lt;正文&gt;';
  const result = parse(conversation({ 0: post(content) }));
  success(result);
  assert.equal(result.posts[0].content, content);
});

test('sparse numbered rows stay chronological and retain distinct keys', () => {
  const result = parse(conversation({ 10: post('第十一条'), 2: post('第三条'), nextPage: '3' }));
  success(result);
  assert.deepEqual(result.posts.map(item => item.content), ['最初发送的正文', '第三条', '第十一条']);
  assert.deepEqual(result.posts.map(item => item.index), [1, 3, 11]);
  assert.equal(new Set(result.posts.map(item => item.key)).size, 3);
  assert.equal(result.nextPage, 3);
});

test('pagination uses response row count and preserves the NGA nextPage marker', () => {
  const first = parse(conversation({ currentPage: '2', rowsPerPage: '10', nextPage: '4' }), MID, 2);
  success(first);
  assert.deepEqual([first.currentPage, first.rowsPerPage, first.nextPage, first.posts[0].index], [2, 10, 4, 11]);
  assert.notEqual(first.posts[0].key, parse(conversation()).posts[0].key);
  assert.notEqual(first.posts[0].key, parse(conversation(), MID + 1).posts[0].key);
  for (const nextPage of [undefined, null, '', 'bad', 0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
    const last = parse(conversation({ currentPage: 2, nextPage }), MID, 2);
    success(last);
    assert.equal(last.nextPage, 0, JSON.stringify(nextPage));
  }
  const marker = parse(conversation({ currentPage: 2, nextPage: 1 }), MID, 2);
  success(marker);
  assert.equal(marker.nextPage, 1, 'A positive legacy marker still means more messages exist');
});

function modernConversation(overrides = {}) {
  return {
    allmsgs: { 0: post('最初发送的正文', { id: '91001', data: '', bit: '0' }),
      1: post('后续消息正文', { id: '91002', from: '77', data: '', bit: '0' }) },
    length: '2', nextPage: '0', subjectBit: '0',
    userInfo: { 42: { username: '原发送者', avatar: 'https://img.invalid/42.png' },
      77: { username: '回复发送者', avatar: 'https://img.invalid/77.png' } },
    starterUid: '42', allUsers: [42, 77], currentPage: '1', ...overrides
  };
}

test('the observed modern allmsgs envelope displays original text and replies with their authors', () => {
  const allmsgs = Object.fromEntries(Array.from({ length: 20 }, (_, index) => [index,
    post(index === 0 ? '最初发送的正文' : `第${index}条回复`,
      { id: String(91001 + index), from: index === 0 ? '42' : '77', data: '', bit: '0' })]));
  const result = parse(modernConversation({ allmsgs, length: '40', nextPage: '2' }));
  success(result);
  assert.equal(result.posts.length, 20);
  assert.equal(result.subject, '最初发送的主题');
  assert.equal(result.posts[0].content, '最初发送的正文');
  assert.equal(result.posts[0].author, '原发送者');
  assert.equal(result.posts[1].author, '回复发送者');
  assert.equal(result.posts[1].avatar, 'https://img.invalid/77.png');
  assert.deepEqual(result.posts.map(item => item.index), Array.from({ length: 20 }, (_, index) => index + 1));
  assert.equal(result.nextPage, 2);
});

test('modern allmsgs supports indexed objects or arrays through either outer data container', () => {
  const fixture = modernConversation();
  for (const allmsgs of [fixture.allmsgs, Object.values(fixture.allmsgs)]) {
    for (const data of [{ 0: modernConversation({ allmsgs }) }, [modernConversation({ allmsgs })]]) {
      const result = MessageDetailParser.parse(JSON.stringify({ data }), MID);
      success(result);
      assert.deepEqual(result.posts.map(item => item.content), ['最初发送的正文', '后续消息正文']);
    }
  }
});

test('a server message ID stays stable across pages and remains isolated between conversations', () => {
  const first = parse(modernConversation());
  const second = parse(modernConversation({ allmsgs: { 0: post('后续消息正文', { id: 91002 }) },
    currentPage: 2 }), MID, 2);
  success(first);
  success(second);
  assert.equal(first.posts[1].key, second.posts[0].key);
  const different = parse(modernConversation(), MID + 1);
  assert.notEqual(first.posts[1].key, different.posts[1].key);
  const noId = { allmsgs: { 0: post('旧消息未提供id') }, length: 1 };
  assert.notEqual(parse(noId).posts[0].key, parse({ ...noId, currentPage: 2 }, MID, 2).posts[0].key);
});

test('unknown nonempty modern containers and positive counts without rows cannot hide missing body data', () => {
  for (const allmsgs of [null, true, 3, 'wrong', { unexpected: post() }, { 0: null }, { 0: {} }]) {
    failure(parse(modernConversation({ allmsgs })));
  }
  for (const allmsgs of [{}, []]) {
    failure(parse(modernConversation({ allmsgs, length: 2 })));
    const empty = parse(modernConversation({ allmsgs, length: 0 }));
    success(empty);
    assert.equal(empty.posts.length, 0);
  }
  failure(parse({ length: 2, currentPage: 1, nextPage: 0 }));
});

test('array or object data containers represent the same conversation', () => {
  for (const inner of [conversation(), [post()]]) {
    for (const data of [{ 0: inner }, [inner]]) {
      const result = MessageDetailParser.parse(JSON.stringify({ data }), MID);
      success(result);
      assert.equal(result.posts[0].content, '最初发送的正文');
    }
  }
});

test('subject-only legacy system messages show their original text and identify a sender fallback', () => {
  const result = parse({ 0: { subject: '系统通知原文', time: 1791216000 },
    1: post('有发送者的正文', { from: 77, from_username: '旧格式发送者' }),
    2: post('只有编号的正文', { from: 88 }) });
  success(result);
  assert.equal(result.posts[0].content, '系统通知原文');
  assert.deepEqual(result.posts.map(item => item.author), ['系统消息', '旧格式发送者', '88']);
  assert.equal(result.subject, '系统通知原文');
  const title = parse(conversation({ subject: '服务器会话标题' }));
  success(title);
  assert.equal(title.subject, '服务器会话标题');
});

test('known wrappers, raw control characters, and error-fill tails retain message content safely', () => {
  const raw = '{"data":{"0":{"0":{"content":"第一行\t末尾\n第二行","subject":"原始标题","from":42}}}}';
  for (const value of [raw, 'window.script_muti_get_var_store=' + raw + ';',
    '\uFEFF /*$js$*/ window.script_muti_get_var_store=/*$js$*/' + raw + ';/*$js$*/',
    raw + '/*error fill content']) {
    const result = MessageDetailParser.parse(value, MID);
    success(result);
    assert.equal(result.posts[0].content, '第一行\t末尾\n第二行');
  }
});

test('unsupported server JavaScript is rejected without executing it', () => {
  globalThis.messageDetailSentinel = 0;
  const result = MessageDetailParser.parse('globalThis.messageDetailSentinel=1;' + body(conversation()), MID);
  failure(result);
  assert.equal(globalThis.messageDetailSentinel, 0);
  delete globalThis.messageDetailSentinel;
});

test('empty valid conversation containers render an empty state while absent or scalar containers fail', () => {
  for (const payload of [{}, [], { nextPage: 0, userInfo: {} }]) {
    const result = parse(payload);
    success(result);
    assert.equal(result.posts.length, 0);
  }
  for (const raw of ['', '{}', 'null', '{"data":{}}', '{"data":[]}', '{"data":null}',
    '{"data":{"0":null}}', '{"data":{"0":7}}', '{"data":{"0":""}}']) {
    failure(MessageDetailParser.parse(raw, MID));
  }
});

test('malformed nonempty message rows cannot silently become an empty success', () => {
  for (const payload of [{ 0: null }, { 0: 3 }, { 0: 'wrong' }, { 0: {} },
    conversation({ 1: null })]) {
    failure(parse(payload));
  }
  for (const value of [{}, [], true, false]) {
    failure(parse(conversation({ 0: post(value) })));
    failure(parse(conversation({ 0: post('正文', { subject: value }) })));
  }
});

test('login and endpoint errors remain visible even alongside apparently valid details', () => {
  for (const raw of [
    JSON.stringify({ error: ['<b>请先登录</b>'], data: { 0: conversation() } }),
    JSON.stringify({ data: { 0: conversation(), error: { 0: '<b>登录信息已过期</b>' } } }),
    JSON.stringify({ data: { 0: conversation(), __MESSAGE: ['ERROR', '<b>没有权限读取消息</b>'] } }),
    JSON.stringify({ __MESSAGE: ['ERROR', '<b>消息已删除</b>'], data: { 0: conversation() } }),
    body('没有权限读取消息')
  ]) failure(MessageDetailParser.parse(raw, MID), /登录|权限|删除/);
});

test('invalid message identifiers fail before accepting valid server content', () => {
  for (const mid of [0, -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '741123', undefined, null]) {
    failure(MessageDetailParser.parse(body(conversation()), mid), /编号/);
  }
});

test('the actual URL builder requests read action and page one for the initial body', () => {
  const builder = realMethods('entry/src/main/ets/model/UrlBuilder.ets', 'UrlBuilder', ['buildMessageReadUrl'],
    { HttpClient: { getDomain: () => 'https://forum.invalid' } }, { static: true });
  for (const page of [undefined, 4]) {
    const url = new URL(page === undefined ? builder.buildMessageReadUrl(MID) : builder.buildMessageReadUrl(MID, page));
    assert.equal(url.origin, 'https://forum.invalid');
    assert.equal(url.pathname, '/nuke.php');
    assert.deepEqual(Object.fromEntries(url.searchParams), {
      __lib: 'message', __act: 'message', act: 'read', lite: 'js', page: String(page || 1), mid: String(MID)
    });
  }
});

function navigationFixture() {
  const routes = [], toasts = [];
  const host = realMethods('entry/src/main/ets/components/NotificationContent.ets', 'NotificationContent',
    ['onMessageClick'], { MessageNotification });
  host.getUIContext = () => ({
    getRouter: () => ({ pushUrl: route => { routes.push(JSON.parse(JSON.stringify(route))); return Promise.resolve(); } }),
    getPromptAction: () => ({ showToast: toast => toasts.push({ ...toast }) })
  });
  return { host, routes, toasts };
}

test('tapping the actual short-message handler opens its conversation ID and original subject', () => {
  const f = navigationFixture();
  f.host.onMessageClick(Object.assign(new MessageNotification(), { mid: MID, subject: '原始短消息主题' }));
  assert.deepEqual(f.routes, [{ url: 'pages/MessageDetailPage', params: { mid: MID, subject: '原始短消息主题' } }]);
  assert.equal(f.toasts.length, 0);
});

test('invalid short-message IDs never open a topic or unrelated conversation', () => {
  const f = navigationFixture();
  for (const mid of [0, -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '741123', undefined, null]) {
    f.host.onMessageClick(Object.assign(new MessageNotification(), { mid, subject: '主题' }));
  }
  assert.equal(f.routes.length, 0);
  assert.equal(f.toasts.length, 9);
  assert.ok(f.toasts.every(item => /刷新|重试/.test(item.message)));
});

test('the message detail route is registered and real message rows wire their click handler', () => {
  const profile = JSON.parse(fs.readFileSync(path.join(root, 'entry/src/main/resources/base/profile/main_pages.json'), 'utf8'));
  assert.equal(profile.src.filter(item => item === 'pages/MessageDetailPage').length, 1);
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/NotificationContent.ets'), 'utf8');
  assert.match(source, /\.onClick\(\(\)\s*=>\s*this\.onMessageClick\(msg\)\)/);
});

function pageFixture() {
  const requests = [], initializations = [], keyboardModes = [];
  const config = {
    account: 'account-a', loggedIn: true,
    hostContext: {}, params: { mid: MID, subject: '路由传入主题' }, keyboardMode: 'offset',
    get: async () => ({ success: true, body: body(conversation()) }),
    parse: (raw, mid, page) => MessageDetailParser.parse(raw, mid, page)
  };
  const host = realMethods('entry/src/main/ets/pages/MessageDetailPage.ets', 'MessageDetailPage',
    ['loadDetail', 'aboutToAppear', 'aboutToDisappear', 'onPageShow'], {
      NgaMessagePost, NgaMessageDetailData,
      LoginStore: { init: context => initializations.push({ kind: 'login', context }),
        hasUser: () => config.loggedIn, getUser: () => ({ uid: config.account }) },
      HttpClient: { get(url) { requests.push(url); return config.get(); } },
      UrlBuilder: { buildMessageReadUrl: (mid, page) => `https://forum.invalid/messages?mid=${mid}&page=${page}` },
      MessageDetailParser: { parse: (...args) => config.parse(...args) },
      SettingsStore: { init: context => initializations.push({ kind: 'settings', context }), getBool: () => false },
      SettingKeys: { NIGHT: 'night' }, SettingDefaults: { NIGHT: false },
      KeyboardAvoidMode: { OFFSET: 'offset', RESIZE: 'resize' },
      applyWindowTheme() {}, console: { info() {}, warn() {}, error() {} }
    });
  Object.assign(host, { mounted: true, requestVersion: 0, activeAccountKey: 'account-a', ctx: {},
    mid: MID, subject: '列表原始主题', postList: [], currentPage: 0, nextPage: 0,
    isLoading: false, loadError: '', loadMoreError: '', nightMode: false,
    keyboardModeSet: false, keyboardAvoidMode: 'offset' });
  host.getUIContext = () => ({ getHostContext: () => config.hostContext,
    getRouter: () => ({ getParams: () => config.params }),
    getKeyboardAvoidMode: () => config.keyboardMode,
    setKeyboardAvoidMode: mode => { keyboardModes.push(mode); config.keyboardMode = mode; } });
  return { host, config, requests, initializations, keyboardModes };
}
const contents = host => Array.from(host.postList, item => item.content);
function defer() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

test('the real detail page starts with page one and displays the initial body', async () => {
  const f = pageFixture();
  await f.host.loadDetail(1);
  assert.deepEqual(f.requests, [`https://forum.invalid/messages?mid=${MID}&page=1`]);
  assert.deepEqual(contents(f.host), ['最初发送的正文']);
  assert.deepEqual([f.host.subject, f.host.currentPage, f.host.nextPage, f.host.isLoading,
    f.host.loadError, f.host.loadMoreError], ['最初发送的主题', 1, 0, false, '', '']);
});

test('the actual lifecycle reads route params, initializes stores and starts reading page one', async () => {
  const f = pageFixture();
  f.host.mid = 0;
  f.host.subject = '';
  f.host.mounted = false;
  f.host.activeAccountKey = '';
  f.host.aboutToAppear();
  await new Promise(setImmediate);
  assert.equal(f.host.mid, MID);
  assert.equal(f.host.activeAccountKey, 'account-a');
  assert.equal(f.host.mounted, true);
  assert.deepEqual(f.requests, [`https://forum.invalid/messages?mid=${MID}&page=1`]);
  assert.deepEqual(f.initializations.map(item => item.kind), ['settings', 'login']);
  assert.ok(f.initializations.every(item => item.context === f.config.hostContext));
  assert.deepEqual(contents(f.host), ['最初发送的正文']);
  assert.equal(f.host.isLoading, false);
});

test('an unavailable host context produces a visible initialization error without a request', () => {
  const f = pageFixture();
  f.config.hostContext = undefined;
  f.host.aboutToAppear();
  assert.equal(f.requests.length, 0);
  assert.equal(f.initializations.length, 0);
  assert.match(f.host.loadError, /初始化|重试/);
});

test('the actual page resizes for its reply keyboard and restores the previous avoidance mode when leaving', async () => {
  const f = pageFixture();
  f.host.aboutToAppear();
  await new Promise(setImmediate);
  assert.deepEqual(f.keyboardModes, ['resize']);
  assert.equal(f.host.keyboardModeSet, true);
  assert.equal(f.host.keyboardAvoidMode, 'offset');
  f.host.aboutToDisappear();
  assert.deepEqual(f.keyboardModes, ['resize', 'offset']);
  assert.equal(f.host.keyboardModeSet, false);
  f.host.aboutToDisappear();
  assert.deepEqual(f.keyboardModes, ['resize', 'offset'], 'Repeated disappearance cannot change keyboard mode again');
});

test('overlapping modern message pages append new IDs once while retaining the original body', async () => {
  const f = pageFixture();
  f.config.get = async () => ({ success: true, body: body(modernConversation({ nextPage: 2 })) });
  await f.host.loadDetail(1);
  f.config.get = async () => ({ success: true, body: body(modernConversation({ allmsgs: {
    0: post('后续消息正文', { id: '91002' }), 1: post('第三条正文', { id: '91003' })
  }, currentPage: 2, nextPage: 0 })) });
  await f.host.loadDetail(2, true);
  assert.deepEqual(contents(f.host), ['最初发送的正文', '后续消息正文', '第三条正文']);
  assert.equal(new Set(Array.from(f.host.postList, item => item.key)).size, 3);
  assert.equal(f.host.nextPage, 0);
});

test('a real append retains the original text and title, and translates nextPage marker one', async () => {
  const f = pageFixture();
  f.config.get = async () => ({ success: true, body: body(conversation({ nextPage: 1 })) });
  await f.host.loadDetail(1);
  assert.equal(f.host.nextPage, 2);
  f.config.get = async () => ({ success: true, body: body(conversation({
    0: post('后续回复', { subject: '后续回复主题' }), currentPage: 2, nextPage: 1
  })) });
  await f.host.loadDetail(f.host.nextPage, true);
  assert.deepEqual(contents(f.host), ['最初发送的正文', '后续回复']);
  assert.equal(f.host.subject, '最初发送的主题');
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.nextPage, 3);
  assert.equal(f.host.isLoading, false);
  assert.equal(new Set(Array.from(f.host.postList, item => item.key)).size, 2);
  assert.equal(new URL(f.requests[1]).searchParams.get('page'), '2');
});

test('explicit future nextPage numbers are kept and an empty returned page ends the conversation', async () => {
  const f = pageFixture();
  f.config.get = async () => ({ success: true, body: body(conversation({ nextPage: 4 })) });
  await f.host.loadDetail(1);
  assert.equal(f.host.nextPage, 4);
  f.config.get = async () => ({ success: true, body: body({ currentPage: 4, nextPage: 1 }) });
  await f.host.loadDetail(f.host.nextPage, true);
  assert.equal(new URL(f.requests[1]).searchParams.get('page'), '4');
  assert.deepEqual(contents(f.host), ['最初发送的正文']);
  assert.equal(f.host.currentPage, 4);
  assert.equal(f.host.nextPage, 0);
});

test('duplicate post keys within one response are removed without removing different messages', async () => {
  const f = pageFixture();
  f.config.get = async () => ({ success: true, body: body(conversation({ 1: post('第二条正文') })) });
  f.config.parse = (...args) => {
    const result = MessageDetailParser.parse(...args);
    result.posts.push(result.posts[0], result.posts[1]);
    return result;
  };
  await f.host.loadDetail(1);
  assert.deepEqual(contents(f.host), ['最初发送的正文', '第二条正文']);
  assert.equal(f.host.isLoading, false);
});

test('failed appends retain the original body, next target, and title, and allow an explicit retry', async () => {
  const f = pageFixture();
  f.config.get = async () => ({ success: true, body: body(conversation({ nextPage: 2 })) });
  await f.host.loadDetail(1);
  f.config.get = async () => ({ success: false, body: '', error: 'offline' });
  await f.host.loadDetail(2, true);
  assert.deepEqual(contents(f.host), ['最初发送的正文']);
  assert.deepEqual([f.host.currentPage, f.host.nextPage, f.host.subject, f.host.isLoading],
    [1, 2, '最初发送的主题', false]);
  assert.equal(f.host.loadError, '');
  assert.match(f.host.loadMoreError, /失败|网络|重试/);
  assert.equal(f.requests.length, 2, 'A failed request must not automatically retry');
  f.config.get = async () => ({ success: true, body: body(conversation({ 0: post('重新加载的回复'), currentPage: 2 })) });
  await f.host.loadDetail(f.host.nextPage, true);
  assert.deepEqual(contents(f.host), ['最初发送的正文', '重新加载的回复']);
  assert.equal(f.host.loadMoreError, '');
  assert.equal(f.host.isLoading, false);
});

test('HTTP, parse, thrown, and wrong-page failures release loading and remain visible', async () => {
  for (const get of [
    async () => ({ success: false, body: '' }),
    async () => ({ success: true, body: '{not json' }),
    async () => { throw new Error('测试传输异常'); },
    async () => ({ success: true, body: body(conversation({ currentPage: 2 })) })
  ]) {
    const f = pageFixture();
    f.config.get = get;
    await f.host.loadDetail(1);
    assert.equal(f.host.isLoading, false);
    assert.equal(f.host.postList.length, 0);
    assert.ok(f.host.loadError.length > 0);
    assert.equal(f.host.currentPage, 0);
    assert.equal(f.requests.length, 1);
  }
});

test('a response from the wrong page cannot replace the original body during append', async () => {
  const f = pageFixture();
  f.config.get = async () => ({ success: true, body: body(conversation({ nextPage: 2 })) });
  await f.host.loadDetail(1);
  f.config.get = async () => ({ success: true, body: body(conversation({ 0: post('错误页正文'), currentPage: 1 })) });
  await f.host.loadDetail(2, true);
  assert.deepEqual(contents(f.host), ['最初发送的正文']);
  assert.match(f.host.loadMoreError, /页码/);
  assert.equal(f.host.currentPage, 1);
  assert.equal(f.host.nextPage, 2);
  assert.equal(f.host.isLoading, false);
});

test('the loading lock prevents duplicate concurrent requests', async () => {
  const f = pageFixture(), pending = defer();
  f.config.get = () => pending.promise;
  const first = f.host.loadDetail(1);
  assert.equal(f.host.isLoading, true);
  await f.host.loadDetail(1);
  assert.equal(f.requests.length, 1);
  pending.resolve({ success: true, body: body(conversation()) });
  await first;
  assert.equal(f.host.isLoading, false);
  assert.deepEqual(contents(f.host), ['最初发送的正文']);
});

test('invalid IDs, invalid pages, and backward append targets never request server data', async () => {
  for (const mid of [0, -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '741123']) {
    const f = pageFixture();
    f.host.mid = mid;
    await f.host.loadDetail(1);
    assert.equal(f.requests.length, 0);
    assert.match(f.host.loadError, /编号/);
  }
  const f = pageFixture();
  for (const page of [0, -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '1']) await f.host.loadDetail(page);
  f.host.currentPage = 2;
  await f.host.loadDetail(1, true);
  await f.host.loadDetail(2, true);
  assert.equal(f.requests.length, 0);
});

test('unmounted and invalid-login pages cannot start a new detail request', async () => {
  const unmounted = pageFixture();
  unmounted.host.aboutToDisappear();
  await unmounted.host.loadDetail(1);
  assert.equal(unmounted.requests.length, 0);
  for (const change of [f => { f.config.loggedIn = false; }, f => { f.config.account = 'account-b'; }]) {
    const f = pageFixture();
    f.host.postList = parse(conversation()).posts;
    change(f);
    await f.host.loadDetail(1);
    assert.equal(f.requests.length, 0);
    assert.equal(f.host.postList.length, 0);
    assert.match(f.host.loadError, /登录|变化/);
  }
});

test('stale account, message ID, request version, or unmounted results never write page content', async () => {
  const changes = [
    f => { f.config.account = 'account-b'; },
    f => { f.config.loggedIn = false; },
    f => { f.host.mid = MID + 1; },
    f => { f.host.requestVersion++; },
    f => { f.host.activeAccountKey = 'account-b'; },
    f => { f.host.aboutToDisappear(); }
  ];
  for (const change of changes) {
    const f = pageFixture(), pending = defer();
    f.config.get = () => pending.promise;
    const request = f.host.loadDetail(1);
    change(f);
    pending.resolve({ success: true, body: body(conversation()) });
    await request;
    assert.equal(f.host.postList.length, 0);
    assert.equal(f.host.subject, '列表原始主题');
    assert.equal(f.host.currentPage, 0);
    assert.equal(f.host.loadError, '');
  }
});

test('an old request cannot overwrite or release the loading lock of a newer request', async () => {
  const f = pageFixture(), older = defer(), newer = defer();
  f.config.get = () => older.promise;
  const oldRequest = f.host.loadDetail(1);
  f.host.requestVersion++;
  f.host.isLoading = false;
  f.config.get = () => newer.promise;
  const newRequest = f.host.loadDetail(1);
  older.resolve({ success: true, body: body(conversation({ 0: post('过期正文') })) });
  await oldRequest;
  assert.equal(f.host.postList.length, 0);
  assert.equal(f.host.isLoading, true);
  newer.resolve({ success: true, body: body(conversation({ 0: post('最新正文') })) });
  await newRequest;
  assert.deepEqual(contents(f.host), ['最新正文']);
  assert.equal(f.host.isLoading, false);
});

test('returning under another account clears previously displayed private message content', async () => {
  const f = pageFixture();
  await f.host.loadDetail(1);
  assert.equal(f.host.postList.length, 1);
  f.config.account = 'account-b';
  f.host.onPageShow();
  assert.equal(f.host.postList.length, 0);
  assert.equal(f.host.subject, '');
  assert.equal(f.host.currentPage, 0);
  assert.equal(f.host.nextPage, 0);
  assert.equal(f.host.isLoading, false);
  assert.match(f.host.loadError, /账号|变化/);
});

'use strict';

/*
 * Run: node tools/test-message-reply.cjs
 * Execute actual MessageDetailPage methods extracted with the DevEco ETS AST
 * and the actual reply response parser. HTTP calls are local captures only;
 * no network, credentials, device access, or live messages are involved.
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

const replyModule = require('../entry/src/main/ets/model/MessageReplyParser.ets');
const { MessageReplyParser, NgaMessageReplyResult } = replyModule;
const { MessageDetailParser } = require('../entry/src/main/ets/model/MessageDetailParser.ets');
const { NgaMessagePost, NgaMessageDetailData } = require('../entry/src/main/ets/model/MessageDetailInfo.ets');

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
  const helpers = ast.statements.filter(node =>
    (ts.isClassDeclaration(node) && node !== component) || ts.isVariableStatement(node))
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
const DRAFT = '  你好\n[img]https://img.invalid/a.png[/img][s:ac:good]\n保留换行与首尾空格  ';
function detailBody(page = 1, overrides = {}) {
  return JSON.stringify({ data: { 0: {
    allmsgs: { 0: { id: String(91000 + page), subject: '会话主题', content: `第${page}页正文`,
      from: 42, time: 1791216000 } }, userInfo: { 42: { username: '发送者' } },
    currentPage: page, nextPage: 0, length: 1, ...overrides
  } } });
}
function defer() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

const ACK = JSON.stringify({ data: { 0: '发送完毕 ...' } });
const REJECTED = JSON.stringify({ data: { __MESSAGE: { 0: 1, 1: '该会话无法回复' } } });
const contents = host => Array.from(host.postList, item => item.content);
const clone = value => JSON.parse(JSON.stringify(value));

function pageFixture() {
  const requests = [], reads = [], toasts = [], encodings = [], timers = [], scrolls = [], backs = [], dialogs = [];
  const config = {
    account: 'account-a', loggedIn: true, hostContext: {},
    params: { mid: MID, subject: '会话主题' },
    encode: value => encodeURIComponent(value),
    toast() {},
    dialog: async () => ({ index: 0 }),
    post: async () => ({ success: true, statusCode: 200, body: ACK }),
    get: async url => ({ success: true, body: detailBody(Number(new URL(url).searchParams.get('page'))) })
  };
  const urls = realMethods('entry/src/main/ets/model/UrlBuilder.ets', 'UrlBuilder',
    ['buildMessageReadUrl', 'buildMessageReplyUrl'], {
      HttpClient: { getDomain: () => 'https://forum.invalid' }
    }, { static: true });
  const host = realMethods('entry/src/main/ets/pages/MessageDetailPage.ets', 'MessageDetailPage',
    ['sendReply', 'aboutToDisappear', 'onPageShow', 'navigateBack', 'confirmReplyNotSent'], {
      NgaMessagePost, NgaMessageDetailData, NgaMessageReplyResult, MessageReplyParser, MessageDetailParser,
      GbkEncoder: { encode(value) { encodings.push(value); return config.encode(value); } },
      setTimeout: callback => { timers.push(callback); return timers.length; }, Edge: { Bottom: 'bottom' },
      themeAccentTextColor: () => '#0960BD', COLOR_DAY_SUB: '#57616B', COLOR_NIGHT_SUB: '#B1BAC4',
      LoginStore: { hasUser: () => config.loggedIn, getUser: () => ({ uid: config.account }) },
      HttpClient: {
        post(url, fields, useGbk) {
          const request = { url, fields: clone(fields), useGbk };
          requests.push(request);
          return config.post(request);
        },
        get(url) { reads.push(url); return config.get(url); }
      },
      UrlBuilder: urls,
      SettingsStore: { getBool: () => false }, SettingKeys: { NIGHT: 'night' },
      SettingDefaults: { NIGHT: false }, applyWindowTheme() {},
      console: { info() {}, warn() {}, error() {} }
    });
  const original = MessageDetailParser.parse(detailBody(), MID, 1);
  assert.equal(original.success, true, original.errorMessage);
  Object.assign(host, { mounted: true, requestVersion: 0, sendVersion: 0,
    activeAccountKey: 'account-a', ctx: {}, mid: MID, subject: '会话主题',
    postList: original.posts, currentPage: 1, nextPage: 0,
    isLoading: false, loadError: '', loadMoreError: '', nightMode: false,
    replyText: DRAFT, isReplying: true, isSending: false, sendError: '', replyUncertain: false,
    refreshError: '', isRefreshing: false, uncertainReviewed: false, conversationInvalid: false,
    keyboardModeSet: false, messageScroller: { scrollEdge: edge => scrolls.push(edge) } });
  host.getUIContext = () => ({
    getHostContext: () => config.hostContext,
    getRouter: () => ({ getParams: () => config.params, back: () => backs.push(true) }),
    getPromptAction: () => ({ showToast: item => { toasts.push(clone(item)); config.toast(item); },
      showDialog: item => { dialogs.push(clone(item)); return config.dialog(item); } })
  });
  return { host, config, requests, reads, toasts, encodings, timers, scrolls, backs, dialogs };
}

test('the actual reply URL uses the configured NGA domain and nuke endpoint', () => {
  const urls = realMethods('entry/src/main/ets/model/UrlBuilder.ets', 'UrlBuilder',
    ['buildMessageReplyUrl'], { HttpClient: { getDomain: () => 'https://forum.invalid' } }, { static: true });
  assert.equal(urls.buildMessageReplyUrl(), 'https://forum.invalid/nuke.php');
});

test('blank replies never send, preserve their draft, and show actionable feedback', async () => {
  for (const draft of ['', '   ', '\t\n\r']) {
    const f = pageFixture();
    f.host.replyText = draft;
    await f.host.sendReply();
    assert.equal(f.requests.length, 0);
    assert.equal(f.reads.length, 0);
    assert.equal(f.host.replyText, draft);
    assert.equal(f.host.isSending, false);
    assert.ok(f.host.sendError.length > 0 || f.toasts.length > 0);
  }
});

test('invalid conversation IDs never send to another conversation', async () => {
  for (const mid of [0, -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '741123']) {
    const f = pageFixture();
    f.host.mid = mid;
    await f.host.sendReply();
    assert.equal(f.requests.length, 0, String(mid));
    assert.equal(f.reads.length, 0);
    assert.equal(f.host.replyText, DRAFT);
    assert.match(f.host.sendError, /编号|无效/);
    assert.equal(f.host.isSending, false);
  }
});

test('signed-out or changed accounts cannot submit the open private conversation', async () => {
  for (const change of [f => { f.config.loggedIn = false; }, f => { f.config.account = 'account-b'; }]) {
    const f = pageFixture();
    change(f);
    await f.host.sendReply();
    assert.equal(f.requests.length, 0);
    assert.equal(f.reads.length, 0);
    assert.equal(f.host.isSending, false);
    assert.match(f.host.sendError + f.host.loadError, /登录|账号|变化/);
  }
});

test('local GBK preflight failures remain definitely unsent and preserve the editable draft', async () => {
  const f = pageFixture();
  f.config.encode = () => { throw new Error('文本包含 GBK 不支持的字符'); };
  await f.host.sendReply();
  assert.equal(f.requests.length, 0);
  assert.equal(f.reads.length, 0);
  assert.equal(f.host.replyText, DRAFT);
  assert.equal(f.host.isReplying, true);
  assert.equal(f.host.isSending, false);
  assert.equal(f.host.replyUncertain, false);
  assert.match(f.host.sendError, /GBK|字符|编码/);
});

test('a real reply posts the exact GBK protocol and unmodified multiline BBCode draft', async () => {
  const f = pageFixture(), pending = defer();
  f.config.post = () => pending.promise;
  const operation = f.host.sendReply();
  assert.equal(f.host.isSending, true);
  assert.deepEqual(f.requests, [{ url: 'https://forum.invalid/nuke.php', useGbk: true, fields: {
    __lib: 'message', __act: 'message', lite: 'js', act: 'reply', mid: String(MID),
    to: '', subject: '', content: DRAFT
  } }]);
  assert.ok(f.encodings.includes(DRAFT), 'Encode the exact draft before initiating a potentially delivered POST');
  assert.equal(f.host.replyText, DRAFT);
  assert.deepEqual(contents(f.host), ['第1页正文']);
  await f.host.sendReply();
  assert.equal(f.requests.length, 1, 'Concurrent taps must share the sending lock');
  pending.resolve({ success: true, statusCode: 200, body: ACK });
  await operation;
  assert.equal(f.host.isSending, false);
});

test('explicit send rejection preserves the draft and original message without an automatic retry', async () => {
  const f = pageFixture();
  f.config.post = async () => ({ success: true, statusCode: 200, body: REJECTED });
  await f.host.sendReply();
  assert.equal(f.requests.length, 1);
  assert.equal(f.reads.length, 0);
  assert.equal(f.host.replyText, DRAFT);
  assert.deepEqual(contents(f.host), ['第1页正文']);
  assert.equal(f.host.replyUncertain, false);
  assert.match(f.host.sendError, /无法回复/);
  assert.equal(f.host.isSending, false);
});

test('after an explicit server rejection a user can deliberately retry the retained draft', async () => {
  const f = pageFixture();
  f.config.post = async () => ({ success: true, statusCode: 200, body: REJECTED });
  await f.host.sendReply();
  assert.equal(f.host.isSending, false);
  assert.equal(f.host.replyText, DRAFT);
  f.config.post = async () => ({ success: true, statusCode: 200, body: ACK });
  await f.host.sendReply();
  assert.equal(f.requests.length, 2);
  assert.equal(f.host.replyText, '');
  assert.equal(f.host.isReplying, false);
  assert.equal(f.host.sendError, '');
  assert.equal(f.host.replyUncertain, false);
  assert.equal(f.host.isSending, false);
});

test('unknown acknowledgements and transport failures retain drafts and block blind duplicate sends', async () => {
  for (const response of [
    { success: true, statusCode: 200, body: '{}' },
    { success: true, statusCode: 200, body: '{malformed' },
    { success: true, statusCode: 200, body: '' },
    { success: false, statusCode: 0, body: '', error: 'timeout' },
    { success: false, statusCode: 502, body: ACK, error: 'HTTP 502' }
  ]) {
    const f = pageFixture();
    f.config.post = async () => response;
    await f.host.sendReply();
    assert.equal(f.requests.length, 1);
    assert.equal(f.host.replyText, DRAFT);
    assert.equal(f.host.replyUncertain, true);
    assert.match(f.host.sendError, /未确认|确认|查看/);
    assert.equal(f.host.isSending, false);
    await f.host.sendReply();
    assert.equal(f.requests.length, 1, 'Uncertain results require a deliberate verification before another POST');
  }
});

test('a thrown transport error is uncertain and does not erase or automatically resend the draft', async () => {
  const f = pageFixture();
  f.config.post = async () => { throw new Error('测试超时'); };
  await f.host.sendReply();
  assert.equal(f.host.replyText, DRAFT);
  assert.equal(f.host.replyUncertain, true);
  assert.ok(f.host.sendError.length > 0);
  assert.equal(f.host.isSending, false);
  assert.equal(f.requests.length, 1);
});

test('unmounted pages do not initiate a reply', async () => {
  const f = pageFixture();
  f.host.aboutToDisappear();
  await f.host.sendReply();
  assert.equal(f.requests.length, 0);
});

test('confirmed success clears only the sent draft and refreshes the whole paginated conversation once', async () => {
  const f = pageFixture();
  f.host.currentPage = 2;
  f.config.get = async url => {
    const page = Number(new URL(url).searchParams.get('page'));
    return { success: true, body: detailBody(page, page === 1 ? { nextPage: 2 } : {
      allmsgs: { 0: { id: '91002', subject: '', content: DRAFT, from: 77, time: 1791216100 } },
      userInfo: { 77: { username: '当前用户' } }
    }) };
  };
  await f.host.sendReply();
  assert.equal(f.requests.length, 1);
  assert.deepEqual(f.reads.map(url => new URL(url).searchParams.get('page')), ['1', '2']);
  assert.deepEqual(contents(f.host), ['第1页正文', DRAFT]);
  assert.equal(f.host.replyText, '');
  assert.equal(f.host.replyUncertain, false);
  assert.equal(f.host.sendError, '');
  assert.equal(f.host.isSending, false);
  assert.equal(f.host.currentPage, 2);
  assert.equal(f.host.nextPage, 0);
  assert.ok(f.toasts.some(item => /已发送|发送成功/.test(item.message)));
  await f.host.sendReply();
  assert.equal(f.requests.length, 1, 'A second tap after success cannot resubmit the cleared draft');
});

test('a confirmed successful POST stays sent even when refreshing its later page fails', async () => {
  const f = pageFixture();
  f.host.postList = MessageDetailParser.parse(detailBody(1, { allmsgs: {
    0: { id: '91001', subject: '会话主题', content: '原始正文', from: 42 },
    1: { id: '91002', subject: '', content: '已显示的回复', from: 77 }
  } }), MID, 1).posts;
  const before = contents(f.host);
  f.config.get = async url => Number(new URL(url).searchParams.get('page')) === 1 ?
    { success: true, body: detailBody(1, { nextPage: 2 }) } :
    { success: false, body: '', error: 'offline' };
  await f.host.sendReply();
  assert.equal(f.requests.length, 1);
  assert.equal(f.host.replyText, '', 'A confirmed sent draft must not come back after a read failure');
  assert.equal(f.host.replyUncertain, false);
  assert.equal(f.host.isSending, false);
  assert.deepEqual(contents(f.host), before, 'Failed pagination refresh must retain the existing conversation');
  assert.ok(f.toasts.some(item => /已发送|发送成功/.test(item.message)));
  assert.ok(f.host.refreshError.length > 0 || f.host.loadMoreError.length > 0 ||
    f.host.loadError.length > 0 || f.host.sendError.length > 0);
});

test('malformed or wrong-page refresh responses cannot replace the existing original conversation', async () => {
  for (const response of [
    { success: true, body: '{not json' },
    { success: true, body: detailBody(2) },
    { success: false, body: '', error: 'offline' }
  ]) {
    const f = pageFixture(), before = contents(f.host);
    f.config.get = async () => response;
    await f.host.sendReply();
    assert.equal(f.requests.length, 1);
    assert.equal(f.host.replyText, '');
    assert.equal(f.host.replyUncertain, false);
    assert.equal(f.host.isSending, false);
    assert.equal(f.host.isRefreshing, false);
    assert.deepEqual(contents(f.host), before);
    assert.ok(f.host.refreshError.length > 0);
  }
});

test('refreshing after success deduplicates overlapping server IDs while keeping the initial body', async () => {
  const f = pageFixture();
  const original = { id: '91001', subject: '会话主题', content: '原始正文', from: 42 };
  const reply = { id: '91002', subject: '', content: '先前回复', from: 77 };
  f.config.get = async url => {
    const page = Number(new URL(url).searchParams.get('page'));
    return { success: true, body: detailBody(page, page === 1 ? {
      allmsgs: { 0: original, 1: reply }, nextPage: 2
    } : { allmsgs: { 0: reply, 1: { id: '91003', subject: '', content: DRAFT, from: 77 } } }) };
  };
  await f.host.sendReply();
  assert.deepEqual(contents(f.host), ['原始正文', '先前回复', DRAFT]);
  assert.equal(new Set(Array.from(f.host.postList, item => item.key)).size, 3);
  assert.equal(f.host.subject, '会话主题');
  assert.equal(f.host.replyText, '');
  assert.equal(f.host.isRefreshing, false);
});

test('an account change while refreshing a confirmed send discards the late private read', async () => {
  const f = pageFixture(), pending = defer();
  f.config.get = () => pending.promise;
  const operation = f.host.sendReply();
  await new Promise(setImmediate);
  assert.equal(f.reads.length, 1, 'The successful reply should have begun refreshing');
  f.config.account = 'account-b';
  f.host.onPageShow();
  pending.resolve({ success: true, body: detailBody() });
  await operation;
  assert.equal(f.host.replyText, '');
  assert.equal(f.host.postList.length, 0);
  assert.equal(f.host.currentPage, 0);
  assert.equal(f.host.nextPage, 0);
  assert.equal(f.host.isRefreshing, false);
  assert.match(f.host.loadError, /账号|变化/);
  assert.equal(f.reads.length, 1);
});

test('late POST acknowledgements after leaving, changing account, or changing conversation stay isolated', async () => {
  for (const change of [
    f => f.host.aboutToDisappear(),
    f => { f.config.account = 'account-b'; },
    f => { f.config.loggedIn = false; },
    f => { f.host.activeAccountKey = 'account-b'; },
    f => { f.host.mid = MID + 1; },
    f => { f.host.sendVersion++; }
  ]) {
    const f = pageFixture(), pending = defer();
    f.config.post = () => pending.promise;
    const operation = f.host.sendReply();
    assert.equal(f.requests.length, 1);
    change(f);
    pending.resolve({ success: true, statusCode: 200, body: ACK });
    await operation;
    assert.equal(f.reads.length, 0);
    assert.equal(f.toasts.length, 0);
    assert.equal(f.host.replyText, DRAFT);
    assert.deepEqual(contents(f.host), ['第1页正文']);
    assert.equal(f.host.sendError, '');
  }
});

test('an older send cannot clear a newer draft or release a newer sending lock', async () => {
  const f = pageFixture(), older = defer(), newer = defer();
  f.config.post = () => older.promise;
  const oldOperation = f.host.sendReply();
  f.host.sendVersion++;
  f.host.isSending = false;
  f.host.replyText = '新的回复草稿';
  f.config.post = () => newer.promise;
  const newOperation = f.host.sendReply();
  older.resolve({ success: true, statusCode: 200, body: ACK });
  await oldOperation;
  assert.equal(f.host.replyText, '新的回复草稿');
  assert.equal(f.host.isSending, true);
  assert.equal(f.reads.length, 0);
  newer.resolve({ success: true, statusCode: 200, body: ACK });
  await newOperation;
  assert.equal(f.host.replyText, '');
  assert.equal(f.host.isSending, false);
  assert.equal(f.requests.length, 2);
});

test('returning under another account clears the previous private reply draft and invalidates its late send', async () => {
  const f = pageFixture(), pending = defer();
  f.config.post = () => pending.promise;
  const operation = f.host.sendReply();
  f.config.account = 'account-b';
  f.host.onPageShow();
  assert.equal(f.host.replyText, '');
  assert.equal(f.host.postList.length, 0);
  assert.equal(f.host.isSending, false);
  assert.equal(f.host.replyUncertain, false);
  pending.resolve({ success: true, statusCode: 200, body: ACK });
  await operation;
  assert.equal(f.host.replyText, '');
  assert.equal(f.host.postList.length, 0);
  assert.equal(f.toasts.length, 0);
  assert.equal(f.reads.length, 0);
});

test('a local toast exception cannot turn an explicitly acknowledged send into an uncertain delivery', async () => {
  const f = pageFixture();
  f.config.toast = () => { throw new Error('测试UI异常'); };
  await f.host.sendReply();
  assert.equal(f.requests.length, 1);
  assert.equal(f.host.replyText, '');
  assert.equal(f.host.isReplying, false);
  assert.equal(f.host.replyUncertain, false);
  assert.equal(f.host.sendError, '');
  assert.ok(f.host.refreshError.length > 0);
  assert.equal(f.host.isSending, false);
  await f.host.sendReply();
  assert.equal(f.requests.length, 1);
});

test('checking an uncertain delivery only reads, preserves its draft, and requires deliberate retry confirmation', async () => {
  const f = pageFixture();
  f.config.post = async () => ({ success: true, statusCode: 200, body: '{}' });
  await f.host.sendReply();
  f.host.confirmReplyNotSent();
  assert.equal(f.host.replyUncertain, true, 'A user cannot confirm before reading the latest conversation');
  const refreshed = await f.host.refreshAfterReply();
  assert.equal(refreshed, true);
  assert.equal(f.requests.length, 1);
  assert.equal(f.reads.length, 1);
  assert.equal(f.host.uncertainReviewed, true);
  assert.equal(f.host.replyUncertain, true);
  assert.equal(f.host.replyText, DRAFT);
  await f.host.sendReply();
  assert.equal(f.requests.length, 1);
  f.host.confirmReplyNotSent();
  assert.equal(f.host.replyUncertain, false);
  assert.equal(f.host.uncertainReviewed, false);
  assert.equal(f.host.isReplying, true);
  assert.equal(f.host.replyText, DRAFT);
  assert.equal(f.host.sendError, '');
  f.config.post = async () => ({ success: true, statusCode: 200, body: ACK });
  await f.host.sendReply();
  assert.equal(f.requests.length, 2);
  assert.equal(f.host.replyText, '');
});

test('a failed uncertain-delivery check cannot unlock a blind resend', async () => {
  const f = pageFixture();
  f.config.post = async () => ({ success: false, body: '', error: 'timeout' });
  await f.host.sendReply();
  f.config.get = async () => ({ success: false, body: '', error: 'offline' });
  assert.equal(await f.host.refreshAfterReply(), false);
  f.host.confirmReplyNotSent();
  assert.equal(f.host.replyUncertain, true);
  assert.equal(f.host.uncertainReviewed, false);
  assert.equal(f.host.replyText, DRAFT);
  await f.host.sendReply();
  assert.equal(f.requests.length, 1);
});

test('a slow refresh after a confirmed send allows leaving and cannot write content afterward', async () => {
  const f = pageFixture(), pending = defer(), original = contents(f.host);
  f.config.get = () => pending.promise;
  const operation = f.host.sendReply();
  await new Promise(setImmediate);
  assert.equal(f.reads.length, 1);
  assert.equal(f.host.isSending, false, 'The send lock ends at acknowledgement');
  assert.equal(f.host.isRefreshing, true);
  await f.host.navigateBack();
  assert.equal(f.backs.length, 1);
  assert.equal(f.dialogs.length, 0);
  f.host.aboutToDisappear();
  pending.resolve({ success: true, body: detailBody(1, {
    allmsgs: { 0: { id: '91008', subject: '', content: '离开后的新正文', from: 77 } }
  }) });
  await operation;
  assert.deepEqual(contents(f.host), original);
  assert.equal(f.toasts.filter(item => /已更新/.test(item.message)).length, 0);
});

test('back closes the editor without losing its draft, then honors continue-editing or discard choices', async () => {
  const f = pageFixture();
  await f.host.navigateBack();
  assert.equal(f.host.isReplying, false);
  assert.equal(f.host.replyText, DRAFT);
  assert.equal(f.dialogs.length, 0);
  assert.equal(f.backs.length, 0);
  await f.host.navigateBack();
  assert.equal(f.dialogs.length, 1);
  assert.equal(f.host.isReplying, true);
  assert.equal(f.host.replyText, DRAFT);
  assert.equal(f.backs.length, 0);
  f.host.isReplying = false;
  f.config.dialog = async () => ({ index: 1 });
  await f.host.navigateBack();
  assert.equal(f.backs.length, 1);
});

test('back cannot discard or leave a reply still being sent', async () => {
  const f = pageFixture(), pending = defer();
  f.config.post = () => pending.promise;
  const operation = f.host.sendReply();
  await f.host.navigateBack();
  assert.equal(f.backs.length, 0);
  assert.equal(f.dialogs.length, 0);
  assert.equal(f.host.replyText, DRAFT);
  assert.ok(f.toasts.some(item => /正在发送/.test(item.message)));
  pending.resolve({ success: true, statusCode: 200, body: REJECTED });
  await operation;
});

test('scrolling to the latest reply also respects late timer account and lifecycle isolation', async () => {
  for (const change of [undefined, f => { f.config.account = 'account-b'; }, f => f.host.aboutToDisappear()]) {
    const f = pageFixture();
    await f.host.sendReply();
    assert.equal(f.timers.length, 1);
    if (change) change(f);
    f.timers[0]();
    assert.deepEqual(f.scrolls, change ? [] : ['bottom']);
  }
});

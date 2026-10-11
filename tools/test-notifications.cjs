'use strict';

/*
 * Run: node tools/test-notifications.cjs
 * Extracts real NotificationContent methods with the DevEco ETS parser and
 * loads real .ets models. All HTTP is mocked; no account, network, or device
 * access is performed, and server JavaScript is never evaluated.
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
const parserOptions = { ets: { components: Object.keys(componentMap.COMPONENT_MAP) } };

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
const { ReplyNotification, MessageNotification, NotificationData } = require('../entry/src/main/ets/model/NotificationInfo.ets');
const filePath = path.join(root, 'entry/src/main/ets/components/NotificationContent.ets');
const source = fs.readFileSync(filePath, 'utf8');
const ast = ts.createSourceFile(filePath, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, parserOptions);
assert.deepEqual(ast.parseDiagnostics.map(item => {
  const pos = ast.getLineAndCharacterOfPosition(item.start || 0);
  return `${pos.line + 1}:${pos.character + 1} ${ts.flattenDiagnosticMessageText(item.messageText, '\n')}`;
}), [], 'Real component must parse with the DevEco ETS parser');
const component = ast.statements.find(node => node.name && node.name.getText(ast) === 'NotificationContent');
assert.ok(component, 'NotificationContent');
const methods = new Map(component.members.filter(ts.isMethodDeclaration).map(method => [method.name.getText(ast), method]));
const resultClasses = ast.statements.filter(node => ts.isClassDeclaration(node) &&
  ['NotificationLoadResult', 'MessageLoadResult'].includes(node.name.getText(ast))).map(node => node.getText(ast)).join('\n');

function realMethods(names, globals) {
  const selected = new Map();
  function add(name) {
    if (selected.has(name)) return;
    const method = methods.get(name);
    assert.ok(method, `Missing actual component method ${name}`);
    selected.set(name, method);
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
  const result = ts.transpileModule(resultClasses + '\nclass RealContent {\n' +
    Array.from(selected.values(), method => method.getText(ast)).join('\n') +
    '\n}\nglobalThis.RealContent = RealContent;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true
  });
  const errors = (result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n'));
  const context = vm.createContext(globals);
  vm.runInContext(result.outputText, context);
  return new context.RealContent();
}

function fixture() {
  const requests = [];
  const config = { get: async () => ({ success: true, body: '{"data":{"0":{}}}', error: '' }) };
  const host = realMethods(['parseNotificationResult', 'parseMessageResult', 'responseInner', 'loadNotifications', 'loadMessages'], {
    NgaJsonParser, ReplyNotification, MessageNotification, NotificationData,
    HttpClient: { get(url) { requests.push(url); return config.get(); } },
    UrlBuilder: {
      buildNotificationUrl: () => 'https://forum.invalid/notifications',
      buildMessageListUrl: page => `https://forum.invalid/messages?page=${page}`
    },
    console: { info() {}, warn() {}, error() {} }
  });
  Object.assign(host, { mounted: true, active: true, loggedIn: true, accountKey: 'account-a',
    requestVersion: 0, isLoading: false, loadError: '', unread: 0,
    replyList: [], messageList: [], msgPage: 1, nextMessagePage: 2, msgHasMore: true,
    messagesLoaded: false });
  return { host, config, requests };
}
const textBody = data => typeof data === 'string' ? data : JSON.stringify(data);
const reply = (tid = 123, overrides = {}) => ({ 0: '1', 1: '42', 2: '回复者', 5: '话题标题',
  6: String(tid), 7: '98765', 9: '1791216000', ...overrides });
const message = (mid = 12, overrides = {}) => ({ mid: String(mid), subject: '短消息主题',
  from_username: '发送者', last_from_username: '最后回复者', time: '1791216000',
  last_modify: '1791216001', posts: '3', ...overrides });
function parsers(body) {
  const host = fixture().host;
  const raw = textBody(body);
  return [host.parseNotificationResult(raw), host.parseMessageResult(raw)];
}
function failure(result, expected) {
  assert.equal(result.success, false);
  assert.ok(result.error.length > 0, 'A malformed response must retain a visible error');
  if (expected) assert.match(result.error, expected);
}

test('real reply models map NGA indexed fields, sparse row order, unread count, and legacy pid index', () => {
  const result = fixture().host.parseNotificationResult(textBody({ data: { 0: {
    unread: '2', 0: { 10: reply(300), 2: reply(200, { 7: undefined, 8: '456' }), 0: reply(100) },
    1: { 0: { 0: 'private-message-reminder' } }
  } } }));
  assert.equal(result.success, true, result.error);
  assert.equal(result.data.unread, 2);
  assert.deepEqual(Array.from(result.data.replyList, item => item.tid), [100, 200, 300]);
  const first = result.data.replyList[0];
  assert.ok(first instanceof ReplyNotification);
  assert.deepEqual([first.type, first.userId, first.userName, first.title, first.pid, first.timeStamp],
    [1, 42, '回复者', '话题标题', 98765, 1791216000]);
  assert.equal(result.data.replyList[1].pid, 456);
});

test('reply reminders accept data.0 object or array payloads and actual arrays of indexed rows', () => {
  for (const body of [{ data: { 0: { 0: [reply(100)], unread: 1 } } },
    { data: [{ 0: [reply(100)], unread: 1 }] },
    { data: [[[reply(100)], []]] }, { data: { 0: [[reply(100)], []] } }]) {
    const result = fixture().host.parseNotificationResult(textBody(body));
    assert.equal(result.success, true, result.error);
    assert.equal(result.data.replyList.length, 1);
    assert.equal(result.data.replyList[0].tid, 100);
  }
});

test('message lists accept object or array data.0 payloads inside object or array outer data', () => {
  for (const payload of [{ 0: message(11), 2: message(22), 10: message(33), nextPage: '4' },
    [message(11), message(22), message(33)]]) {
    for (const data of [[payload], { 0: payload }]) {
      const result = fixture().host.parseMessageResult(textBody({ data }));
      assert.equal(result.success, true, result.error);
      assert.deepEqual(Array.from(result.messages, item => item.mid), [11, 22, 33]);
      const first = result.messages[0];
      assert.ok(first instanceof MessageNotification);
      assert.deepEqual([first.subject, first.fromUserName, first.lastFromUserName, first.time, first.lastModify, first.posts],
        ['短消息主题', '发送者', '最后回复者', 1791216000, 1791216001, 3]);
      assert.equal(result.hasPagination, !Array.isArray(payload));
      assert.equal(result.nextPage, Array.isArray(payload) ? 0 : 4);
    }
  }
});

test('valid empty object and array payloads are successful empty states in both tabs', () => {
  for (const body of [{ data: [{}] }, { data: [[]] }, { data: { 0: {} } }, { data: { 0: [] } }]) {
    const [notices, messages] = parsers(body);
    assert.equal(notices.success, true, `${textBody(body)}: ${notices.error}`);
    assert.equal(messages.success, true, `${textBody(body)}: ${messages.error}`);
    assert.equal(notices.data.replyList.length, 0);
    assert.equal(messages.messages.length, 0);
  }
  const result = fixture().host.parseMessageResult('{"data":{"0":{"nextPage":0}}}');
  assert.equal(result.success, true, result.error);
  assert.equal(result.hasPagination, true);
  assert.equal(result.nextPage, 0);
});

test('missing, null, scalar, or invalid data containers stay visible as errors', () => {
  for (const body of ['', '[]', '{}', 'null', '{"unrelated":{}}', '{"data":{}}', '{"data":[]}', '{"data":null}',
    '{"data":true}', '{"data":1}', '{"data":""}', '{"data":{"0":null}}',
    '{"data":{"0":7}}', '{"data":{"0":"invalid"}}']) {
    for (const result of parsers(body)) failure(result);
  }
});

test('explicit empty and whitespace status strings are valid empty responses without accepting absent data.0', () => {
  for (const body of [{ data: { 0: '' } }, { data: [''] },
    { data: { 0: ' \t\n ' } }, { data: [' \t\n '] }]) {
    const [notices, messages] = parsers(body);
    assert.equal(notices.success, true, `${textBody(body)}: ${notices.error}`);
    assert.equal(messages.success, true, `${textBody(body)}: ${messages.error}`);
    assert.equal(notices.data.replyList.length, 0);
    assert.equal(notices.data.unread, 0);
    assert.equal(messages.messages.length, 0);
    assert.equal(messages.hasPagination, false);
  }
  for (const body of [{ data: {} }, { data: [] }, { data: { 0: null } }]) {
    for (const result of parsers(body)) failure(result);
  }
});

test('nonempty malformed rows do not collapse into a successful empty state', () => {
  failure(fixture().host.parseNotificationResult('{"data":{"0":{"0":[null,{},"wrong"]}}}'));
  failure(fixture().host.parseMessageResult('{"data":{"0":[null,{},"wrong"]}}'));
  failure(fixture().host.parseNotificationResult('{"data":{"0":{"0":7}}}'));
});

test('server login and endpoint errors remain visible in both message tabs', () => {
  for (const body of [{ error: ['<b>请先登录</b>'] },
    { data: { error: { 0: '<b>登录信息已过期</b>' }, 0: {} } },
    { data: { __MESSAGE: ['ERROR', '<b>接口权限不足</b>'], 0: {} } }]) {
    for (const result of parsers(body)) failure(result, /登录|权限/);
  }
});

test('string payloads outside the explicit empty-status vocabulary preserve server hints as errors', () => {
  for (const text of ['没有权限读取消息', '<b>登录状态已失效</b>', '暂无回复提醒，但是接口权限不足']) {
    for (const result of parsers({ data: { 0: text } })) {
      failure(result);
      assert.equal(result.error, text.replace(/<[^>]*>/g, '').trim());
    }
  }
});

test('known wrappers and markers preserve valid lists through the shared response parser', () => {
  const json = textBody({ data: { 0: { 0: message(), nextPage: 0 } } });
  for (const raw of [json, 'window.script_muti_get_var_store=' + json + ';',
    '\uFEFF /*$js$*/ window.script_muti_get_var_store= /*$js$*/ ' + json + ' /*$js$*/; ',
    '/*$js$*/' + json + ';/*$js$*/']) {
    const result = fixture().host.parseMessageResult(raw);
    assert.equal(result.success, true, result.error);
    assert.equal(result.messages[0].mid, 12);
  }
});

test('raw TAB and newline inside real NGA strings are repaired without changing their text', () => {
  const raw = '{"data":{"0":{"0":{"mid":12,"subject":"第一行\t末尾\n第二行","from_username":"发送者"},"nextPage":0}}}';
  const result = fixture().host.parseMessageResult('window.script_muti_get_var_store=' + raw);
  assert.equal(result.success, true, result.error);
  assert.equal(result.messages[0].subject, '第一行\t末尾\n第二行');
});

test('known NGA error-fill tail is removed only after the completed JSON payload', () => {
  const json = textBody({ data: { 0: { 0: message() } } });
  for (const body of [json + '/*error fill content',
    '/*$js$*/window.script_muti_get_var_store=' + json + ';/*$js$*//*error fill content diagnostic padding */']) {
    const result = fixture().host.parseMessageResult(body);
    assert.equal(result.success, true, result.error);
    assert.equal(result.messages[0].mid, 12);
  }
});

test('unquoted +digits in subject and content become text, including the final object field', () => {
  const parsed = NgaJsonParser.parseResponseObject('{"data":{"0":{"mid":12,"subject":+123,"content":+456}}}');
  assert.equal(parsed.data['0'].subject, '+123');
  assert.equal(parsed.data['0'].content, '+456');
  const result = fixture().host.parseMessageResult('{"data":{"0":{"0":{"mid":12,"subject":+123}}}}');
  assert.equal(result.success, true, result.error);
  assert.equal(result.messages[0].subject, '+123');
});

test('markers and +digits inside quoted strings retain their literal text', () => {
  const subject = '原样 /*$js$*/ /*error fill content +123; window.script_muti_get_var_store= \\"subject\\":+456';
  const raw = textBody({ data: { 0: { 0: message(12, { subject, content: '正文 +789' }) } } });
  const parsed = NgaJsonParser.parseResponseObject(raw);
  assert.equal(parsed.data['0']['0'].subject, subject);
  assert.equal(parsed.data['0']['0'].content, '正文 +789');
  const result = fixture().host.parseMessageResult(raw);
  assert.equal(result.success, true, result.error);
  assert.equal(result.messages[0].subject, subject);
});

test('unknown JavaScript, executable suffixes, and invalid +expressions are rejected without execution', () => {
  const json = textBody({ data: { 0: { 0: message() } } });
  globalThis.ngaNotificationTestExecuted = false;
  try {
    for (const body of ['unknown=' + json, json + ';globalThis.ngaNotificationTestExecuted=true',
      '(globalThis.ngaNotificationTestExecuted=true,' + json + ')',
      json + ';globalThis.ngaNotificationTestExecuted=true;/*error fill content',
      json + '/*error fill content padding */;globalThis.ngaNotificationTestExecuted=true',
      json + '/*error fill content padding */<html>unknown content</html>',
      '{"data":{"0":{"mid":12,"subject":+123+456}}}',
      '{"data":{"0":{"mid":+12,"subject":"标识符不应修复"}}}']) {
      for (const result of parsers(body)) failure(result);
      assert.equal(globalThis.ngaNotificationTestExecuted, false);
    }
  } finally {
    delete globalThis.ngaNotificationTestExecuted;
  }
});

test('notification loader uses parsed data and clears loading after success', async () => {
  const f = fixture();
  f.config.get = async () => ({ success: true, body: textBody({ data: { 0: { 0: [reply()], unread: '5' } } }), error: '' });
  await f.host.loadNotifications();
  assert.deepEqual(f.requests, ['https://forum.invalid/notifications']);
  assert.equal(f.host.replyList[0].tid, 123);
  assert.equal(f.host.unread, 5);
  assert.equal(f.host.loadError, '');
  assert.equal(f.host.isLoading, false);
});

test('message loader replaces first-page rows, appends later rows, and honors nextPage metadata', async () => {
  const f = fixture();
  f.host.messageList = [message(999)];
  f.config.get = async () => ({ success: true, body: textBody({ data: { 0: { 0: message(11), nextPage: 4 } } }), error: '' });
  await f.host.loadMessages(1);
  assert.deepEqual(Array.from(f.host.messageList, item => item.mid), [11]);
  assert.equal(f.host.nextMessagePage, 4);
  assert.equal(f.host.msgPage, 1);
  assert.equal(f.host.msgHasMore, true);
  f.config.get = async () => ({ success: true, body: textBody({ data: { 0: { 0: message(22), nextPage: 0 } } }), error: '' });
  await f.host.loadMessages(4);
  assert.deepEqual(Array.from(f.host.messageList, item => item.mid), [11, 22]);
  assert.equal(f.host.msgPage, 4);
  assert.equal(f.host.msgHasMore, false);
  assert.equal(f.host.messagesLoaded, true);
  assert.equal(f.host.isLoading, false);
  assert.deepEqual(f.requests, ['https://forum.invalid/messages?page=1', 'https://forum.invalid/messages?page=4']);
});

test('both loaders expose server and transport errors while retaining loaded rows', async () => {
  for (const loader of ['loadNotifications', 'loadMessages']) {
    for (const response of [{ success: true, body: '{"error":["登录信息已过期"]}', error: '' },
      { success: false, body: '', error: '网络不可用' }]) {
      const f = fixture();
      const oldReply = new ReplyNotification(), oldMessage = new MessageNotification();
      f.host.replyList = [oldReply]; f.host.messageList = [oldMessage];
      f.config.get = async () => response;
      await f.host[loader](1);
      assert.match(f.host.loadError, /登录信息已过期|网络不可用/);
      assert.equal(f.host.isLoading, false);
      assert.equal(f.host.replyList[0], oldReply);
      assert.equal(f.host.messageList[0], oldMessage);
    }
  }
});

test('both loaders catch rejected requests, expose an error, and release loading', async () => {
  for (const loader of ['loadNotifications', 'loadMessages']) {
    const f = fixture();
    f.config.get = async () => { throw new Error('测试网络异常'); };
    await f.host[loader](1);
    assert.equal(f.host.isLoading, false);
    assert.ok(f.host.loadError.length > 0);
  }
});

test('inactive or logged-out tabs never start either loader', async () => {
  for (const loader of ['loadNotifications', 'loadMessages']) {
    for (const state of [{ active: false }, { loggedIn: false }]) {
      const f = fixture(); Object.assign(f.host, state);
      await f.host[loader](1);
      assert.equal(f.requests.length, 0);
      assert.equal(f.host.isLoading, false);
    }
  }
});

test('results and failures from an old account or inactive/unmounted tab cannot alter current data', async () => {
  for (const loader of ['loadNotifications', 'loadMessages']) {
    for (const change of [{ accountKey: 'account-b' }, { active: false }, { mounted: false }]) {
      for (const rejected of [false, true]) {
        const f = fixture(); let resolve, reject;
        f.config.get = () => new Promise((done, fail) => { resolve = done; reject = fail; });
        const pending = f.host[loader](1);
        Object.assign(f.host, change, { isLoading: false, loadError: '当前页提示' });
        f.host.replyList = []; f.host.messageList = [];
        if (rejected) reject(new Error('旧账号异常'));
        else resolve({ success: true, body: textBody({ data: { 0: [reply()], unread: 2 } }), error: '' });
        await pending;
        assert.equal(f.host.replyList.length, 0);
        assert.equal(f.host.messageList.length, 0);
        assert.equal(f.host.loadError, '当前页提示');
        assert.equal(f.host.isLoading, false);
      }
    }
  }
});

test('completion or rejection of a superseded request does not release the newer loading state', async () => {
  for (const loader of ['loadNotifications', 'loadMessages']) {
    for (const rejected of [false, true]) {
      const f = fixture(); const resolvers = [], rejecters = [];
      f.config.get = () => new Promise((resolve, reject) => { resolvers.push(resolve); rejecters.push(reject); });
      const first = f.host[loader](1);
      const second = f.host[loader](1);
      assert.equal(f.requests.length, 2);
      if (rejected) rejecters[0](new Error('过期请求异常'));
      else resolvers[0]({ success: true, body: '{"data":{"0":{}}}', error: '' });
      await first;
      assert.equal(f.host.isLoading, true);
      assert.equal(f.host.loadError, '');
      resolvers[1]({ success: true, body: '{"data":{"0":{}}}', error: '' });
      await second;
      assert.equal(f.host.isLoading, false);
      assert.equal(f.host.loadError, '');
    }
  }
});

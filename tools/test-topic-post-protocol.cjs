'use strict';

/* Run: node --test tools/test-topic-post-protocol.cjs
 * Exercise real ArkTS protocol/parser/HTTP encoding with the DevEco compiler.
 * Native APIs and persisted login are mocks. No network or real post is sent.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { TextDecoder } = require('node:util');
const { test } = require('node:test');

const devecoHome = process.env.DEVECO_HOME || 'D:/software/DevEco Studio';
const compilerPath = process.env.TYPESCRIPT_PATH || path.join(devecoHome,
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
assert.ok(fs.existsSync(compilerPath), 'Set DEVECO_HOME or TYPESCRIPT_PATH to the DevEco SDK compiler');
const ts = require(compilerPath);
const modelRoot = path.resolve(__dirname, '../entry/src/main/ets/model');
const requests = [];
const nativeHttp = {
  RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { ARRAY_BUFFER: 2 },
  createHttp() {
    return {
      async request(url, options) {
        requests.push({ url, options });
        assert.notEqual(options.extraData, '', 'Native HTTP rejects an empty string extraData');
        const bytes = Buffer.from('{}');
        return { responseCode: 200, header: { 'content-type': 'text/plain; charset=utf-8' },
          result: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) };
      }, destroy() {}
    };
  }
};
const nativeUtil = {
  TextEncoder: class {
    constructor(encoding) { assert.equal(encoding, 'gbk'); }
    encodeInto(input) {
      const bytes = [];
      for (const char of input) {
        if (char.codePointAt(0) < 0x80) bytes.push(char.codePointAt(0));
        else if (char === '中') bytes.push(0xD6, 0xD0);
        else if (char === '文') bytes.push(0xCE, 0xC4);
        else bytes.push(0x3f);
      }
      return new Uint8Array(bytes);
    }
  },
  TextDecoder: { create(encoding) {
    const decoder = new TextDecoder(encoding);
    return { decodeToString(bytes, options) { return decoder.decode(bytes, options); } };
  } }
};
const mocks = {
  '@ohos.net.http': { default: nativeHttp }, '@ohos.util': { default: nativeUtil },
  '@kit.ArkTS': { util: nativeUtil }, './LoginStore': { LoginStore: { getCookie: () => 'test=1' } },
  './AppSettings': { SettingsStore: { getInt: () => 1 }, SettingKeys: { DOMAIN: 'domain' },
    SettingDefaults: { DOMAIN: 1 } }
};
const cache = new Map();
function load(name) {
  if (cache.has(name)) return cache.get(name).exports;
  const filename = path.join(modelRoot, name + '.ets');
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  const errors = (output.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
  assert.deepEqual(errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
  const module = { exports: {} };
  cache.set(name, module);
  const localRequire = id => {
    if (Object.hasOwn(mocks, id)) return mocks[id];
    if (id.startsWith('./')) return load(id.slice(2));
    throw new Error('Unexpected ETS dependency: ' + id);
  };
  const evaluate = vm.runInThisContext('(function(require, module, exports) {\n' +
    output.outputText + '\n})', { filename });
  evaluate(localRequire, module, module.exports);
  return module.exports;
}
const { NgaTopicPostInput, TopicPostProtocol } = load('TopicPostProtocol');
const { NgaTopicPostPreparation, NgaTopicPostResult, TopicPostParser } = load('TopicPostParser');
const { HttpClient } = load('HttpClient');
const input = fields => Object.assign(new NgaTopicPostInput(), {
  fid: -7, subject: '标题', content: '正文', ...fields
});
const ack = (text = '发贴完毕 ...', fields = {}) => JSON.stringify({ data: {
  __MESSAGE: { 0: 0, 1: text }, ...fields
} });
const html = text => `<html><span style='color:#aaa'>&gt;</span>${text}<br/></html>`;
const prep = fields => JSON.stringify({ data: { auth: 'mock-attachment-auth', fid: -7, ...fields } });
function success(body, tid = 0) {
  const result = TopicPostParser.parseSubmit(body);
  assert.ok(result instanceof NgaTopicPostResult);
  assert.deepEqual([result.success, result.uncertain, result.errorMessage, result.tid], [true, false, '', tid]);
}
function uncertain(body) {
  const result = TopicPostParser.parseSubmit(body);
  assert.deepEqual([result.success, result.uncertain, result.tid], [false, true, 0]);
  assert.match(result.errorMessage, /未确认/);
}
function rejected(body, text) {
  const result = TopicPostParser.parseSubmit(body);
  assert.deepEqual([result.success, result.uncertain, result.tid], [false, false, 0]);
  assert.ok(result.errorMessage.length > 0);
  if (text) assert.equal(result.errorMessage, text);
}

test('models start with safe unpublished defaults', () => {
  const post = new NgaTopicPostInput();
  assert.deepEqual([post.action, post.fid, post.stid, post.tid, post.pid, post.anonymous], ['new', 0, 0, 0, 0, false]);
  assert.equal(new NgaTopicPostPreparation().success, false);
  assert.equal(new NgaTopicPostResult().success, false);
});

test('normal, negative-fid, and stid-only board inputs are valid', () => {
  for (const board of [{ fid: -7 }, { fid: 123 }, { fid: 0, stid: 555 }]) {
    assert.equal(TopicPostProtocol.validate(input(board)), '');
  }
});

test('missing or unsafe board context and actions fail validation', () => {
  for (const fields of [{ fid: 0 }, { fid: NaN }, { fid: 1.5 }, { stid: -1 },
    { stid: Infinity }, { tid: -1 }, { pid: Number.MAX_SAFE_INTEGER + 1 }, { action: 'delete' }]) {
    assert.ok(TopicPostProtocol.validate(input(fields)).length > 0, JSON.stringify(fields));
  }
});

test('blank new titles and blank bodies fail without rewriting drafts', () => {
  for (const blank of ['', ' ', '\n\r\t']) {
    const title = input({ subject: blank });
    assert.match(TopicPostProtocol.validate(title), /标题/);
    assert.equal(title.subject, blank);
    const content = input({ content: blank });
    assert.match(TopicPostProtocol.validate(content), /内容/);
    assert.equal(content.content, blank);
  }
});

test('reply and modify require tid, allow an empty subject, and preserve pid', () => {
  for (const action of ['reply', 'modify']) {
    assert.match(TopicPostProtocol.validate(input({ action, subject: '' })), /话题/);
    const post = input({ action, subject: '', tid: 321, pid: 654 });
    assert.equal(TopicPostProtocol.validate(post), '');
    assert.deepEqual(TopicPostProtocol.buildFields(post), {
      step: '2', post_content: '正文', action, fid: '-7', tid: '321', pid: '654'
    });
  }
});

test('prepare URL mirrors Android including negative fid and optional pid tid stid', () => {
  assert.equal(TopicPostProtocol.buildPrepareUrl(input()), 'https://bbs.nga.cn/post.php?fid=-7&lite=js&action=new');
  assert.equal(TopicPostProtocol.buildPrepareUrl(input({ action: 'reply', fid: 0, stid: 555, tid: 321, pid: 654 })),
    'https://bbs.nga.cn/post.php?fid=0&lite=js&action=reply&pid=654&tid=321&stid=555');
});

test('new post fields preserve raw drafts, negative fid, stid, and optional anonymity', () => {
  const post = input({ stid: 555, subject: '  [分类] 中文 %20  ', content: '\n中文 &%=+ [s:ac:good]\n',
    tid: 999, pid: 888 });
  assert.deepEqual(TopicPostProtocol.buildFields(post), {
    step: '2', post_content: post.content, action: 'new', post_subject: post.subject, fid: '-7', stid: '555'
  });
  post.fid = 0;
  post.anonymous = true;
  assert.deepEqual(TopicPostProtocol.buildFields(post), {
    step: '2', post_content: post.content, action: 'new', post_subject: post.subject, stid: '555', anony: '1'
  });
});

test('real HTTP client encodes raw fields exactly once and omits extraData for empty preparation', async () => {
  requests.length = 0;
  const post = input({ subject: '中文 %20', content: '中文 &%=+ [s:ac:good]' });
  await HttpClient.post(TopicPostProtocol.buildPrepareUrl(post), {}, true);
  assert.equal(Object.hasOwn(requests[0].options, 'extraData'), false);
  assert.equal(requests[0].options.header['Content-Length'], '0');
  await HttpClient.post('https://bbs.nga.cn/post.php', TopicPostProtocol.buildFields(post), true);
  assert.equal(Object.hasOwn(requests[1].options.header, 'Content-Length'), false);
  assert.equal(requests[1].options.extraData,
    'step=2&post_content=%D6%D0%CE%C4+%26%25%3D%2B+%5Bs%3Aac%3Agood%5D&action=new&post_subject=%D6%D0%CE%C4+%2520&fid=-7');
  assert.ok(!requests[1].options.extraData.includes('auth='));
});

test('HTTP diagnostics distinguish request failure from HTTP rejection and decoding failure', async () => {
  const originalCreate = nativeHttp.createHttp;
  let destroyed = 0;
  try {
    nativeHttp.createHttp = () => ({
      async request() { throw Object.assign(new Error('fixture secret-bearing raw message'), { code: 2300028 }); },
      destroy() { destroyed++; }
    });
    const timeout = await HttpClient.post('https://bbs.nga.cn/post.php?lite=js', {});
    assert.deepEqual([timeout.success, timeout.statusCode, timeout.failureStage, timeout.nativeErrorCode],
      [false, 0, 'request', 2300028]);
    nativeHttp.createHttp = () => ({
      async request() { return { responseCode: 403, header: {}, result: 'fixture rejection' }; },
      destroy() { destroyed++; }
    });
    const rejection = await HttpClient.post('https://bbs.nga.cn/post.php?lite=js', {});
    assert.deepEqual([rejection.success, rejection.statusCode, rejection.failureStage, rejection.nativeErrorCode],
      [false, 403, 'http', 0]);
    nativeHttp.createHttp = () => ({
      async request() { return { responseCode: 200, header: {}, result: { fixture: true } }; },
      destroy() { destroyed++; }
    });
    const badBody = await HttpClient.post('https://bbs.nga.cn/post.php?lite=js', {});
    assert.deepEqual([badBody.success, badBody.statusCode, badBody.failureStage, badBody.nativeErrorCode],
      [false, 200, 'decode', 0]);
    assert.equal(destroyed, 3);
  } finally {
    nativeHttp.createHttp = originalCreate;
  }
});

test('preparation accepts known auth structure and known JSON wrappers', () => {
  for (const body of [prep(), '/*$js$*/window.script_muti_get_var_store=' + prep() + ';/*error fill content padding*/']) {
    const result = TopicPostParser.parsePreparation(body, -7, 0);
    assert.deepEqual([result.success, result.errorMessage, result.fid, result.stid], [true, '', -7, 0]);
    assert.equal(Object.hasOwn(result, 'auth'), false);
  }
});

test('stid-only preparation preserves child and resolves actual nonzero fid when supplied', () => {
  for (const fields of [{ fid: -7, stid: '555' }, { fid: 0, __F: { fid: '-7' } }, { fid: 0 }]) {
    const result = TopicPostParser.parsePreparation(prep(fields), 0, 555);
    assert.equal(result.success, true, result.errorMessage);
    assert.equal(result.stid, 555);
    assert.equal(result.fid, fields.fid === 0 && !fields.__F ? 0 : -7);
  }
});

test('preparation rejects unexpected board changes and malformed contexts', () => {
  for (const [fields, fid, stid] of [[{ fid: 123 }, -7, 0], [{ stid: 555 }, -7, 0],
    [{ stid: 556 }, -7, 555], [{ fid: 'abc' }, -7, 0], [{ stid: '1.5' }, -7, 555],
    [{ fid: -7, __F: { fid: 123 } }, 0, 555]]) {
    const result = TopicPostParser.parsePreparation(prep(fields), fid, stid);
    assert.equal(result.success, false);
    assert.match(result.errorMessage, /信息不一致/);
  }
});

test('preparation errors override both auth and matching board context', () => {
  for (const body of [JSON.stringify({ error: '未登录', data: { auth: 'mock-auth', fid: -7 } }),
    prep({ __MESSAGE: { 0: 1, 1: '没有发帖权限' } }), prep({ __MESSAGE: { 0: 0, 1: '请先登录' } }),
    prep({ error_code: 403 }), prep({ 0: '没有发帖权限' }), '{}', '<html>未登录</html>', '']) {
    const result = TopicPostParser.parsePreparation(body, -7, 0);
    assert.equal(result.success, false);
    assert.ok(result.errorMessage.length > 0);
  }
});

test('explicit HTML, root/nested JSON, and indexed array acknowledgements succeed', () => {
  for (const body of [html('发贴完毕'), html('<b>发帖完毕</b> ...'), ack(),
    JSON.stringify({ __MESSAGE: { 0: '0', 1: ' 发贴完毕！ ' } }),
    JSON.stringify({ data: { __MESSAGE: [0, '发贴完毕 ...'] } }),
    JSON.stringify({ data: ['发贴完毕 ...'] }),
    'window.script_muti_get_var_store=' + ack() + ';']) success(body);
});

test('HTML and JSON feedback expose only their own safe numeric NGA topic links', () => {
  const fragment = '发贴完毕 ... <a href="/read.php?page=1&amp;tid=321">查看帖子</a>';
  success(html(fragment), 321);
  success(ack(fragment), 321);
  success(ack('发贴完毕 ... <a href="https://bbs.ngacn.cc/read.php?tid=321#pid0">查看</a>'), 321);
  success(html('发贴完毕 ...') + '<a href="read.php?tid=999">无关链接</a>', 0);
});

test('unsafe, conflicting, duplicate, and malformed topic links do not expose a tid', () => {
  for (const target of ['javascript:read.php?tid=321', 'https://evil.invalid/read.php?tid=321',
    'https://bbs.nga.cn.evil.invalid/read.php?tid=321', 'read.php?tid=321x', 'read.php?tid=-321',
    'read.php?tid=9007199254740992', 'read.php?tid=321&tid=654', 'other.php?tid=321']) {
    success(ack(`发贴完毕 ... <a href="${target}">查看</a>`), 0);
  }
  success(ack('发贴完毕 ... <a href="read.php?tid=321">甲</a><a href="read.php?tid=654">乙</a>'), 0);
});

test('errors at every JSON status level override apparent success', () => {
  for (const body of [JSON.stringify({ error: { 0: '未登录' }, data: { __MESSAGE: { 0: 0, 1: '发贴完毕' } } }),
    ack('发贴完毕', { error: '无发帖权限' }), ack('发贴完毕', { __ERROR: true }),
    ack('发贴完毕', { error_code: 403 }),
    JSON.stringify({ data: { __MESSAGE: { 0: 1, 1: '发贴完毕' } } }),
    JSON.stringify({ data: { __MESSAGE: { 0: 0, 1: '发贴完毕', 3: '403' } } }),
    ack('发贴完毕', { 0: '请先登录' })]) rejected(body);
  rejected(ack('标题不能为空'), '标题不能为空');
  rejected(html('发帖失败'), '发帖失败');
  rejected(html('发贴完毕') + html('没有发帖权限'), '没有发帖权限');
});

test('empty, unknown, incidental, and fake success feedback remain unconfirmed', () => {
  for (const body of ['', '{}', 'not JSON', ack('操作成功'), ack('发贴完毕率低'), ack('未发贴完毕'),
    ack('正文中提到发贴完毕'), ack('@提醒每24小时不能超过50个'),
    '<html>发贴完毕</html>', 'example: ' + html('发贴完毕'), '{broken:' + html('发贴完毕'), '<script>' + html('发贴完毕') + '</script>',
    '<!--' + html('发贴完毕') + '-->', '<pre>' + html('发贴完毕') + '</pre>',
    '<blockquote>' + html('发贴完毕') + '</blockquote>',
    JSON.stringify({ __MESSAGE: {}, data: { 0: '发贴完毕' } })]) uncertain(body);
});

test('explicit failure text cannot be hidden inside an apparent acknowledgement', () => {
  rejected(ack('发贴完毕 ... 发帖失败'));
  rejected(html('发贴完毕 ... 操作失败'));
});

test('unencodable GBK drafts are rejected before the native HTTP request', async () => {
  requests.length = 0;
  const result = await HttpClient.post('https://bbs.nga.cn/post.php',
    TopicPostProtocol.buildFields(input({ subject: '中文', content: '中文😀' })), true);
  assert.equal(result.success, false);
  assert.match(result.error, /GBK/);
  assert.equal(requests.length, 0);
});

test('a reply with a known tid can prepare while its board fid is still unknown', () => {
  const post = input({ action: 'reply', fid: 0, stid: 0, tid: 321, subject: '' });
  assert.equal(TopicPostProtocol.validate(post), '');
  const result = TopicPostParser.parsePreparation(prep(), post.fid, post.stid);
  assert.deepEqual([result.success, result.fid, result.stid], [true, -7, 0]);
  assert.match(TopicPostProtocol.validate(input({ fid: 0, stid: 0 })), /板块/);
});


test('pure text preparation accepts a matching fid without attachment auth', () => {
  for (const data of [{ fid: -7 }, { auth: '', fid: '-7' }, { auth: 123, fid: -7 },
    { __F: { fid: -7 } }]) {
    const result = TopicPostParser.parsePreparation(JSON.stringify({ data }), -7, 0);
    assert.deepEqual([result.success, result.errorMessage, result.fid, result.stid], [true, '', -7, 0]);
  }
  const reply = TopicPostParser.parsePreparation(JSON.stringify({ data: { __F: { fid: -7 } } }), 0, 0);
  assert.deepEqual([reply.success, reply.fid], [true, -7]);
});

test('pure text preparation accepts an empty auth with the selected child stid', () => {
  const result = TopicPostParser.parsePreparation(JSON.stringify({ data: { auth: '', stid: '555' } }), 0, 555);
  assert.deepEqual([result.success, result.errorMessage, result.fid, result.stid], [true, '', 0, 555]);
});

test('missing attachment auth never hides board mismatch or explicit rejection', () => {
  for (const data of [{ fid: 123 }, { stid: 555 }, { fid: -7, __F: { fid: 123 } },
    { fid: -7, error: '未登录' }, { fid: -7, __MESSAGE: { 0: 1, 1: '没有发帖权限' } }]) {
    const result = TopicPostParser.parsePreparation(JSON.stringify({ data }), -7, 0);
    assert.equal(result.success, false);
    assert.ok(result.errorMessage.length > 0);
  }
});

test('empty or unknown preparation data cannot authorize a text submission', () => {
  for (const data of [{}, { auth: '' }, { fid: 0, stid: 0 }, { foo: 'unknown' }, { __F: { name: '标题' } }]) {
    const result = TopicPostParser.parsePreparation(JSON.stringify({ data }), -7, 0);
    assert.equal(result.success, false);
    assert.match(result.errorMessage, /发帖信息/);
  }
});

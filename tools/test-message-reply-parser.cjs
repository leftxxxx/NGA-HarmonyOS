'use strict';

/* Run: node tools/test-message-reply-parser.cjs
 * Transpiles the actual ArkTS parser and its shared NGA response normalizer
 * with the DevEco SDK compiler. All replies are synthetic; no network or
 * account credentials are used and no private message is sent.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');

const devecoHome = process.env.DEVECO_HOME || 'D:/software/DevEco Studio';
const compilerPath = process.env.TYPESCRIPT_PATH || path.join(devecoHome,
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
assert.ok(fs.existsSync(compilerPath), 'Set DEVECO_HOME or TYPESCRIPT_PATH to the DevEco SDK compiler');
const ts = require(compilerPath);
require.extensions['.ets'] = (module, filename) => {
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  const errors = (output.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
  assert.deepEqual(errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
  module._compile(output.outputText, filename);
};

const { NgaMessageReplyResult, MessageReplyParser } = require('../entry/src/main/ets/model/MessageReplyParser.ets');
const UNCERTAIN = '发送结果未确认，请查看会话后再决定是否重试';
const reply = text => JSON.stringify({ data: { 0: text } });
function success(body) {
  const result = MessageReplyParser.parse(body);
  assert.ok(result instanceof NgaMessageReplyResult);
  assert.deepEqual([result.success, result.uncertain, result.errorMessage], [true, false, '']);
}
function uncertain(body) {
  const result = MessageReplyParser.parse(body);
  assert.deepEqual([result.success, result.uncertain, result.errorMessage], [false, true, UNCERTAIN]);
}
function rejected(body, expectedText) {
  const result = MessageReplyParser.parse(body);
  assert.equal(result.success, false);
  assert.equal(result.uncertain, false, 'An explicit rejection is a confirmed failed operation');
  assert.ok(result.errorMessage.length > 0);
  if (expectedText) assert.equal(result.errorMessage, expectedText);
}

test('reply result model starts with no success, rejection, or uncertainty', () => {
  const model = new NgaMessageReplyResult();
  assert.deepEqual([model.success, model.errorMessage, model.uncertain], [false, '', false]);
});

for (const text of ['发送完毕 ...', '发送完毕', '操作成功', '操作成功。', ' 操作成功！ ',
  '<b>发送完毕</b> ...', '发送完毕 ... @提醒每24小时不能超过50个']) {
  test(`explicit data.0 acknowledgement is accepted: ${text}`, () => success(reply(text)));
}

test('PHP indexed array data containers are accepted', () => {
  success(JSON.stringify({ data: ['发送完毕 ...'] }));
});

test('shared wrapper parser handles JS prefix, marker, semicolon, and error padding', () => {
  success('/*$js$*/window.script_muti_get_var_store=' + reply('发送完毕 ...') +
    ';/*error fill content padding*/');
});

for (const error of [{ 0: '未登录' }, ['没有回复权限'], '发送失败', { message: '发送过于频繁' },
  { msg: '消息已关闭' }, { 0: 403 }, true, {}]) {
  test(`explicit root error overrides successful data: ${JSON.stringify(error)}`, () => {
    rejected(JSON.stringify({ error, data: { 0: '操作成功' } }));
  });
}

test('nested data.error overrides both root zero error and success feedback', () => {
  rejected(JSON.stringify({ error: 0, data: { error: { 0: '<b>无回复权限</b>' }, 0: '发送完毕 ...' } }),
    '无回复权限');
});

test('root error is not hidden by a second nested error', () => {
  rejected(JSON.stringify({ error: { 0: '请先登录' }, data: { error: { 0: '其它错误' }, 0: '操作成功' } }),
    '请先登录');
});

test('__ERROR at either response level rejects a success acknowledgement', () => {
  for (const error of ['发送失败', { 0: '<b>没有回复权限</b>' }, ['会话已关闭'],
    { message: '消息已关闭' }, true, 403, {}, '操作成功']) {
    rejected(JSON.stringify({ __ERROR: error, data: { 0: '操作成功' } }));
    rejected(JSON.stringify({ error: 0, __ERROR: 0, data: { __ERROR: error, 0: '操作成功' } }));
  }
  rejected(JSON.stringify({ __ERROR: { 0: '<b>请先登录</b>' }, data: { 0: '操作成功' } }), '请先登录');
});

test('nonzero __MESSAGE status blocks success text even if the status text says success', () => {
  for (const container of ['root', 'data']) {
    for (const code of [1, '-1', 403, true]) {
      const message = { 0: code, 1: '操作成功' };
      const payload = container === 'root' ? { __MESSAGE: message, data: { 0: '操作成功' } } :
        { data: { __MESSAGE: message, 0: '操作成功' } };
      rejected(JSON.stringify(payload));
    }
  }
});

test('__MESSAGE rejection preserves server explanation without HTML', () => {
  rejected(JSON.stringify({ data: { __MESSAGE: { 0: 1, 1: '<span>该会话无法回复</span>' } } }),
    '该会话无法回复');
});

test('__MESSAGE HTTP error status rejects misleading success at either response level', () => {
  for (const code of [400, 403, 500, '401', ' 503 ']) {
    for (const level of ['root', 'data']) {
      const message = { 0: 0, 1: '操作成功', 3: code };
      rejected(JSON.stringify(level === 'root' ? { __MESSAGE: message, data: { 0: '操作成功' } } :
        { data: { __MESSAGE: message, 0: '操作成功' } }));
    }
  }
  rejected(JSON.stringify({ data: { __MESSAGE: { 1: '<b>未登录</b>', 3: 403 }, 0: '操作成功' } }), '未登录');
  success(JSON.stringify({ data: { __MESSAGE: { 0: 0, 1: '发送完毕 ...', 3: 200 } } }));
});

test('explicit rejection text cannot be hidden by zero message status or another success', () => {
  for (const text of ['未登录', '请先登录', '1:未登录', '没有回复权限', '无发送权限', '该会话无法回复',
    '会话已关闭', '发送过于频繁', '发送失败', '操作失败', '回复未完成']) {
    rejected(reply(text), text);
    rejected(JSON.stringify({ data: { __MESSAGE: { 0: 0, 1: text }, 0: '操作成功' } }), text);
    rejected(JSON.stringify({ __MESSAGE: text, data: { 0: '操作成功' } }), text);
  }
  rejected(JSON.stringify({ __MESSAGE: { 0: 0, 1: '操作成功' }, data: { 0: '发送失败' } }), '发送失败');
});

test('both __MESSAGE containers are checked before a success is accepted', () => {
  rejected(JSON.stringify({ __MESSAGE: { 0: 0, 1: '操作成功' },
    data: { __MESSAGE: { 0: 1, 1: '会话已关闭' }, 0: '发送完毕 ...' } }), '会话已关闭');
});

test('zero __MESSAGE status needs an explicit acknowledgement', () => {
  success(JSON.stringify({ data: { __MESSAGE: { 0: 0, 1: '操作成功' } } }));
  success(JSON.stringify({ __MESSAGE: ['0', '发送完毕 ...'] }));
  uncertain(JSON.stringify({ data: { __MESSAGE: { 0: 0, 1: '已处理' } } }));
});

test('absent and zero error sentinels do not reject a confirmed success', () => {
  for (const error of [undefined, null, false, 0, '0', '', ' 0 ']) {
    success(JSON.stringify({ error, __ERROR: error, data: { error, __ERROR: error, 0: '操作成功' } }));
  }
});

test('malformed or unknown __MESSAGE cannot prove success from another field', () => {
  for (const message of [true, false, 123, 'OK', {}, []]) {
    uncertain(JSON.stringify({ __MESSAGE: message, data: { 0: '操作成功' } }));
    uncertain(JSON.stringify({ data: { __MESSAGE: message, 0: '操作成功' } }));
  }
});

for (const text of ['', '0', 'OK', '成功', '登录成功', '未操作成功', '没有操作成功',
  '操作成功率低', '发送完毕前请确认', '正文中提到操作成功', '发送完毕 ... 回复失败',
  '操作成功，但发送失败', '@提醒每24小时不能超过50个']) {
  test(`unknown or misleading feedback cannot confirm sending: ${text}`, () => uncertain(reply(text)));
}

test('success words in unrelated fields or returned conversation content are ignored', () => {
  uncertain(JSON.stringify({ message: '操作成功', data: { 0: { content: '发送完毕 ...' } } }));
  uncertain(JSON.stringify({ data: { 1: '操作成功' } }));
});

test('missing, null, empty, and malformed response shapes are uncertain', () => {
  for (const body of ['', '   ', '{}', 'null', 'true', '[]', '{"data":null}',
    '{"data":{}}', '{"data":{"0":null}}', '{"data":{"0":true}}',
    '{"data":{"0":123}}', '{"data":{"0":"发送完毕 ..."}', '<html>操作成功</html>',
    '<!doctype html><html><body><form>请先登录</form></body></html>']) {
    uncertain(body);
  }
});

test('non-JSON script and trailing code cannot spoof a success acknowledgement', () => {
  globalThis.messageReplySpoofed = false;
  uncertain('window.script_muti_get_var_store=' + reply('操作成功') +
    ';globalThis.messageReplySpoofed=true;');
  uncertain('({data:{0:"操作成功"}})');
  assert.equal(globalThis.messageReplySpoofed, false);
  delete globalThis.messageReplySpoofed;
});

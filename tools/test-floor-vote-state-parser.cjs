'use strict';

// Loads the actual ArkTS parser through the DevEco SDK compiler. No network or device voting.
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
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    fileName: filename,
    reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  const errors = (result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0,
    errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n'));
  module._compile(result.outputText, filename);
};
const { NgaJsonParser } = require('../entry/src/main/ets/model/NgaJsonParser.ets');
const direction = (body, requested = 1) => NgaJsonParser.parsePostVoteDirection(body, requested);
const envelope = message => JSON.stringify({ data: { 0: message } });

test('affirmative and already-voted server statements retain their actual direction', () => {
  for (const person of ['你', '您']) {
    for (const already of ['', '已经', '已']) {
      for (const target of ['这个帖子', '该帖子', '本帖']) {
        for (const [label, expected] of [['支持', 1], ['反对', -1]]) {
          const message = `${person}${already}对${target}表示${label}`;
          assert.equal(direction(envelope(message)), expected, message);
          assert.equal(direction(envelope(message), -1), expected,
            'A confirmed server direction takes precedence over the requested direction');
        }
      }
    }
  }
});

test('confirmed cancellation and withdrawal clear either previously selected direction', () => {
  for (const person of ['你', '您']) {
    for (const target of ['这个帖子', '该帖子', '本帖']) {
      for (const action of ['取消了', '撤回了', '取消', '撤回', '已经取消了', '已撤回']) {
        for (const label of ['支持', '反对']) {
          const message = `${person}${action}对${target}的${label}`;
          assert.equal(direction(envelope(message)), 0, message);
          assert.equal(direction(envelope(message), -1), 0, message);
        }
      }
    }
  }
});

test('root messages, known JS envelopes, HTML decoration, and terminal punctuation remain supported', () => {
  for (const body of [
    '{"0":"你对这个帖子表示支持"}',
    '/*$js$*/window.script_muti_get_var_store={"data":{"0":"你对这个帖子表示支持"}}/*$js$*/;',
    envelope(' 您已经对 该帖子 表示<b>支持</b>。 '),
    envelope('你对这个帖子表示支持！')
  ]) assert.equal(direction(body), 1, body);
  assert.equal(direction(envelope('你对这个帖子表示反对!')), -1);
  assert.equal(direction(envelope('你撤回了对这个帖子的反对。')), 0);
});

test('business error envelopes override even explicitly affirmative data messages', () => {
  const successfulMessage = '你对这个帖子表示支持';
  for (const body of [
    { error: '未登录', data: { 0: successfulMessage } },
    { error: '你对这个帖子表示支持', data: { 0: successfulMessage } },
    { error: ['没有权限'], data: { 0: successfulMessage } },
    { error: { 0: 403 }, data: { 0: successfulMessage } },
    { error: true, data: { 0: successfulMessage } },
    { data: { error: '操作次数超过限制', 0: successfulMessage } },
    { error: 0, data: { error: '操作失败', 0: successfulMessage } },
    { __MESSAGE: { 0: 1, 1: '操作失败' }, data: { 0: successfulMessage } },
    { data: { __MESSAGE: { 0: 1, 1: '你对这个帖子表示支持' }, 0: successfulMessage } },
    { __MESSAGE: { 0: 1, 1: '操作失败' },
      data: { __MESSAGE: { 0: 0, 1: '操作成功' }, 0: successfulMessage } }
  ]) assert.equal(direction(JSON.stringify(body)), undefined, JSON.stringify(body));
  assert.equal(direction(JSON.stringify({ error: 0, data: { 0: successfulMessage } })), 1);
});

test('failure, negation, hypothetical, ambiguous, and generic success text never creates a selection', () => {
  for (const message of [
    '操作成功', '支持', '反对', '支持失败', '反对失败', '不支持该操作',
    '未能确认支持结果', '你没有对这个帖子表示支持', '你尚未对这个帖子表示反对',
    '你对这个帖子表示支持失败', '你对这个帖子表示反对未成功',
    '如果你对这个帖子表示支持', '请对这个帖子表示支持',
    '你对这个帖子表示支持或者反对', '你对这个帖子表示支持，随后撤回',
    '你取消了对这个帖子的支持失败', '你撤回了对这个帖子的反对失败',
    '你取消了对这个帖子的支持，并对这个帖子表示反对'
  ]) assert.equal(direction(envelope(message)), undefined, message);
});

test('missing, numeric-only, malformed, and unknown responses never change a selection', () => {
  for (const body of ['', '{', '<html>Bad gateway</html>', 'null', '[]', '{}',
    '{"data":{}}', '{"data":{"0":0}}', '{"data":{"0":true}}',
    '{"data":{"0":""}}', '{"data":{"0":{"message":"你对这个帖子表示支持"}}}']) {
    assert.equal(direction(body), undefined, body);
  }
});

test('unsupported or non-finite requested directions are rejected before interpreting the server', () => {
  for (const requested of [0, 2, -2, 1.5, NaN, Infinity, undefined, null, '1']) {
    assert.equal(NgaJsonParser.parsePostVoteDirection(envelope('你对这个帖子表示支持'), requested),
      undefined, String(requested));
  }
});

test('server JavaScript attached to a successful-looking body is never executed or accepted', () => {
  delete globalThis.floorVoteStateExecuted;
  const body = envelope('你对这个帖子表示支持') + ';globalThis.floorVoteStateExecuted=true';
  assert.equal(direction(body), undefined);
  assert.equal(globalThis.floorVoteStateExecuted, undefined);
});

'use strict';

// Run: node --test tools/test-topic-attachment-protocol.cjs
// Compile the real attachment/parser models with the DevEco ETS compiler.
// All responses and binary headers are local fixtures; no upload is performed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const devecoHome = process.env.DEVECO_HOME || 'D:/software/DevEco Studio';
const compilerPath = process.env.TYPESCRIPT_PATH || path.join(devecoHome,
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
assert.ok(fs.existsSync(compilerPath), 'Set DEVECO_HOME or TYPESCRIPT_PATH to the DevEco SDK compiler');
const ts = require(compilerPath);
const modelRoot = path.resolve(__dirname, '../entry/src/main/ets/model');
const cache = new Map();
function load(name) {
  if (cache.has(name)) return cache.get(name).exports;
  const filename = path.join(modelRoot, name + '.ets');
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  assert.deepEqual((output.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error)
    .map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
  const module = { exports: {} };
  cache.set(name, module);
  const sourceRequire = id => {
    assert.ok(id.startsWith('./'), 'Native dependencies are not permitted in protocol fixtures: ' + id);
    return load(id.slice(2));
  };
  vm.runInThisContext('(function(require, module, exports) {\n' + output.outputText + '\n})', { filename })
    (sourceRequire, module, module.exports);
  return module.exports;
}

const { TopicAttachmentProtocol: protocol } = load('TopicAttachmentProtocol');
const { TopicAttachmentLiteral: literal } = load('TopicAttachmentLiteral');
const received = { url: 'mon_202610/07/fixture_001.png', attachments: 'fixture-attachment-id',
  attachments_check: 'fixture-check' };
const body = data => JSON.stringify({ data });
const clone = item => JSON.parse(JSON.stringify(item));
const bytes = value => Uint8Array.from(value).buffer;

test('confirmed upload returns paired metadata and the forum relative-image BBCode', () => {
  for (const url of [received.url, './' + received.url]) {
    const result = protocol.parseUpload(body({ ...received, url }));
    assert.equal(result.success, true);
    assert.equal(result.errorMessage, '');
    assert.deepEqual(clone(result.attachment), { url: received.url,
      attachments: received.attachments, attachmentsCheck: received.attachments_check });
    assert.equal(protocol.buildMarkup(result.attachment), '[img]./' + received.url + '[/img]');
  }
});

test('the exact public upload rejection probe is safely parsed as a data literal', () => {
  const response = "window.script_muti_get_var_store={error_code:2,error:'附件上传版面错误',error_txt:'附件上传版面错误',encode:'utf-8'}";
  const result = protocol.parseUpload(response);
  assert.equal(result.success, false);
  assert.equal(result.failureStage, 'server');
  assert.equal(result.errorMessage, '附件上传版面错误');
  assert.match(protocol.describeUpload(response), /shape=nga-assignment wrapper=nga-js json=true/);
  assert.match(protocol.describeUpload(response), /rootKeys=encode,error,error_code,error_txt\+other:0/);
  assert.match(protocol.describeUpload(response), /errorCode=2$/);
});

test('same-shape upload success supports unquoted fields, single quotes and a single known assignment', () => {
  for (const prefix of ['window.script_muti_get_var_store=', '/*$js$*/window.script_muti_get_var_store = ']) {
    const response = prefix + "{data:{url:'mon_202610/07/fixture_001.png',attachments:'fixture-attachment-id'," +
      "attachments_check:'fixture-check'},encode:'utf-8'};/*$js$*/";
    const result = protocol.parseUpload(response);
    assert.equal(result.success, true);
    assert.equal(result.attachment.url, received.url);
    assert.equal(protocol.buildMarkup(result.attachment), '[img]./' + received.url + '[/img]');
  }
  assert.equal(protocol.parseUpload('{data:{url:"fixture"}}').failureStage, 'json',
    'JavaScript literals must have the exact NGA assignment wrapper');
});

test('literal string parsing preserves quotes, slashes, hex escapes, Unicode and JSON values', () => {
  const response = String.raw`window.script_muti_get_var_store={data:{text:'quote\' double" slash\\ \x41 \u4e2d \ud83d\ude00',` +
    String.raw`controls:'\b\f\n\r\t\/',values:[true,false,null,-3,0.5,1e3],__MESSAGE:{0:0,1:'正常'},},};`;
  const parsed = literal.parseResponse(response);
  assert.equal(parsed.data.text, 'quote\' double" slash\\ A 中 😀');
  assert.equal(parsed.data.controls, '\b\f\n\r\t/');
  assert.deepEqual(parsed.data.values, [true, false, null, -3, 0.5, 1000]);
  assert.deepEqual(parsed.data.__MESSAGE, { 0: 0, 1: '正常' });
  const modern = { data: { text: '中文 \u0000 \n 😃', values: [true, null, 0.25] } };
  assert.deepEqual(literal.parseResponse(JSON.stringify(modern)), modern);
});

test('literal parser rejects executable syntax, alternate assignments and incomplete input', () => {
  const valid = JSON.stringify({ data: received });
  const assignment = 'window.script_muti_get_var_store=';
  const attacks = [
    assignment + 'window.script_muti_get_var_store=' + valid,
    'other=' + valid,
    assignment + valid + ';globalThis.attachmentParserExecuted=true',
    assignment + '{data:(globalThis.attachmentParserExecuted=true)}',
    assignment + '{data:function(){}}', assignment + '{data:()=>1}', assignment + '{data:new Date()}',
    assignment + '{data:`template`}', assignment + '{data:/regex/}', assignment + '{data:undefined}',
    assignment + '{get data(){return 1}}', assignment + '{...data}',
    assignment + '{data:{__proto__:{polluted:true}}}', assignment + '{data:1,data:2}',
    assignment + '{data:[1,,2]}', assignment + '{data:NaN}', assignment + '{data:1e999}',
    assignment + "{data:'bad\\xGG'}", assignment + "{data:'bad\\uGGGG'}", assignment + "{data:'bad\\q'}",
    assignment + "{data:'unclosed}", assignment + "{data:'raw\nnewline'}",
    '<script>' + assignment + valid + '</script>', assignment + valid + ';;',
    assignment + valid + '/* arbitrary trailing comment */', assignment + valid + ';/*error fill content hidden',
    "{data:'raw-js-without-assignment'}", '{"data":"bad\\x41"}', '{"data":[1,]}', valid + ';',
    assignment + '{data:' + '['.repeat(34) + '0' + ']'.repeat(34) + '}',
    ' '.repeat(1024 * 1024) + valid
  ];
  delete globalThis.attachmentParserExecuted;
  for (const response of attacks) {
    assert.throws(() => literal.parseResponse(response), undefined, response.slice(0, 120));
    const result = protocol.parseUpload(response);
    assert.equal(result.success, false);
    assert.equal(result.failureStage, 'json');
    assert.equal(result.attachment.url, '');
  }
  assert.equal(globalThis.attachmentParserExecuted, undefined);
  assert.equal({}.polluted, undefined);
});

test('safe response diagnostics never include values or unrecognized key names', () => {
  const response = JSON.stringify({ data: { ...received, 'private-secret-key': 'private-secret-value' },
    'private-root-secret': 'private-cookie=1' });
  const description = protocol.describeUpload(response);
  assert.match(description, /rootKeys=data\+other:1/);
  assert.match(description, /dataKeys=attachments,attachments_check,url\+other:1/);
  assert.ok(!description.match(/fixture|private|secret|cookie|mon_/));
  const html = '<html><script>window.secretAuth="private-token"</script></html>';
  assert.match(protocol.describeUpload(html), /shape=html wrapper=html-script json=false/);
  assert.ok(!protocol.describeUpload(html).includes('private-token'));
});

test('malformed, incomplete or unsafe upload responses never supply insertable attachments', () => {
  const responses = ['', '{malformed', '{}', body({}), body({ ...received, attachments: '' }),
    body({ ...received, attachments_check: '\tbad-check' }), body({ ...received, attachments: 123 }),
    body({ ...received, attachments_check: 'x'.repeat(8193) })];
  for (const url of ['https://img.invalid/fixture.png', 'javascript:alert(1)', '/mon_202610/07/a.png',
    'mon_202610/07/../a.png', 'mon_202610/07/a.png?x=1', 'mon_202610/07/a.png#x',
    'mon_202610/07/a.svg', 'mon_202610/07/a.png\n', "mon_202610/07/a' onerror='x.png"]) {
    responses.push(body({ ...received, url }));
  }
  for (const response of responses) {
    const result = protocol.parseUpload(response);
    assert.equal(result.success, false, response);
    assert.ok(result.errorMessage.length > 0);
    assert.equal(protocol.buildMarkup(result.attachment), '');
    assert.equal(result.attachment.attachments, '');
  }
});

test('server size errors and explicit rejection win over apparently valid attachment fields', () => {
  for (const response of [body({ ...received, error_code: 9 }), body({ ...received, error_code: '9' }),
    JSON.stringify({ error_code: 9, data: received })]) {
    const result = protocol.parseUpload(response);
    assert.equal(result.success, false);
    assert.match(result.errorMessage, /大小|更小/);
    assert.equal(protocol.buildMarkup(result.attachment), '');
  }
  for (const data of [{ ...received, __MESSAGE: { 0: 1, 1: '<b>没有权限上传</b>' } },
    { ...received, __MESSAGE: { 0: 0, 1: '上传授权已失效', 3: 403 } },
    { ...received, error: { message: '<div>请先登录</div>' } }]) {
    const result = protocol.parseUpload(body(data));
    assert.equal(result.success, false);
    assert.ok(result.errorMessage.length > 0);
    assert.ok(!result.errorMessage.includes('<'));
    assert.equal(result.attachment.url, '');
  }
});

test('attachment authorization requires a valid auth and consistent board context', () => {
  for (const [data, fid, stid, resolved] of [
    [{ auth: 'fixture-auth', fid: -7 }, -7, 0, -7],
    [{ auth: 'fixture-auth', fid: 414, stid: 12007887 }, 414, 12007887, 414],
    [{ auth: 'fixture-auth', fid: 414, stid: 12007887 }, 0, 12007887, 414]
  ]) {
    const result = protocol.parsePreparation(body(data), fid, stid);
    assert.equal(result.success, true);
    assert.equal(result.auth, 'fixture-auth');
    assert.equal(result.fid, resolved);
  }
  for (const [data, fid, stid] of [
    [{ fid: -7 }, -7, 0], [{ auth: ' ' }, -7, 0], [{ auth: 'bad\nvalue', fid: -7 }, -7, 0],
    [{ auth: 'x'.repeat(4097), fid: -7 }, -7, 0], [{ auth: 'fixture', fid: 414 }, -7, 0],
    [{ auth: 'fixture', fid: 414, stid: 13011773 }, 414, 12007887],
    [{ auth: 'fixture', fid: -7, __MESSAGE: { 0: 1, 1: '登录失效' } }, -7, 0]
  ]) {
    const result = protocol.parsePreparation(body(data), fid, stid);
    assert.equal(result.success, false);
    assert.equal(result.auth, '');
    assert.ok(result.errorMessage.length > 0);
  }
});

test('image references survive size and tag-case edits and forum-supported absolute paths', () => {
  const attachment = protocol.parseUpload(body(received)).attachment;
  for (const content of [
    '[img]./' + received.url + '[/img]',
    '[IMG]./' + received.url + '[/IMG]',
    '[img50]./' + received.url + '[/img]',
    '[img=100,200]./' + received.url + '[/img]',
    '[img]  ' + received.url + '  [/img]',
    '[img]https://img.nga.cn/attachments/' + received.url + '[/img]',
    '[img]https://img8.nga.cn/attachments/' + received.url + '[/img]',
    '[code][img]./' + received.url + '[/img][/code]\n实际图片[img50]./' + received.url + '[/img]'
  ]) {
    assert.equal(protocol.isReferenced(content, attachment), true, content);
  }
});

test('deleted images, quoted code and unrelated links do not attach uploaded metadata', () => {
  const attachment = protocol.parseUpload(body(received)).attachment;
  for (const content of [
    '图片已删除，保留正文', received.url,
    '[url]' + received.url + '[/url]',
    '[img]./mon_202610/07/other.png[/img]',
    '[img]https://example.invalid/attachments/' + received.url + '[/img]',
    '[code][img]./' + received.url + '[/img][/code]',
    '[CODE=bbcode][IMG50]./' + received.url + '[/IMG][/CODE]',
    '[code][img]./' + received.url + '[/img][/code]\n' +
      '[code=example][img=100,200]./' + received.url + '[/img][/code]'
  ]) {
    assert.equal(protocol.isReferenced(content, attachment), false, content);
  }
});

test('known image signatures identify their actual format instead of trusting a filename', () => {
  for (const [data, type] of [
    [[0xff, 0xd8, 0xff, 0xe0], 'image/jpeg'],
    [[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 'image/png'],
    [[...Buffer.from('GIF89a')], 'image/gif'], [[...Buffer.from('GIF87a')], 'image/gif'],
    [[...Buffer.from('RIFF0000WEBP')], 'image/webp'],
    [[0, 0, 0, 16, ...Buffer.from('ftypheic')], 'image/heif'],
    [[0, 0, 0, 16, ...Buffer.from('ftypavif')], 'image/avif'], [[0x42, 0x4d], 'image/bmp']
  ]) {
    assert.equal(protocol.detectImageType(bytes(data)), type);
  }
  for (const data of [[], [0xff, 0xd8], [...Buffer.from('<html>not an image</html>')],
    [...Buffer.from('GIF00a')], [...Buffer.from('RIFF0000FAKE')]]) {
    assert.equal(protocol.detectImageType(bytes(data)), '');
  }
});

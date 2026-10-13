/*
 * Run: node tools/test-topic-protocol.cjs [--live]
 * Loads the actual .ets models with DevEco's TypeScript transpiler.
 * No parser implementation is copied into this test and no credentials are read.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');

const devecoHome = process.env.DEVECO_HOME || 'D:\\software\\DevEco Studio';
const compilerCandidates = [
  process.env.TYPESCRIPT_PATH,
  path.join(devecoHome, 'tools/hvigor/hvigor-ohos-plugin/node_modules/typescript'),
  path.join(devecoHome, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript')
].filter(Boolean);
const compilerPath = compilerCandidates.find(candidate => fs.existsSync(candidate));
assert.ok(compilerPath, 'Set DEVECO_HOME or TYPESCRIPT_PATH to a DevEco TypeScript installation');
const ts = require(compilerPath);
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
const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/topic-list-fid7.json'), 'utf8'));
const rawFixture = JSON.stringify(fixture);
const row = fixture.data.__T['0'];
const parse = body => NgaJsonParser.parseTopicList(typeof body === 'string' ? body : JSON.stringify(body));

function expectFailure(body, expectedText) {
  const result = parse(body);
  assert.equal(result.success, false);
  assert.equal(result.threadPageList.length, 0);
  assert.ok(result.error.length > 0);
  if (expectedText) assert.ok(result.error.includes(expectedText), result.error);
}

function expectThreadFailure(body, expectedText) {
  const result = NgaJsonParser.parseThreadData(typeof body === 'string' ? body : JSON.stringify(body));
  assert.equal(result.success, false);
  assert.equal(result.rowList.length, 0);
  assert.ok(result.error.length > 0);
  if (expectedText) assert.ok(result.error.includes(expectedText), result.error);
}

test('public GBK response excerpt: data.__T numeric map, Chinese subject, and real sub_forums', () => {
  const result = parse(rawFixture);
  assert.equal(result.success, true);
  assert.equal(result.error, '');
  assert.equal(result.name, fixture.data.__F.name);
  assert.equal(result.threadPageList.length, Object.keys(fixture.data.__T).length);
  assert.equal(result.threadPageList[0].tid, row.tid);
  assert.equal(result.threadPageList[0].subject, row.subject);
  assert.ok(result.threadPageList[0].subject.includes('魔兽世界'));
  assert.ok(result.subBoardList.some(board => board.fid < 0));
  assert.ok(result.subBoardList.some(board => board.stid > 0));
});

test('known JavaScript prefix, markers, BOM, and trailing semicolon are handled safely', () => {
  for (const body of [
    'window.script_muti_get_var_store=' + rawFixture,
    '\uFEFF /*$js$*/ window.script_muti_get_var_store= /*$js$*/ ' + rawFixture + ' /*$js$*/; '
  ]) {
    const result = parse(body);
    assert.equal(result.success, true);
    assert.equal(result.threadPageList[0].subject, row.subject);
  }
});

test('marker text inside a subject is preserved', () => {
  const result = parse({ __T: [{ ...row, subject: '讨论 /*$js$*/ 原样文本' }] });
  assert.equal(result.success, true);
  assert.equal(result.threadPageList[0].subject, '讨论 /*$js$*/ 原样文本');
});

test('legacy root fields and actual arrays remain supported', () => {
  const result = parse({
    __T: [row], __F: { name: '旧格式' },
    __SUB: [{ fid: '-7', stid: '0', name: '旧子版面' }]
  });
  assert.equal(result.success, true);
  assert.equal(result.threadPageList.length, 1);
  assert.equal(result.name, '旧格式');
  assert.equal(result.subBoardList[0].fid, -7);
});

test('numeric strings and sparse numeric-key rows are parsed in numeric order', () => {
  const result = parse({ data: { __T: {
    10: { ...row, tid: '10', authorid: '21', replies: '3', postdate: '1498529634' },
    2: { ...row, tid: '2' }, 0: { ...row, tid: '1' }
  } } });
  assert.equal(result.success, true);
  assert.deepEqual(result.threadPageList.map(thread => thread.tid), [1, 2, 10]);
  assert.equal(result.threadPageList[2].authorId, 21);
  assert.equal(result.threadPageList[2].replies, 3);
  assert.equal(result.threadPageList[2].postDate, 1498529634);
});

test('topic recommendation accepts numeric strings and defaults missing or invalid values to zero', () => {
  for (const [recommend, expected] of [
    [10, 10], ['10', 10], [' 11 ', 11], [9, 9], [0, 0],
    [undefined, 0], [null, 0], ['', 0], ['10oops', 0], ['10.0', 0],
    ['NaN', 0], ['Infinity', 0], [true, 0], [{}, 0], [[], 0]
  ]) {
    const result = parse({ data: { __T: [{ ...row, recommend }] } });
    assert.equal(result.success, true, result.error);
    assert.equal(result.threadPageList[0].recommend, expected, `recommend=${JSON.stringify(recommend)}`);
    assert.equal(result.threadPageList[0].subject, row.subject);
  }
});

test('sub_forums serialized as JSON also works', () => {
  const result = parse({ data: {
    __T: { 0: row }, __F: { sub_forums: JSON.stringify(fixture.data.__F.sub_forums) }
  } });
  assert.equal(result.success, true);
  assert.equal(result.subBoardList.length, Object.keys(fixture.data.__F.sub_forums).length);
});

test('empty arrays and maps are successful empty boards', () => {
  for (const threads of [[], {}]) {
    const result = parse({ data: { __T: threads, __F: { name: '空板块' } } });
    assert.equal(result.success, true);
    assert.equal(result.error, '');
    assert.equal(result.threadPageList.length, 0);
  }
});

test('HTTP 200 NGA error envelope is an error, not an empty board', () => {
  const body = fs.readFileSync(path.join(__dirname, 'fixtures/topic-list-page-limit.json'), 'utf8');
  expectFailure(body, '超过限制');
  assert.ok(!parse(body).error.includes('<a'));
});

test('NGA anonymous login and invalid-board errors preserve the server message', () => {
  for (const name of ['topic-list-login-required.json', 'topic-list-invalid-board.json']) {
    const body = fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8');
    const expected = name.includes('login') ? '未登录' : '不存在';
    expectFailure('window.script_muti_get_var_store=' + body, expected);
  }
});

test('string, array, and __MESSAGE-only error variants are handled', () => {
  expectFailure({ error: '没有权限' }, '没有权限');
  expectFailure({ error: ['权限不足'] }, '权限不足');
  expectFailure({ data: { __MESSAGE: { 0: 1, 1: '未登录' } } }, '未登录');
  expectFailure({ __MESSAGE: { 0: 56, 1: '版面不存在' } }, '不存在');
});

test('invalid JSON, HTML, missing data, wrong row shape, and malformed rows fail visibly', () => {
  for (const body of ['', '{', '<html>网关错误</html>', 'null', '[]', {},
    { data: {} }, { data: { __T: null } }, { __T: 'oops' },
    { __T: { metadata: {} } }, { __T: [null, {}, { tid: 1, subject: 2 }] }]) {
    expectFailure(body);
  }
});

test('server JavaScript is never executed', () => {
  delete globalThis.ngaProtocolTestExecuted;
  expectFailure('window.script_muti_get_var_store=' + rawFixture + ';globalThis.ngaProtocolTestExecuted=true');
  assert.equal(globalThis.ngaProtocolTestExecuted, undefined);
});

function topicWithRawString(rawString, field = 'jdata') {
  return JSON.stringify({ data: { __F: { fid: 414, name: '游戏综合讨论' }, __T: {
    0: { tid: 414001, subject: '合成话题', [field]: 'HEX_INPUT_SENTINEL' }
  } } }).replace('"HEX_INPUT_SENTINEL"', '"' + rawString + '"');
}

test('fid414 jdata hexadecimal backslash keeps nested JSON quotes and the topic list', () => {
  const body = fs.readFileSync(path.join(__dirname, 'fixtures/topic-list-fid414-hex-escape.txt'), 'utf8');
  assert.ok(body.includes(String.raw`\x5C`));
  assert.throws(() => JSON.parse(body.replace(/^window\.script_muti_get_var_store=/, '').trim().replace(/;$/, '')));
  const result = parse(body);
  assert.equal(result.success, true, result.error);
  assert.equal(result.name, '游戏综合讨论');
  assert.equal(result.threadPageList.length, 1);
  assert.equal(result.threadPageList[0].tid, 414001);
  assert.equal(result.threadPageList[0].subject, '合成话题');
  const metadata = NgaJsonParser.parseResponseObject(body).data.__T['60'].jdata;
  assert.equal(metadata, String.raw`{"skw":"alpha\"beta"}`);
  assert.deepEqual(JSON.parse(metadata), { skw: 'alpha"beta' });
});

test('valid JS hexadecimal string escapes decode backslash, quote, controls, and mixed-case digits', () => {
  const cases = [
    [String.raw`before\x5Cafter`, String.raw`before\after`],
    [String.raw`before\x5cafter`, String.raw`before\after`],
    [String.raw`before\x22after`, 'before"after'],
    [String.raw`\x00\x01\x08\x09\x0A\x0d\x1F`, '\u0000\u0001\b\t\n\r\u001f'],
    [String.raw`\x61\x41\xaf\xAF\xFf`, 'aA\u00af\u00af\u00ff']
  ];
  for (const [rawString, expected] of cases) {
    const body = topicWithRawString(rawString);
    assert.equal(parse(body).success, true, rawString);
    assert.equal(NgaJsonParser.parseResponseObject(body).data.__T['0'].jdata, expected, rawString);
  }
});

test('adjacent hexadecimal escapes retain their decoded value without leaking into JSON structure', () => {
  const body = topicWithRawString(String.raw`\x5C\x22\x5c\x5C\x22\x0Aend`);
  const expected = '\\"\\\\"\nend';
  assert.equal(parse(body).success, true);
  assert.equal(NgaJsonParser.parseResponseObject(body).data.__T['0'].jdata, expected);
});

test('hexadecimal escapes in a topic subject and reply body preserve visible content', () => {
  const list = parse(topicWithRawString(String.raw`原文\x22引号\x22\x5C路径\x0A下一行`, 'subject'));
  assert.equal(list.success, true, list.error);
  assert.equal(list.threadPageList[0].subject, '原文"引号"\\路径\n下一行');
  const detail = NgaJsonParser.parseThreadData(String.raw`{"data":{"__T":{"tid":414001},"__R":{"0":{"tid":414001,"content":"图片说明\x0A\x22原话\x22\x5c路径"}}}}`);
  assert.equal(detail.success, true, detail.error);
  assert.equal(detail.rowList[0].content, '图片说明\n"原话"\\路径');
});

test('existing JSON escapes remain unchanged alongside a hexadecimal escape', () => {
  const rawString = String.raw`\u4E2D\n\r\t\b\f\"\\\/\x41`;
  const expected = '中\n\r\t\b\f"\\/A';
  const body = topicWithRawString(rawString);
  assert.equal(parse(body).success, true);
  assert.equal(NgaJsonParser.parseResponseObject(body).data.__T['0'].jdata, expected);
  const existingOnly = String.raw`{"value":"\u4E2D\n\r\t\b\f\"\\\/"}`;
  assert.deepEqual(NgaJsonParser.parseResponseObject(existingOnly), JSON.parse(existingOnly));
});

test('double-escaped literal hexadecimal text is not converted', () => {
  for (const [rawString, expected] of [
    [String.raw`literal\\x5C`, String.raw`literal\x5C`],
    [String.raw`literal\\\\x22`, String.raw`literal\\x22`],
    [String.raw`literal\\x5C|decoded\x5C`, 'literal\\x5C|decoded\\']
  ]) {
    const body = topicWithRawString(rawString);
    assert.equal(parse(body).success, true, rawString);
    assert.equal(NgaJsonParser.parseResponseObject(body).data.__T['0'].jdata, expected, rawString);
  }
});

test('malformed hexadecimal and unsupported JS string escapes remain errors', () => {
  for (const rawString of [String.raw`\x`, String.raw`\x0`, String.raw`\xGG`, String.raw`\x5g`,
    String.raw`\x-1`, String.raw`\X5C`, String.raw`\v`, String.raw`\0`, String.raw`\q`]) {
    const body = topicWithRawString(rawString);
    expectFailure(body);
    assert.throws(() => NgaJsonParser.parseResponseObject(body), undefined, rawString);
  }
});

test('hexadecimal syntax outside strings and appended JS are rejected without execution', () => {
  delete globalThis.ngaHexProtocolTestExecuted;
  expectFailure(String.raw`{"data":{"__T":[]},"value":\x31}`);
  const body = topicWithRawString(String.raw`metadata\x5Cvalue`);
  expectFailure('window.script_muti_get_var_store=' + body + ';globalThis.ngaHexProtocolTestExecuted=true');
  assert.equal(globalThis.ngaHexProtocolTestExecuted, undefined);
  const stringCode = topicWithRawString(String.raw`globalThis.ngaHexProtocolTestExecuted=true;\x5C`);
  assert.equal(parse(stringCode).success, true);
  assert.equal(globalThis.ngaHexProtocolTestExecuted, undefined);
});

test('public read.php excerpt: data.__R map and __U authors, with raw TAB in metadata', () => {
  const body = fs.readFileSync(path.join(__dirname, 'fixtures/thread-tid47552220.txt'), 'utf8');
  assert.throws(() => JSON.parse(body), /control character/i);
  const result = NgaJsonParser.parseThreadData(body);
  assert.equal(result.success, true, result.error);
  assert.equal(result.rowList.length, 2);
  assert.equal(result.threadInfo.tid, 47552220);
  assert.equal(result.threadInfo.subject, row.subject);
  assert.equal(result.__F.fid, '7');
  assert.equal(result.rowList[0].author, '公开用户甲');
  assert.equal(result.rowList[1].author, '公开用户乙');
  assert.ok(result.rowList.every(reply => reply.content.length > 0));
});

test('detail arrays, numeric strings, direct and __U avatars, and numeric forum fields', () => {
  const result = NgaJsonParser.parseThreadData(JSON.stringify({
    __ROWS: '2', __T: { tid: '9', fid: '-7', subject: '主题', authorid: '1', replies: '1' },
    __F: { fid: -7, name: '版面' }, __U: {
      1: { username: '甲', avatar: 'https://example.com/a.png' },
      2: { username: '乙', avatar: '{"0":{"0":"https://example.com/b.png"}}' }
    }, __R: [
      { tid: '9', pid: '11', authorid: '1', content: '正文', lou: '0', postdate: '2026-10-03 14:00' },
      { authorid: '2', subject: '仅标题的回复', lou: '1', postdate: 1791037049 }
    ]
  }));
  assert.equal(result.success, true);
  assert.equal(result.__ROWS, 2);
  assert.equal(result.__F.fid, '-7');
  assert.equal(result.threadInfo.authorId, 1);
  assert.equal(result.threadInfo.replies, 1);
  assert.deepEqual(result.rowList.map(reply => reply.author), ['甲', '乙']);
  assert.deepEqual(result.rowList.map(reply => reply.avatar), ['https://example.com/a.png', 'https://example.com/b.png']);
  assert.equal(result.rowList[0].pid, 11);
  assert.equal(result.rowList[1].tid, 9);
  assert.equal(result.rowList[1].lou, 1);
  assert.equal(result.rowList[1].content, '仅标题的回复');
  assert.equal(result.rowList[1].postdate, '1791037049');
});

test('detail wrappers, literal control characters, escaped quotes, and backslashes retain content', () => {
  const content = '第一行\n第二行\t"原话"\\路径\r\u0001';
  const raw = JSON.stringify({ data: { __T: { tid: 1 }, __R: { 0: { tid: 1, content } } } })
    .replace('\\n', '\n').replace('\\t', '\t').replace('\\r', '\r').replace('\\u0001', '\u0001');
  const result = NgaJsonParser.parseThreadData('/*$js$*/window.script_muti_get_var_store=' + raw + ';/*$js$*/');
  assert.equal(result.success, true, result.error);
  assert.equal(result.rowList[0].content, content);
});

test('detail empty rows are valid, while metadata alone and invalid rows fail', () => {
  for (const replies of [{}, []]) {
    const result = NgaJsonParser.parseThreadData(JSON.stringify({ data: { __T: { tid: 1 }, __R: replies } }));
    assert.equal(result.success, true);
    assert.equal(result.rowList.length, 0);
  }
  for (const body of ['', '<html>错误</html>', { data: { __T: { tid: 1 } } },
    { data: { __R: { 0: {} } } }, { __R: '错误' }]) {
    expectThreadFailure(body);
  }
});

test('detail preserves attachment CDN from nested and legacy globals for online and cached content', () => {
  for (const body of [
    { data: { __R: [], __GLOBAL: { _ATTACH_BASE_VIEW: 'img.nga.cn/attachments', _ATTACH_BASE: 'unused.example/attachments' } } },
    { __GLOBAL: { _ATTACH_BASE_VIEW: 'img.nga.cn/attachments' }, data: { __R: [] } },
    { __R: [], __GLOBAL: { _ATTACH_BASE: 'img.nga.cn/attachments' } }
  ]) {
    const result = NgaJsonParser.parseThreadData(JSON.stringify(body));
    assert.equal(result.success, true);
    assert.equal(result.attachmentBase, 'img.nga.cn/attachments');
  }
  const result = NgaJsonParser.parseThreadData(JSON.stringify({ data: { __R: [] } }));
  assert.equal(result.attachmentBase, 'https://img.nga.cn/attachments/');
});

test('detail errors use __R, not topic metadata, when interpreting __MESSAGE', () => {
  expectThreadFailure({ data: { __T: { tid: 1 }, __MESSAGE: { 0: 1, 1: '未登录' } } }, '未登录');
  expectThreadFailure({ error: '没有权限', data: { __R: [], __T: { tid: 1 } } }, '没有权限');
  const result = NgaJsonParser.parseThreadData(JSON.stringify({
    data: { __R: [{ tid: 1, content: '正文' }], __MESSAGE: { 0: 0, 1: '正常提示' } }
  }));
  assert.equal(result.success, true);
});

function expectIncompleteThread(body) {
  const result = NgaJsonParser.parseThreadData(body);
  assert.equal(result.success, false);
  assert.equal(result.responseIncomplete, true);
  assert.equal(result.error, '服务器响应不完整，请重试');
  assert.equal(result.rowList.length, 0, 'A partial response must never publish its early rows');
  return result;
}

test('captured thread response shape ending inside the attachs key is identified without repairing JSON', () => {
  // Anonymous structural fixture based on the observed EOF: data.__R.2 ended
  // during the attachs key, with four objects still open. No response text is retained.
  const complete = JSON.stringify({ data: {
    __ROWS: 60, __T: { tid: 900, subject: '示例话题' }, __R: {
      0: { tid: 900, content: '示例正文', lou: 0, pid: 0 },
      2: { tid: 900, content: '示例回复', lou: 2, from_client: '8 Android',
        postdatetimestamp: 1700000000, attachs: '' }
    }
  } });
  const incomplete = complete.slice(0, complete.indexOf('"attachs"') + '"attachs'.length);
  assert.ok(incomplete.endsWith('"attachs'));
  assert.throws(() => JSON.parse(incomplete));
  expectIncompleteThread(incomplete);
  const valid = NgaJsonParser.parseThreadData(complete);
  assert.equal(valid.success, true, valid.error);
  assert.equal(valid.responseIncomplete, false);
  assert.equal(valid.rowList.length, 2);
});

test('EOF inside content, after a backslash, and inside a wrapped response is incomplete', () => {
  const prefix = '{"data":{"__R":{"0":{"tid":1,"content":"';
  for (const body of [prefix + '正文', prefix + '正文\\',
    '/*$js$*/window.script_muti_get_var_store=' + prefix + '正文']) {
    expectIncompleteThread(body);
  }
});

test('EOF with unclosed arrays and objects is incomplete', () => {
  for (const body of ['{', '{"data":{', '{"data":{"__R":[',
    '{"data":{"__R":[{"tid":1,"content":"正文"}',
    '{"data":{"__R":[{"tid":1,"content":"正文"}]']) {
    expectIncompleteThread(body);
  }
});

test('EOF where a property value or the rest of an object is expected is incomplete', () => {
  for (const body of ['{"data":{"__ROWS":', '{"data":{"__ROWS":1',
    '{"data":{"__R":null', '{"data":{"__R":[true',
    '{"data":{"__R":[{"tid":1,"content":"正文"},']) {
    expectIncompleteThread(body);
  }
});

test('complete permission, login, deletion and row-shape errors never request incomplete-response recovery', () => {
  for (const body of [
    { error: '没有权限', data: { __R: [] } },
    { data: { __MESSAGE: { 0: 1, 1: '未登录' } } },
    { error: { 0: '话题不存在或已被删除' } },
    { data: { __T: { tid: 1 } } }, { data: { __R: '错误' } },
    { data: { __R: [{}] } }, null, [], ''
  ]) {
    const result = NgaJsonParser.parseThreadData(typeof body === 'string' ? body : JSON.stringify(body));
    assert.equal(result.success, false);
    assert.equal(result.responseIncomplete, false);
    assert.notEqual(result.error, '服务器响应不完整，请重试');
  }
});

test('invalid escapes, mismatched brackets and illegal plus numbers are ordinary parse failures', () => {
  for (const body of [
    String.raw`{"data":{"__R":[{"content":"\q"}]}}`,
    String.raw`{"data":{"__R":[{"content":"\q`,
    String.raw`{"data":{"__R":[{"content":"\xGG"}]}}`,
    '{"data":{"__R":[}}', '{"data":{"__R":[}',
    '{"data":{"__R":{]', '{"data":{"other":+123,"__R":[]}}',
    '{"data":{"__R":[{"content":+1.5}]}}',
    '{"data":{"__R":[{"subject":+}]}}',
    '<html>网关错误</html>'
  ]) {
    const result = NgaJsonParser.parseThreadData(body);
    assert.equal(result.success, false);
    assert.equal(result.responseIncomplete, false);
    assert.equal(result.error, '服务器响应解析失败，请重试');
  }
});

test('native EOF wording is accepted only alongside an unfinished object without bracket mismatch', t => {
  const parser = t.mock.method(JSON, 'parse', () => {
    throw new SyntaxError('Unexpected end Text in JSON');
  });
  expectIncompleteThread('{"data":{"__R":{"0":{"content":"正文');
  for (const body of ['{"data":{"__R":[]}}', '{"data":{"__R":[}', '[{"data":{']) {
    const result = NgaJsonParser.parseThreadData(body);
    assert.equal(result.responseIncomplete, false);
  }
  parser.mock.restore();
});

test('errors during field mapping are not incomplete JSON even when the error mentions EOF', t => {
  const { AvatarUtils } = require('../entry/src/main/ets/model/AvatarUtils.ets');
  const parser = t.mock.method(AvatarUtils, 'parseAvatarUrl', () => {
    throw new Error('Unexpected end Text in JSON');
  });
  const result = NgaJsonParser.parseThreadData(JSON.stringify({ data: { __R: [{ tid: 1, content: '正文' }] } }));
  assert.equal(result.success, false);
  assert.equal(result.responseIncomplete, false);
  assert.equal(result.error, '服务器响应解析失败，请重试');
  parser.mock.restore();
});

test('optional public live lite=js and __output=8 compatibility', { skip: !process.argv.includes('--live') }, async () => {
  for (const format of ['lite=js&noprefix', '__output=8&noprefix', 'lite=js']) {
    const response = await fetch('https://bbs.nga.cn/thread.php?fid=7&page=1&' + format, {
      headers: { 'User-Agent': 'Nga_Official/80023', 'Accept-Charset': 'GBK' },
      signal: AbortSignal.timeout(15000)
    });
    assert.equal(response.status, 200);
    const body = new TextDecoder('gbk').decode(await response.arrayBuffer());
    const result = parse(body);
    assert.equal(result.success, true, result.error);
    assert.ok(result.threadPageList.length > 0);
    assert.ok(result.threadPageList.every(thread => thread.tid > 0 && thread.subject.length > 0));
    assert.equal(result.name, fixture.data.__F.name);
  }
});

test('optional public live read.php content and users', { skip: !process.argv.includes('--live') }, async () => {
  const response = await fetch('https://bbs.nga.cn/read.php?page=1&__output=8&noprefix&v2&tid=47552220', {
    headers: { 'User-Agent': 'Nga_Official/80023', 'Accept-Charset': 'GBK' },
    signal: AbortSignal.timeout(15000)
  });
  assert.equal(response.status, 200);
  const result = NgaJsonParser.parseThreadData(new TextDecoder('gbk').decode(await response.arrayBuffer()));
  assert.equal(result.success, true, result.error);
  assert.ok(result.rowList.length > 0);
  assert.ok(result.rowList.every(reply => reply.content.length > 0 && reply.author.length > 0));
  assert.equal(result.threadInfo.tid, 47552220);
  assert.equal(result.__F.fid, '7');
});

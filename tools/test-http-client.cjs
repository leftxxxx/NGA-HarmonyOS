'use strict';

// Run: node --test tools/test-http-client.cjs
// Exercise the actual ETS sources. Only HarmonyOS native APIs and persisted stores
// are replaced; parsing, response handling, form encoding, and URL building remain real.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { TextDecoder } = require('node:util');
const { test } = require('node:test');

const studioRoot = process.env.DEVECO_HOME || 'D:\\software\\DevEco Studio';
const typescriptPath = process.env.ETS_TYPESCRIPT_PATH || path.join(studioRoot,
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js');
const ts = require(typescriptPath);
const modelRoot = path.resolve(__dirname, '../entry/src/main/ets/model');

// GBK fixture for {"title":"中文"}; Chinese bytes are fixed, not produced by
// the app's encoder or by another implementation of the response decoder.
const gbkJson = Buffer.from('7b227469746c65223a22d6d0cec4227d', 'hex');
const expectedJson = '{"title":"中文"}';
// Fixed GBK reference bytes. This substitutes the native encoder only; form
// escaping and roundtrip validation still run in the actual ETS encoder.
const gbkReference = new Map([
  ['后', 'BAF3'], ['很', 'BADC'], ['文', 'CEC4'], ['问', 'CECA'],
  ['龘', 'FD93'], ['喆', '86B4'], ['镕', 'E946']
]);

function arrayBuffer(buffer) {
  return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
}

function fixture(response, requestError, cachedResponse) {
  const requests = [];
  const responseSources = [];
  const encodings = [];
  const encoderEncodings = [];
  let destroyed = 0;
  const nativeHttp = {
    RequestMethod: { GET: 'GET', POST: 'POST' },
    HttpDataType: { STRING: 0, OBJECT: 1, ARRAY_BUFFER: 2 },
    createHttp() {
      return {
        async request(url, options) {
          requests.push({ url, options });
          if (requestError) throw requestError;
          // Model the documented native cache boundary; this does not reproduce
          // or establish which response the real device previously received.
          if (cachedResponse !== undefined && options.usingCache !== false) {
            responseSources.push('cache');
            return cachedResponse;
          }
          responseSources.push('network');
          return response;
        },
        destroy() { destroyed++; }
      };
    }
  };
  const nativeUtil = {
    TextEncoder: class {
      constructor(encoding) {
        assert.equal(encoding, 'gbk');
        encoderEncodings.push(encoding);
      }
      encodeInto(input) {
        const bytes = [];
        for (const ch of input) {
          if (ch.codePointAt(0) < 0x80) bytes.push(ch.codePointAt(0));
          else if (gbkReference.has(ch)) bytes.push(...Buffer.from(gbkReference.get(ch), 'hex'));
          else bytes.push(0x3f); // Native replacement must be caught by the ETS roundtrip check.
        }
        return new Uint8Array(bytes);
      }
    },
    TextDecoder: {
      create(encoding) {
        encodings.push(encoding);
        const decoder = new TextDecoder(encoding);
        return { decodeToString(bytes, options) { return decoder.decode(bytes, options); } };
      }
    }
  };
  const mocks = {
    '@ohos.net.http': { default: nativeHttp },
    '@ohos.util': { default: nativeUtil, ...nativeUtil },
    '@kit.ArkTS': { util: nativeUtil },
    './LoginStore': { LoginStore: { getCookie: () => 'test-cookie=1' } },
    './AppSettings': {
      SettingsStore: { getInt: () => 1 },
      SettingKeys: { DOMAIN: 'domain' },
      SettingDefaults: { DOMAIN: 1 }
    }
  };
  const cache = new Map();
  function load(name) {
    if (cache.has(name)) return cache.get(name).exports;
    const filename = path.join(modelRoot, name + '.ets');
    const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      fileName: filename.replace(/\.ets$/, '.ts'),
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    });
    const module = { exports: {} };
    cache.set(name, module);
    const sourceRequire = (id) => {
      if (Object.hasOwn(mocks, id)) return mocks[id];
      if (id.startsWith('./')) return load(id.slice(2));
      throw new Error('Unexpected ETS dependency: ' + id);
    };
    const evaluate = vm.runInThisContext('(function(require, module, exports) {\n' +
      compiled.outputText + '\n})', { filename });
    evaluate(sourceRequire, module, module.exports);
    return module.exports;
  }
  return {
    HttpClient: load('HttpClient').HttpClient,
    UrlBuilder: load('UrlBuilder').UrlBuilder,
    NgaJsonParser: load('NgaJsonParser').NgaJsonParser,
    requests,
    responseSources,
    encodings,
    encoderEncodings,
    destroyed: () => destroyed,
    arrayBufferType: nativeHttp.HttpDataType.ARRAY_BUFFER
  };
}

test('GET retains native cache use by default and when explicitly enabled', async () => {
  const f = fixture({ responseCode: 200, result: 'network response', header: {} }, undefined,
    { responseCode: 200, result: 'cached response', header: {} });
  const url = 'https://bbs.nga.cn/thread.php?fid=-7&page=1&lite=js&noprefix';
  const implicit = await f.HttpClient.get(url);
  const explicit = await f.HttpClient.get(url, { Referer: 'https://bbs.nga.cn/' }, true);
  assert.equal(implicit.body, 'cached response');
  assert.equal(explicit.body, 'cached response');
  assert.deepEqual(f.requests.map(item => item.options.usingCache), [true, true]);
  assert.deepEqual(f.responseSources, ['cache', 'cache']);
  assert.equal(f.destroyed(), 2);
});

test('fresh online read bypasses a damaged simulated native cache and parses the network body', async () => {
  const freshBody = JSON.stringify({ data: {
    __T: { tid: 44191387, subject: 'fixture topic' }, __ROWS: 1,
    __R: [{ tid: 44191387, pid: 0, lou: 0, content: 'fresh topic content' }]
  } });
  const damagedBody = '{"data":{"__R":';
  const f = fixture({ responseCode: 200, result: freshBody, header: {} }, undefined,
    { responseCode: 200, result: damagedBody, header: {} });
  const url = f.UrlBuilder.buildArticleUrl(44191387, 1);
  const cached = await f.HttpClient.get(url);
  assert.equal(f.NgaJsonParser.parseThreadData(cached.body).success, false);
  const fresh = await f.HttpClient.get(url, { Referer: 'https://bbs.nga.cn/' }, false);
  const parsed = f.NgaJsonParser.parseThreadData(fresh.body);
  assert.equal(fresh.success, true);
  assert.equal(fresh.body, freshBody);
  assert.equal(parsed.success, true, parsed.error);
  assert.equal(parsed.rowList[0].content, 'fresh topic content');
  assert.deepEqual(f.responseSources, ['cache', 'network']);
  assert.equal(f.requests[1].options.usingCache, false);
  assert.equal(f.requests[1].options.header.Cookie, 'test-cookie=1');
  assert.equal(f.requests[1].options.header['User-Agent'], 'Nga_Official/80023');
  assert.equal(f.requests[1].options.header['Accept-Charset'], 'GBK');
  assert.equal(f.requests[1].options.header.Referer, 'https://bbs.nga.cn/');
  assert.equal(f.requests[1].options.expectDataType, f.arrayBufferType);
  assert.equal(f.destroyed(), 2);
});

async function request(f, method) {
  const url = 'https://bbs.nga.cn/thread.php?fid=-7&page=1&lite=js&noprefix';
  return method === 'GET' ? f.HttpClient.get(url, { Referer: 'https://bbs.nga.cn/' }) :
    f.HttpClient.post(url, { content: 'test content', page: '1' });
}

for (const method of ['GET', 'POST']) {
  test(method + ' decodes unlabelled binary GBK responses and requests ARRAY_BUFFER', async () => {
    const f = fixture({ responseCode: 200, result: arrayBuffer(gbkJson), header: {} });
    const result = await request(f, method);
    assert.equal(result.success, true);
    assert.equal(result.statusCode, 200);
    assert.equal(result.body, expectedJson);
    assert.equal(result.error, '');
    assert.equal(f.requests[0].options.expectDataType, f.arrayBufferType);
    assert.equal(f.requests[0].options.method, method);
    assert.equal(f.requests[0].options.header.Cookie, 'test-cookie=1');
    assert.equal(f.requests[0].options.header['User-Agent'], 'Nga_Official/80023');
    assert.equal(f.requests[0].options.header['Accept-Charset'], 'GBK');
    assert.equal(f.encodings.at(-1).toLowerCase(), 'gbk');
    assert.equal(f.destroyed(), 1);
    if (method === 'GET') {
      assert.equal(f.requests[0].options.header.Referer, 'https://bbs.nga.cn/');
    } else {
      const form = new URLSearchParams(f.requests[0].options.extraData);
      assert.equal(form.get('content'), 'test content');
      assert.equal(form.get('page'), '1');
    }
  });

  test(method + ' honors declared UTF-8 instead of decoding it as GBK', async () => {
    const f = fixture({
      responseCode: 200,
      result: arrayBuffer(Buffer.from(expectedJson, 'utf8')),
      header: { 'Content-Type': 'application/json; charset=UTF-8' }
    });
    const result = await request(f, method);
    assert.equal(result.success, true);
    assert.equal(result.body, expectedJson);
    assert.equal(f.encodings.at(-1).toLowerCase(), 'utf-8');
    assert.equal(f.destroyed(), 1);
  });

  test(method + ' preserves a decoded error body for HTTP 403', async () => {
    const f = fixture({
      responseCode: 403, result: arrayBuffer(gbkJson),
      header: { 'content-type': 'application/json; charset=gbk' }
    });
    const result = await request(f, method);
    assert.equal(result.success, false);
    assert.equal(result.statusCode, 403);
    assert.equal(result.body, expectedJson);
    assert.match(result.error, /HTTP 403/);
    assert.equal(f.destroyed(), 1);
  });

  test(method + ' destroys the native request after an exception', async () => {
    const f = fixture(undefined, new Error('simulated socket timeout'));
    const result = await request(f, method);
    assert.equal(result.success, false);
    assert.equal(result.statusCode, 0);
    assert.match(result.error, /simulated socket timeout/);
    assert.equal(f.destroyed(), 1);
  });
}

test('POST sends correct GBK Chinese and escaped form separators without modifying the draft', async () => {
  const f = fixture({ responseCode: 200, result: arrayBuffer(gbkJson), header: {} });
  const content = ' 后很文问龘喆镕\n&+= [s:ac:good] ';
  const result = await f.HttpClient.post('https://bbs.nga.cn/nuke.php', { content }, true);
  assert.equal(result.success, true);
  assert.deepEqual(f.encoderEncodings, ['gbk']);
  assert.equal(f.requests[0].options.extraData,
    'content=+%BA%F3%BA%DC%CE%C4%CE%CA%FD%93%86%B4%E9%46%0A%26%2B%3D+%5Bs%3Aac%3Agood%5D+');
});

test('POST rejects unsupported Unicode before dispatching and releases the request', async () => {
  const f = fixture();
  const result = await f.HttpClient.post('https://bbs.nga.cn/nuke.php', { content: '文😀' }, true);
  assert.equal(result.success, false);
  assert.equal(result.statusCode, 0);
  assert.match(result.error, /GBK 不支持的字符/);
  assert.equal(f.requests.length, 0);
  assert.equal(f.destroyed(), 1);
});

test('POST rejects malformed UTF-16 before dispatching', async () => {
  const f = fixture();
  const result = await f.HttpClient.post('https://bbs.nga.cn/nuke.php', { content: '文\ud800' }, true);
  assert.equal(result.success, false);
  assert.match(result.error, /无效字符/);
  assert.equal(f.requests.length, 0);
  assert.equal(f.encoderEncodings.length, 0);
});

test('topic URL preserves a negative fid and page with no default stid', () => {
  const f = fixture();
  assert.equal(f.UrlBuilder.buildTopicListUrl(-7, 2),
    'https://bbs.nga.cn/thread.php?fid=-7&page=2&lite=js&noprefix');
});

test('topic URL uses fid when the sub-board stid is zero', () => {
  const f = fixture();
  assert.equal(f.UrlBuilder.buildTopicListUrl(414, 1, 0),
    'https://bbs.nga.cn/thread.php?fid=414&page=1&lite=js&noprefix');
});

test('topic URL prioritizes a nonzero sub-board stid over fid and retains page', () => {
  const f = fixture();
  assert.equal(f.UrlBuilder.buildTopicListUrl(414, 3, 16015869),
    'https://bbs.nga.cn/thread.php?stid=16015869&page=3&lite=js&noprefix');
  assert.equal(f.UrlBuilder.buildTopicListUrl(414, 1, -1),
    'https://bbs.nga.cn/thread.php?stid=-1&page=1&lite=js&noprefix');
});

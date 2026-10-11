'use strict';

// Run: node --test tools/test-gbk-encoder.cjs
// Execute the real ETS percent encoder. Only HarmonyOS native codec APIs are
// substituted using fixed, independently known GBK bytes; no network is used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { TextDecoder } = require('node:util');
const { test } = require('node:test');

const studioRoot = process.env.DEVECO_HOME || 'D:/software/DevEco Studio';
const compilerPath = process.env.ETS_TYPESCRIPT_PATH || path.join(studioRoot,
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js');
const ts = require(compilerPath);
const nativeCalls = [];
const referenceBytes = new Map([
  ['后', 'BAF3'], ['很', 'BADC'], ['文', 'CEC4'], ['问', 'CECA'],
  ['龘', 'FD93'], ['喆', '86B4'], ['镕', 'E946']
]);
const nativeUtil = {
  TextEncoder: class {
    constructor(encoding) {
      assert.equal(encoding, 'gbk');
      nativeCalls.push(['encoder', encoding]);
    }
    encodeInto(input) {
      const bytes = [];
      for (const ch of input) {
        if (ch.codePointAt(0) < 0x80) bytes.push(ch.codePointAt(0));
        else if (referenceBytes.has(ch)) bytes.push(...Buffer.from(referenceBytes.get(ch), 'hex'));
        else bytes.push(0x3f);
      }
      return new Uint8Array(bytes);
    }
  },
  TextDecoder: {
    create(encoding, options) {
      assert.equal(encoding, 'gbk');
      nativeCalls.push(['decoder', encoding]);
      const decoder = new TextDecoder(encoding, options);
      return { decodeToString(bytes, decodeOptions) { return decoder.decode(bytes, decodeOptions); } };
    }
  }
};
const filename = path.resolve(__dirname, '../entry/src/main/ets/model/GbkEncoder.ets');
const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  fileName: filename, reportDiagnostics: true,
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
});
assert.deepEqual((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error)
  .map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
const codecModule = { exports: {} };
const loadNative = id => {
  assert.equal(id, '@kit.ArkTS');
  return { util: nativeUtil };
};
vm.runInThisContext('(function(require, module, exports) {\n' + compiled.outputText + '\n})',
  { filename })(loadNative, codecModule, codecModule.exports);
const { GbkEncoder } = codecModule.exports;

test('empty text stays empty without invoking native codecs', () => {
  nativeCalls.length = 0;
  assert.equal(GbkEncoder.encode(''), '');
  assert.deepEqual(nativeCalls, []);
});

test('incorrect old table entries now use correct GBK bytes', () => {
  assert.equal(GbkEncoder.encode('后很文问'), '%BA%F3%BA%DC%CE%C4%CE%CA');
});

test('GBK extension ideographs are supported, including an ASCII-valued trailing byte', () => {
  assert.equal(GbkEncoder.encode('龘喆镕'), '%FD%93%86%B4%E9%46');
});

test('safe ASCII and the established space-as-plus rule are preserved', () => {
  const input = "AZaz09-_.~!*'()";
  assert.equal(GbkEncoder.encode(input), input);
  assert.equal(GbkEncoder.encode(' a b '), '+a+b+');
});

test('newlines, tabs and reserved form separators are escaped as bytes', () => {
  assert.equal(GbkEncoder.encode('\r\n\t&+=%/?#'), '%0D%0A%09%26%2B%3D%25%2F%3F%23');
});

test('forum BBCode images and emoticons remain valid ASCII content', () => {
  const bbcode = '[img]https://img.invalid/a.png[/img][s:ac:good]';
  assert.equal(GbkEncoder.encode(bbcode),
    '%5Bimg%5Dhttps%3A%2F%2Fimg.invalid%2Fa.png%5B%2Fimg%5D%5Bs%3Aac%3Agood%5D');
});

for (const input of ['😀', '文😀问', '𠮷', 'a\u200db']) {
  test(`unsupported Unicode is rejected instead of native substitution: ${JSON.stringify(input)}`, () => {
    assert.throws(() => GbkEncoder.encode(input), /GBK 不支持的字符/);
  });
}

for (const input of ['\ud800', '\udc00', 'a\ud800b', '\ud800\ud800', '\udc00\ud800']) {
  test(`malformed UTF-16 is rejected before native encoding: ${JSON.stringify(input)}`, () => {
    nativeCalls.length = 0;
    assert.throws(() => GbkEncoder.encode(input), /无效字符/);
    assert.deepEqual(nativeCalls, []);
  });
}

test('roundtrip validation rejects any unexpected native transcoding', () => {
  const originalCreate = nativeUtil.TextDecoder.create;
  nativeUtil.TextDecoder.create = () => ({ decodeToString: () => '被改写' });
  try {
    assert.throws(() => GbkEncoder.encode('文'), /GBK 不支持的字符/);
  } finally {
    nativeUtil.TextDecoder.create = originalCreate;
  }
});

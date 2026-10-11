/* Tests the actual .ets decoder; --live also compares NGA's public smile mapping. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const devecoHome = process.env.DEVECO_HOME || 'D:\\software\\DevEco Studio';
const ts = require(process.env.TYPESCRIPT_PATH || path.join(devecoHome,
  'tools/hvigor/hvigor-ohos-plugin/node_modules/typescript'));
require.extensions['.ets'] = (module, filename) => {
  const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  assert.equal((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  module._compile(compiled.outputText, filename);
};
const {
  EMOTION_CATEGORIES, EMOTION_CATEGORY_LABELS, getEmoticonList, getEmoticonRawfilePath,
  getEmoticonImageUrl, getLegacyEmoticonRawfilePath, getPathByUrl, decodeAllEmoticons
} = require('../entry/src/main/ets/model/EmoticonUtils.ets');
const rawfileRoot = path.resolve(__dirname, '../entry/src/main/resources/rawfile');
const officialNgMap = {
  '呲牙笑': 'ng_1.png', '奸笑': 'ng_2.png', '问号': 'ng_3.png', '茶': 'ng_4.png',
  '笑指': 'ng_5.png', '燃尽': 'ng_6.png', '晕': 'ng_7.png', '扇笑': 'ng_8.png',
  '寄': 'ng_9.png', '别急': 'ng_10.png', 'doge': 'ng_11.png', '丧': 'ng_12.png',
  '汗': 'ng_13.png', '叹气': 'ng_15.png', '吃饼': 'ng_16.png', '吃瓜': 'ng_17.png',
  '吐舌': 'ng_18.png', '哭': 'ng_19.png', '喘': 'ng_20.png', '心': 'ng_21.png',
  '喷': 'ng_22.png', '困': 'ng_24.png', '大哭': 'ng_25.png', '大惊': 'ng_26.png',
  '害怕': 'ng_27.png', '惊': 'ng_28.png', '暴怒': 'ng_30.png', '气愤': 'ng_31.png',
  '热': 'ng_32.png', '瓜不熟': 'ng_33.png', '瞎': 'ng_34.png', '色': 'ng_35.png',
  '斜眼': 'ng_37.png', '问号大': 'ng_38.png'
};
const officialLegacyMap = {
  '1': 'smile.gif', '2': 'mrgreen.gif', '3': 'question.gif', '4': 'wink.gif',
  '5': 'redface.gif', '6': 'sad.gif', '7': 'cool.gif', '8': 'crazy.gif',
  '24': '04.gif', '25': '05.gif', '26': '06.gif', '27': '07.gif',
  '28': '08.gif', '29': '09.gif', '30': '10.gif', '32': '12.gif',
  '33': '13.gif', '34': '14.gif', '35': '15.gif', '36': '16.gif',
  '37': '17.gif', '38': '18.gif', '39': '19.gif', '40': '20.gif',
  '41': '21.gif', '42': '22.gif', '43': '23.gif'
};
const localSource = rawfile => {
  const data = fs.readFileSync(path.join(rawfileRoot, rawfile));
  return 'data:image/' + (rawfile.endsWith('.gif') ? 'gif' : 'png') + ';base64,' + data.toString('base64');
};
const imageCount = html => (html.match(/<img\b/g) || []).length;

test('34 official NG names render their exact packaged PNGs and appear in the selector', () => {
  assert.ok(EMOTION_CATEGORIES.includes('ng'));
  assert.equal(EMOTION_CATEGORY_LABELS.ng, 'NG娘');
  assert.deepEqual(getEmoticonList('ng').sort(), Object.keys(officialNgMap).sort());
  for (const [name, filename] of Object.entries(officialNgMap)) {
    const rawfile = 'emoticon/ng/' + filename;
    assert.equal(getEmoticonRawfilePath('ng', name), rawfile);
    const data = fs.readFileSync(path.join(rawfileRoot, rawfile));
    assert.ok(data.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])));
    assert.equal(data.subarray(12, 16).toString(), 'IHDR');
    assert.ok(data.readUInt32BE(16) > 0 && data.readUInt32BE(20) > 0);
    const token = '[s:ng:' + name + ']';
    const html = decodeAllEmoticons(token, localSource);
    assert.equal(imageCount(html), 1);
    assert.ok(html.includes("src='" + localSource(rawfile) + "'"));
    assert.ok(html.includes("alt='" + token + "'"));
    assert.ok(!html.includes('invertFilter'));
  }
  assert.equal(getEmoticonRawfilePath('ng', '呼'), '');
});

test('all 27 numeric names and both official category aliases share the same local GIF', () => {
  for (const [number, filename] of Object.entries(officialLegacyMap)) {
    const rawfile = 'emoticon/legacy/' + filename;
    assert.equal(getLegacyEmoticonRawfilePath(number), rawfile);
    assert.ok(fs.readFileSync(path.join(rawfileRoot, rawfile)).subarray(0, 6).toString().startsWith('GIF8'));
    for (const token of ['[s:' + number + ']', '[s:0:' + number + ']', '[s::' + number + ']']) {
      const html = decodeAllEmoticons(token, localSource);
      assert.equal(imageCount(html), 1, token);
      assert.ok(html.includes("src='" + localSource(rawfile) + "'"), token);
      assert.ok(html.includes("alt='" + token + "'"), token);
    }
    assert.equal(getEmoticonRawfilePath('0', number), rawfile);
    assert.equal(getEmoticonRawfilePath('', number), rawfile);
  }
  for (const token of ['[s:9]', '[s:0:9]', '[s::9]', '[s:1:1]', '[s:00:1]']) {
    assert.equal(decodeAllEmoticons(token, localSource), token);
  }
});

test('mixed adjacent, repeated and uppercase category tokens all render locally', () => {
  const tokens = '[s:ng:呲牙笑][s:ng:奸笑][s:NG:doge][s:ac:哭笑][s:0:1][s::1][s:1]';
  const html = decodeAllEmoticons(tokens, localSource);
  assert.equal(imageCount(html), 7);
  assert.equal((html.match(/src='data:image\//g) || []).length, 7);
});

test('NG image URL lookups preserve prior smile URL localization behavior', () => {
  for (const filename of Object.values(officialNgMap)) {
    assert.equal(getPathByUrl('https://img4.nga.cn/ngabbs/post/smile/' + filename + '?v=1'), 'emoticon/ng/' + filename);
  }
  assert.equal(getPathByUrl('http://img.nga.178.com/attachments/mon_201209/14/-47218_5052bc4cc6331.png?x=1'),
    'emoticon/ac/-47218_5052bc4cc6331.png');
  assert.equal(getPathByUrl('https://img4.nga.cn/ngabbs/post/smile/smile.gif#x'), 'emoticon/legacy/smile.gif');
});

test('unknown names, prototype keys and unsafe image sources never emit images', () => {
  for (const category of ['__proto__', 'constructor', 'toString', 'prototype']) {
    assert.deepEqual(getEmoticonList(category), []);
    assert.equal(getEmoticonRawfilePath(category, 'doge'), '');
    assert.equal(getEmoticonImageUrl(category, 'doge'), '');
    const token = '[s:' + category + ':doge]';
    assert.equal(decodeAllEmoticons(token, localSource), token);
  }
  for (const name of ['__proto__', 'constructor', 'toString', 'prototype', '未定义']) {
    assert.equal(getEmoticonRawfilePath('ng', name), '');
    assert.equal(getEmoticonImageUrl('ng', name), '');
    assert.equal(getLegacyEmoticonRawfilePath(name), '');
    const token = '[s:ng:' + name + ']';
    assert.equal(decodeAllEmoticons(token, localSource), token);
  }
  Object.prototype.fakeSmile = 'ng_1.png';
  try {
    assert.equal(getEmoticonRawfilePath('ng', 'fakeSmile'), '');
    assert.equal(decodeAllEmoticons('[s:ng:fakeSmile]', localSource), '[s:ng:fakeSmile]');
  } finally {
    delete Object.prototype.fakeSmile;
  }
  const tokens = '[s:ng:呲牙笑][s:0:1][s::1]';
  assert.equal(imageCount(decodeAllEmoticons(tokens, () => "javascript:alert(1)' onerror='x")), 0);
});

test('public NGA mapping and every NG PNG match the bundled official assets',
  { skip: !process.argv.includes('--live') }, async () => {
    const response = await fetch('https://img4.nga.cn/common_res/js_bbscode_core.js?1342409',
      { signal: AbortSignal.timeout(15000) });
    assert.equal(response.status, 200);
    const source = new TextDecoder('gb18030').decode(await response.arrayBuffer());
    const ngBlock = source.match(/\bng:\{\s*([\s\S]*?)\n\}/);
    assert.ok(ngBlock);
    const cleanNg = ngBlock[1].replace(/\/\/[^\r\n]*/g, '');
    const liveNgMap = Object.fromEntries([...cleanNg.matchAll(/'([^']+)'\s*:\s*'([^']+)'/g)]
      .filter(match => !match[1].startsWith('_')).map(match => [match[1], match[2]]));
    assert.deepEqual(liveNgMap, officialNgMap);
    const defaultBlock = source.match(/smiles\s*=\s*\{\s*0:\{\s*([\s\S]*?)\n\}/);
    assert.ok(defaultBlock);
    const liveLegacyMap = Object.fromEntries([...defaultBlock[1].matchAll(/\b(\d+):'([^']+)'/g)]
      .map(match => [match[1], match[2]]));
    assert.deepEqual(liveLegacyMap, officialLegacyMap);
    const filenames = Object.values(officialNgMap);
    for (let offset = 0; offset < filenames.length; offset += 4) {
      await Promise.all(filenames.slice(offset, offset + 4).map(async filename => {
        const image = await fetch('https://img4.nga.cn/ngabbs/post/smile/' + filename,
          { signal: AbortSignal.timeout(15000) });
        assert.equal(image.status, 200, filename);
        assert.ok(image.headers.get('content-type').startsWith('image/'), filename);
        const actual = Buffer.from(await image.arrayBuffer());
        assert.ok(actual.equals(fs.readFileSync(path.join(rawfileRoot, 'emoticon/ng', filename))), filename);
      }));
    }
  });

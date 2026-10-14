'use strict';

// Execute the real pure ArkTS parser and the existing whitelist HTML renderer.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const ts = require(process.env.TYPESCRIPT_PATH || path.join(process.env.DEVECO_HOME || 'D:/software/DevEco Studio',
  'tools/hvigor/hvigor-ohos-plugin/node_modules/typescript'));
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  assert.deepEqual((result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error), []);
  module._compile(result.outputText, filename);
};
const { parseNativeArticleContent, NATIVE_ARTICLE_PARAGRAPH_LIMIT } =
  require('../entry/src/main/ets/model/ArticleNativeContent.ets');
const { renderArticleContent, articleImageSources } = require('../entry/src/main/ets/model/ArticleHtml.ets');
const { getEmoticonRawfilePath, getLegacyEmoticonRawfilePath, getEmoticonImageUrl } =
  require('../entry/src/main/ets/model/EmoticonUtils.ets');
const rawfiles = path.resolve(__dirname, '../entry/src/main/resources/rawfile');
const localSource = rawfile => 'data:image/' + (rawfile.endsWith('.gif') ? 'gif' : 'png') + ';base64,' +
  fs.readFileSync(path.join(rawfiles, rawfile)).toString('base64');
const textOf = document => document.blocks.flatMap(block => block.inlines).map(inline => inline.text).join('');
const imagesOf = document => document.blocks.flatMap(block => block.kind === 'image' ? [block.image] :
  block.inlines.filter(inline => inline.image !== undefined).map(inline => inline.image));
const paragraphLength = block => block.inlines.reduce((sum, inline) => sum + (inline.image ? 1 : inline.text.length), 0);
function documentHtml(content, night = false, preview = false) {
  return '<!DOCTYPE html><html><head><meta charset="utf-8"><style>' +
    (preview ? 'html,body' : 'body') + '{background:' + (night ? '#192333' : '#ffffff') + ';color:' +
    (night ? '#e9eff8' : '#182538') + ';font-size:16px;line-height:1.75;margin:0;padding:0;}' +
    'blockquote{margin:8px 0;padding:8px;border-left:3px solid ' + (night ? '#8dbeff' : '#1765c1') + ';}' +
    'a{color:' + (night ? '#8dbeff' : '#1765c1') + ';}' +
    (night ? 'img.invertFilter{filter:invert(100%);}' : '') +
    '</style></head><body>' + content + '</body></html>';
}
function render(content, night = false) {
  return parseNativeArticleContent(documentHtml(renderArticleContent(content,
    'https://img.nga.cn/attachments/', localSource), night));
}

test('empty content is empty layout, while ordinary text and whitespace remain exact', () => {
  assert.deepEqual(parseNativeArticleContent('').blocks, []);
  assert.deepEqual(parseNativeArticleContent('<body></body>').blocks, []);
  const result = render('  正文\t第一行\n\n第二行  ');
  assert.equal(textOf(result), '  正文\t第一行\n\n第二行  ');
  assert.equal(result.blocks[0].kind, 'paragraph');
});

test('text entity decoding preserves escaped tags, quotes, non-BMP characters and unknown entities', () => {
  const result = parseNativeArticleContent('<body>&lt;img src=&quot;x&quot;&gt; &apos;y&apos; &amp; ' +
    '&nbsp;&#65;&#x1f600; &bogus; &#0; &#xD800; &#1114112; &amp;lt;</body>');
  assert.equal(textOf(result), '<img src="x"> \'y\' & \u00a0A😀 &bogus; &#0; &#xD800; &#1114112; &lt;');
  assert.equal(imagesOf(result).length, 0);
});

test('nested inline font, emphasis and decoration return to their parent styles', () => {
  const result = render('[b]粗[i]斜[u]线[del]删[/del][/u][/i]仍粗[/b]正常');
  const runs = result.blocks[0].inlines;
  assert.equal(textOf(result), '粗斜线删仍粗正常');
  assert.deepEqual(runs.map(run => [run.text, run.bold, run.italic, run.underline, run.strike]), [
    ['粗', true, false, false, false], ['斜', true, true, false, false],
    ['线', true, true, true, false], ['删', true, true, true, true],
    ['仍粗', true, false, false, false], ['正常', false, false, false, false]
  ]);
});

test('nested colors and font percentages are inherited and restored without leaking styles', () => {
  const result = render('[color=red]红[color=#123456][size=150]大蓝[/size]蓝[/color]红[/color]正常');
  assert.deepEqual(result.blocks[0].inlines.map(run => [run.text, run.color, run.size]), [
    ['红', '#ff0000', 1], ['大蓝', '#123456', 1.5], ['蓝', '#123456', 1],
    ['红', '#ff0000', 1], ['正常', '', 1]
  ]);
});

test('CSS alpha colors use native ARGB ordering, while unsafe or unsupported color values inherit', () => {
  const result = parseNativeArticleContent('<span style="color:#abc">三</span>' +
    '<span style="color:#1234">四</span><span style="color:#11223344">八</span>' +
    '<span style="color:url(javascript:alert(1))">安全</span>');
  assert.deepEqual(result.blocks[0].inlines.map(run => run.color), ['#aabbcc', '#44112233', '#44112233', '']);
});

test('safe generated hyperlinks and quoted user/floor metadata retain their labels and URLs', () => {
  const result = render('[url=https://example.com/x?q=1&v=2]外链[/url] ' +
    '[uid=123]用户名[/uid] [pid=456,789,1]楼层[/pid]');
  assert.equal(textOf(result), '外链 用户名 楼层');
  const runs = result.blocks[0].inlines;
  assert.equal(runs.find(run => run.text === '外链').link, 'https://example.com/x?q=1&v=2');
  assert.equal(runs.find(run => run.text === '楼层').link, 'https://bbs.nga.cn/read.php?searchpost=1&pid=456');
  assert.equal(runs.find(run => run.text.includes('用户名')).link, '');
});

test('unsafe, relative and application-protocol hyperlinks cannot become native actions', () => {
  for (const url of ['javascript:alert(1)', 'data:text/html,boom', 'file:///data/private',
    'http://example.com', '/relative', 'nga-image:https%3A%2F%2Fexample.com%2Fx.png',
    'https://example.com/&#x22;']) {
    const result = parseNativeArticleContent('<a href="' + url + '">标签</a>');
    assert.equal(textOf(result), '标签');
    assert.equal(result.blocks[0].inlines[0].link, '');
  }
});

test('block quotes preserve nesting, ordinary text and formatting across boundaries', () => {
  const result = render('[b]前[quote]一[quote]二[/quote]三[/quote]后[/b]');
  assert.deepEqual(result.blocks.map(block => [textOf({ blocks: [block] }), block.quoteDepth]), [
    ['前', 0], ['一', 1], ['二', 2], ['三', 1], ['后', 0]
  ]);
  assert.ok(result.blocks.every(block => block.inlines.every(run => run.bold)));
});

test('code blocks preserve literal BBCode, escaped source tags, indentation and all line breaks', () => {
  const result = render('前[code]  <script>never()</script>\n[b]字[/b]\n\n\t末[/code]后');
  assert.deepEqual(result.blocks.map(block => [block.code, textOf({ blocks: [block] })]), [
    [false, '前'], [true, '  <script>never()</script>\n[b]字[/b]\n\n\t末'], [false, '后']
  ]);
  assert.equal(imagesOf(result).length, 0);
});

test('alignment has separate paragraph boundaries and restores the parent alignment', () => {
  const result = render('前[align=center]中[align=right]右[/align]中[/align]后');
  assert.deepEqual(result.blocks.map(block => [textOf({ blocks: [block] }), block.align]), [
    ['前', 'left'], ['中', 'center'], ['右', 'right'], ['中', 'center'], ['后', 'left']
  ]);
});

test('consecutive breaks including empty quote/code lines remain visible layout data', () => {
  const result = parseNativeArticleContent('前<br><br><blockquote><br><br></blockquote><pre>\n\n</pre>后');
  assert.deepEqual(result.blocks.map(block => [textOf({ blocks: [block] }), block.quoteDepth, block.code]), [
    ['前\n\n', 0, false], ['\n\n', 1, false], ['\n\n', 0, true], ['后', 0, false]
  ]);
});

test('empty quoted/code sections retain a native block boundary without inventing body text', () => {
  const result = parseNativeArticleContent('前<blockquote></blockquote><pre></pre>后');
  assert.deepEqual(result.blocks.map(block => [textOf({ blocks: [block] }), block.quoteDepth, block.code]), [
    ['前', 0, false], ['', 1, false], ['', 0, true], ['后', 0, false]
  ]);
  assert.equal(textOf(result), '前后');
});

test('only generated attachment URLs become full-size image blocks with view/save targets', () => {
  const body = renderArticleContent('前[img]./mon_202610/13/a.jpg?x=1&y=2[/img]后');
  const result = parseNativeArticleContent(documentHtml(body));
  assert.deepEqual(result.blocks.map(block => block.kind), ['paragraph', 'image', 'paragraph']);
  const image = result.blocks[1].image;
  assert.equal(image.src, 'https://img.nga.cn/attachments/mon_202610/13/a.jpg?x=1&y=2');
  assert.equal(image.openUrl, articleImageSources(body)[0]);
  assert.equal(image.alt, '图片');
  assert.equal(image.rawfilePath, '');
});

test('image blocks retain their quote depth and alignment without losing following paragraph text', () => {
  const result = render('[quote][align=center]前[img]https://example.com/a.png[/img]后[/align][/quote]外');
  assert.deepEqual(result.blocks.map(block => [block.kind, block.quoteDepth, block.align]), [
    ['paragraph', 1, 'center'], ['image', 1, 'center'], ['paragraph', 1, 'center'], ['paragraph', 0, 'left']
  ]);
  assert.equal(textOf(result), '前后外');
});

test('current editor local JPEG/PNG thumbnails render as block images without remote save targets', () => {
  for (const mime of ['png', 'jpeg']) {
    const data = 'data:image/' + mime + ';base64,AQID';
    const body = renderArticleContent('[img]https://example.com/a.png[/img]',
      'https://img.nga.cn/attachments/', undefined, 'https://bbs.nga.cn/', () => data);
    const result = parseNativeArticleContent(documentHtml(body));
    assert.equal(result.blocks[0].kind, 'image');
    assert.equal(result.blocks[0].image.src, data);
    assert.equal(result.blocks[0].image.openUrl, '');
  }
});

test('bundled adjacent category and legacy emoticons remain inline with real rawfile paths', () => {
  const result = render('前[s:ac:哭笑][s:a2:jojo立5][s:1][s::1]后');
  const images = imagesOf(result);
  assert.equal(images.length, 4);
  assert.equal(result.blocks.length, 1);
  assert.deepEqual(images.map(image => image.rawfilePath), [getEmoticonRawfilePath('ac', '哭笑'),
    getEmoticonRawfilePath('a2', 'jojo立5'), getLegacyEmoticonRawfilePath('1'), getLegacyEmoticonRawfilePath('1')]);
  assert.ok(images.every(image => fs.existsSync(path.join(rawfiles, image.rawfilePath))));
  assert.ok(images.every(image => image.src.startsWith('data:image/') && image.openUrl === '' && !image.invert));
  assert.equal(textOf(result), '前后');
});

test('decorative HTTPS emoticons can recover bundled assets from their original attachment URL', () => {
  const url = getEmoticonImageUrl('ac', '哭笑');
  const result = parseNativeArticleContent('<img class="emoticon" src="' + url + '" alt="图片">');
  assert.equal(result.blocks[0].inlines[0].image.rawfilePath, getEmoticonRawfilePath('ac', '哭笑'));
  assert.equal(result.blocks[0].inlines[0].image.openUrl, '');
});

test('old img emoticon URLs retain mapped rawfile metadata when replaced by real local GIF/PNG data', () => {
  for (const [url, expected] of [
    ['https://img4.nga.cn/ngabbs/post/smile/smile.gif', getLegacyEmoticonRawfilePath('1')],
    ['http://img.nga.178.com/attachments/mon_201209/14/-47218_5052bc4cc6331.png?x=1',
      getEmoticonRawfilePath('ac', '哭笑')],
    [getEmoticonImageUrl('ac', '喘'), getEmoticonRawfilePath('ac', '喘')]
  ]) {
    const body = renderArticleContent('[img]' + url + '[/img]',
      'https://img.nga.cn/attachments/', localSource);
    assert.ok(body.includes('data-nga-rawfile="' + expected + '"'));
    const image = imagesOf(parseNativeArticleContent(documentHtml(body)))[0];
    assert.equal(image.rawfilePath, expected);
    assert.equal(image.alt, '图片');
    assert.equal(image.src, localSource(expected));
    assert.equal(image.openUrl, '');
    assert.deepEqual(articleImageSources(body), []);
  }
});

test('rawfile metadata cannot name an arbitrary bundled file, wrong category, or traversed path', () => {
  for (const hint of ['../private.txt', 'emoticon/../../private.txt', 'emoticon/legacy/../smile.gif',
    'emoticon/legacy/not-mapped.gif', 'emoticon/other/smile.gif', 'emoticon/ac/smile.gif',
    'emoticon/legacy/-47218_5052bc4cc6331.png', '/emoticon/legacy/smile.gif',
    'emoticon/legacy/smile.gif?x=1', 'emoticon/legacy/smile.gif#x', 'other/legacy/smile.gif',
    'emoticon/legacy/smile%2egif', 'file:///emoticon/legacy/smile.gif']) {
    const result = parseNativeArticleContent('<img class="emoticon" src="data:image/png;base64,AQID" ' +
      'alt="图片" data-nga-rawfile="' + hint + '">');
    const image = imagesOf(result)[0];
    assert.equal(image.rawfilePath, '', hint);
    assert.equal(image.src, 'data:image/png;base64,AQID');
    assert.equal(image.openUrl, '');
  }
});

test('a valid alt token remains authoritative over a different mapped rawfile hint', () => {
  const result = parseNativeArticleContent('<img class="emoticon" src="data:image/gif;base64,AQID" ' +
    'alt="[s:1]" data-nga-rawfile="emoticon/legacy/mrgreen.gif">');
  assert.equal(imagesOf(result)[0].rawfilePath, getLegacyEmoticonRawfilePath('1'));
  const ordinary = parseNativeArticleContent('<img class="article-image" src="data:image/png;base64,AQID" ' +
    'alt="图片" data-nga-rawfile="emoticon/legacy/smile.gif">');
  assert.equal(imagesOf(ordinary)[0].rawfilePath, '');
});

test('ordinary attachment markup and native image action allowlists stay exact after rawfile metadata', () => {
  const body = renderArticleContent('[img]https://example.com/a.png[/img]',
    'https://img.nga.cn/attachments/', localSource);
  assert.equal(body, '<a class="article-image-link" href="nga-image:https%3A%2F%2Fexample.com%2Fa.png">' +
    '<img class="article-image" src="https://example.com/a.png" alt="图片"></a>');
  assert.deepEqual(articleImageSources(body), ['https://example.com/a.png']);
  assert.equal(imagesOf(parseNativeArticleContent(body))[0].openUrl, 'https://example.com/a.png');
});

test('night-time inversion applies only to marked AC/a2 emoticons, not attachments or ordinary emojis', () => {
  const result = render('[s:ac:哭笑][s:1][img]https://example.com/a.png[/img]', true);
  assert.deepEqual(imagesOf(result).map(image => image.invert), [true, false, false]);
});

test('malicious and non-generated image protocols fall back to alt text without load/action targets', () => {
  for (const src of ['javascript:alert(1)', 'data:image/svg+xml;base64,AQID', 'file:///data/private',
    'http://example.com/a.png', '//example.com/a.png', 'data:image/png;base64,',
    'data:image/png;base64,A!', 'https://example.com/&#x22;']) {
    const result = parseNativeArticleContent('<img class="article-image" src="' + src + '" alt="图片">');
    assert.equal(imagesOf(result).length, 0, src);
    assert.equal(textOf(result), '图片');
  }
  for (const html of ['<img src="https://example.com/a.png" alt="未识别">',
    '<img class="other article-image" src="https://example.com/a.png" alt="未识别">',
    '<img class="article-image" src="https://example.com/a.png" alt="不是生成图片">']) {
    assert.equal(imagesOf(parseNativeArticleContent(html)).length, 0);
  }
});

test('oversized local inline data cannot create a native image, but surrounding text remains', () => {
  const source = 'data:image/png;base64,' + 'AAAA'.repeat(65536);
  const result = parseNativeArticleContent('前<img class="emoticon" src="' + source + '" alt="表情">后');
  assert.equal(imagesOf(result).length, 0);
  assert.equal(textOf(result), '前表情后');
});

test('unknown tags keep readable children while comments, head, script and style do not expose source', () => {
  const result = parseNativeArticleContent('<head><style>body{color:red}</style><script>bad()</script></head>' +
    '<widget class="x">正文<b>粗</b></widget><!-- secret --><script><b>bad()</b></script>' +
    '<style>some{secret}</style><iframe>后</iframe>');
  assert.equal(textOf(result), '正文粗后');
  assert.equal(result.blocks[0].inlines[1].bold, true);
  assert.ok(!textOf(result).includes('bad') && !textOf(result).includes('secret'));
});

test('malformed/misnested styles degrade safely without losing visible text', () => {
  const result = parseNativeArticleContent('前<b><i>中</b>后</i><unknown>尾');
  assert.equal(textOf(result), '前中后尾');
  assert.equal(result.blocks[0].inlines.find(run => run.text === '中').italic, true);
  assert.equal(result.blocks[0].inlines.find(run => run.text === '后').bold, false);
});

test('document colors, font size and unitless line height are taken only from the generated head', () => {
  for (const preview of [false, true]) {
    const day = parseNativeArticleContent(documentHtml('正文', false, preview));
    const night = parseNativeArticleContent(documentHtml('正文', true, preview));
    assert.deepEqual([day.fontSize, day.lineHeight, day.textColor, day.linkColor, day.quoteColor, day.invertEmoticons],
      [16, 28, '#182538', '#1765c1', '#1765c1', false]);
    assert.deepEqual([night.fontSize, night.lineHeight, night.textColor, night.linkColor, night.quoteColor, night.invertEmoticons],
      [16, 28, '#e9eff8', '#8dbeff', '#8dbeff', true]);
    assert.equal(textOf(day), textOf(night));
  }
  const result = parseNativeArticleContent('<style>body{color:#ff0000}</style>正文');
  assert.equal(result.textColor, '#182538');
});

test('absolute line-height and safe native bounds handle a valid alternative generated typography', () => {
  const result = parseNativeArticleContent('<html><head><style>body{color:#abc;font-size:18px;line-height:30px;}' +
    'a{color:blue;}blockquote{border-left:3px solid red;}</style></head><body>正文</body></html>');
  assert.deepEqual([result.fontSize, result.lineHeight, result.textColor, result.linkColor, result.quoteColor],
    [18, 30, '#aabbcc', '#0000ff', '#ff0000']);
});

test('very long paragraphs are bounded, remain complete, and retain every nested style', () => {
  const content = '长'.repeat(NATIVE_ARTICLE_PARAGRAPH_LIMIT * 20 + 87);
  const result = render('[quote][b]' + content + '[/b][/quote]末');
  assert.equal(textOf(result), content + '末');
  assert.equal(result.blocks.length, 22);
  assert.ok(result.blocks.every(block => paragraphLength(block) <= NATIVE_ARTICLE_PARAGRAPH_LIMIT));
  assert.ok(result.blocks.slice(0, -1).every(block => block.quoteDepth === 1 && block.inlines.every(run => run.bold)));
  assert.equal(result.blocks.at(-1).quoteDepth, 0);
});

test('paragraph boundaries never split a UTF-16 surrogate pair, including one character remaining', () => {
  for (const prefix of [NATIVE_ARTICLE_PARAGRAPH_LIMIT - 1, NATIVE_ARTICLE_PARAGRAPH_LIMIT,
    NATIVE_ARTICLE_PARAGRAPH_LIMIT * 2 - 1]) {
    const content = '字'.repeat(prefix) + '😀' + '尾'.repeat(NATIVE_ARTICLE_PARAGRAPH_LIMIT + 3);
    const result = render(content);
    assert.equal(textOf(result), content);
    assert.ok(result.blocks.every(block => paragraphLength(block) <= NATIVE_ARTICLE_PARAGRAPH_LIMIT));
    for (const block of result.blocks) {
      const text = textOf({ blocks: [block] });
      assert.ok(!/[\ud800-\udbff]$/.test(text), 'block ends in half of an emoji');
      assert.ok(!/^[\udc00-\udfff]/.test(text), 'block starts in half of an emoji');
    }
  }
});

test('a paragraph filled with inline emoticons splits at the same bound without dropping image tokens', () => {
  const html = '<img class="emoticon" src="data:image/png;base64,AQID" alt="表情">'
    .repeat(NATIVE_ARTICLE_PARAGRAPH_LIMIT + 7);
  const result = parseNativeArticleContent(html);
  assert.equal(imagesOf(result).length, NATIVE_ARTICLE_PARAGRAPH_LIMIT + 7);
  assert.deepEqual(result.blocks.map(paragraphLength), [NATIVE_ARTICLE_PARAGRAPH_LIMIT, 7]);
});

test('day/night transitions retain all body tokens, image targets and native block identities', () => {
  const body = renderArticleContent('[quote]引用[color=#ff0000]红[/color][s:ac:哭笑][/quote]' +
    '[align=center][img]./mon_202610/13/a.jpg[/img][/align][code]<b>代码</b>\n尾[/code]',
    'https://img.nga.cn/attachments/', localSource);
  const day = parseNativeArticleContent(documentHtml(body));
  const night = parseNativeArticleContent(documentHtml(body, true));
  const normalize = document => JSON.stringify(document.blocks, (key, value) => key === 'invert' ? false : value);
  assert.equal(normalize(day), normalize(night));
  const identities = day.blocks.flatMap(block => [block.id, ...block.inlines.map(run => run.id)]);
  assert.equal(new Set(identities).size, identities.length);
});

test('public main/reply media fixtures preserve all attachment images and bundled reply emoticons', () => {
  const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/article-public-media.json'), 'utf8'));
  const main = render(fixture.mainContent);
  const reply = render(fixture.reply17Content);
  assert.equal(main.blocks.filter(block => block.kind === 'image').length, 3);
  assert.equal(reply.blocks.filter(block => block.kind === 'image').length, 1);
  assert.equal(imagesOf(reply).filter(image => image.rawfilePath).length, 1);
  assert.ok(imagesOf(main).every(image => image.openUrl.startsWith('https://img.nga.cn/attachments/')));
  assert.ok(textOf(main).length > 0 && textOf(reply).length > 0);
});

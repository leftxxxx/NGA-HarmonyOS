/* node tools/test-article-html.cjs [--live]: tests actual .ets pure functions. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const devecoHome = process.env.DEVECO_HOME || 'D:\\software\\DevEco Studio';
const ts = require(process.env.TYPESCRIPT_PATH || path.join(devecoHome,
  'tools/hvigor/hvigor-ohos-plugin/node_modules/typescript'));
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  assert.equal((result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  module._compile(result.outputText, filename);
};
const { renderArticleContent, resolveArticleImageUrl, articleImageSources, articleImageFromLink,
  articleHtmlHasOnlyThemeChange } =
  require('../entry/src/main/ets/model/ArticleHtml.ets');
const {
  EMOTION_CATEGORIES, getEmoticonList, getEmoticonRawfilePath, getLegacyEmoticonRawfilePath,
  decodeAllEmoticons, getPathByUrl, getEmoticonImageUrl
} = require('../entry/src/main/ets/model/EmoticonUtils.ets');
const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/article-public-media.json'), 'utf8'));
const rawfileRoot = path.resolve(__dirname, '../entry/src/main/resources/rawfile');
const localSource = rawfile => {
  const data = fs.readFileSync(path.join(rawfileRoot, rawfile));
  return 'data:image/' + (rawfile.endsWith('.gif') ? 'gif' : 'png') + ';base64,' + data.toString('base64');
};
const imageCount = html => (html.match(/<img\b/g) || []).length;

const themedDocument = (content, night, extraCss = '') => {
  const background = night ? '#192333' : '#ffffff';
  const text = night ? '#e9eff8' : '#182538';
  const accent = night ? '#8dbeff' : '#1765c1';
  return '<!DOCTYPE html><html><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1.0"><style>' +
    'html{background:' + background + ';}body{background:' + background + ';color:' + text +
    ';font-size:16px;line-height:1.75;padding:0;margin:0;overflow-wrap:anywhere;}' +
    'img{max-width:100%;height:auto;}blockquote{margin:8px 0;padding:8px;border-left:3px solid ' + accent + ';}' +
    (night ? 'img.invertFilter{filter:invert(100%);}' : '') + 'a{color:' + accent + ';}' + extraCss +
    '</style></head><body>' + renderArticleContent(content) + '</body></html>';
};

test('only generated head colors and the night emoticon filter identify a theme transition', () => {
  const body = '[color=#ff0000]红字[/color][quote]引用[/quote]' +
    '[code]body{color:#abcdef;}[/code][img]https://img.nga.cn/attachments/a.png[/img]';
  const day = themedDocument(body, false), night = themedDocument(body, true);
  assert.equal(articleHtmlHasOnlyThemeChange(day, night), true);
  assert.equal(articleHtmlHasOnlyThemeChange(night, day), true);
  assert.deepEqual(articleImageSources(day), articleImageSources(night));
  const previewDay = day.replace('html{background:#ffffff;}body{background:#ffffff;',
    'html,body{background:#ffffff;');
  const previewNight = night.replace('html{background:#192333;}body{background:#192333;',
    'html,body{background:#192333;');
  assert.equal(articleHtmlHasOnlyThemeChange(previewDay, previewNight), true);
});

test('theme classification retains exact body markup, image URLs, viewport and all layout rules', () => {
  const body = '原正文[color=#ff0000]红字[/color][img]https://img.nga.cn/attachments/a.png[/img]';
  const previous = themedDocument(body, false), night = themedDocument(body, true);
  for (const next of [
    themedDocument(body.replace('原正文', '新正文'), true),
    themedDocument(body.replace('a.png', 'b.png'), true),
    themedDocument(body.replace('#ff0000', '#00ff00'), true),
    themedDocument('没有图片', true),
    night.replace('font-size:16px', 'font-size:20px'),
    night.replace('line-height:1.75', 'line-height:2'),
    night.replace('border-left:3px', 'border-left:6px'),
    night.replace('initial-scale=1.0', 'initial-scale=1.5'),
    night.replace('invert(100%)', 'invert(50%)')
  ]) {
    assert.equal(articleHtmlHasOnlyThemeChange(previous, next), false);
  }
});

test('initial, identical or body-only HTML must use the ordinary reload path', () => {
  const day = themedDocument('正文', false);
  assert.equal(articleHtmlHasOnlyThemeChange('', day), false);
  assert.equal(articleHtmlHasOnlyThemeChange(day, day), false);
  assert.equal(articleHtmlHasOnlyThemeChange('<body style="color:#ffffff">正文</body>',
    '<body style="color:#192333">正文</body>'), false);
});

test('actual public main post renders three HTTPS attachments and line breaks', () => {
  const html = renderArticleContent(fixture.mainContent, fixture.attachmentBase, localSource);
  assert.equal(imageCount(html), 3);
  assert.equal((html.match(/class="article-image"/g) || []).length, 3);
  assert.ok(!html.includes('[img]'));
  for (const filename of ['7Q82-2yhpZhT3cSsg-f2.jpg', '7Q83-uyeZgT3cSsg-f2.jpg', '7Q41-8jv3ZhT3cSsg-ez.jpg']) {
    assert.ok(html.includes(filename));
  }
  assert.ok(html.includes('src="https://img.nga.cn/attachments/mon_202610/'));
  assert.ok(html.includes('<br>'));
});

test('actual public reply renders WEBP photo and bundled a2 emoticon', () => {
  const html = renderArticleContent(fixture.reply17Content, fixture.attachmentBase, localSource);
  assert.equal(imageCount(html), 2);
  assert.ok(html.includes('7Q85-9srsZdT3cS1z4-140.webp'));
  assert.ok(html.includes("class='emoticon invertFilter'"));
  assert.ok(html.includes('data:image/png;base64,'));
  assert.ok(!html.includes('[s:a2:jojo立5]') || html.includes("alt='[s:a2:jojo立5]'"));
});

test('repeated, adjacent, and mixed emoticons all decode using real local assets', () => {
  const content = '[s:ac:哭笑][s:ac:哭笑][s:a2:jojo立5][s:pg:吃瓜][s:pst:举手][s:dt:ROLL]';
  const html = renderArticleContent(content, fixture.attachmentBase, localSource);
  assert.equal(imageCount(html), 6);
  assert.equal((html.match(/data:image\/png;base64,/g) || []).length, 6);
  assert.equal(imageCount(renderArticleContent(fixture.otherReplyEmoticonTokens.join(''), fixture.attachmentBase, localSource)), 4);
});

test('every one of 238 classified mappings names an actual PNG/GIF rawfile', () => {
  let total = 0;
  for (const category of EMOTION_CATEGORIES) {
    for (const name of getEmoticonList(category)) {
      const rawfile = getEmoticonRawfilePath(category, name);
      const data = fs.readFileSync(path.join(rawfileRoot, rawfile));
      assert.ok(data.subarray(0, 4).equals(Buffer.from([137, 80, 78, 71])) || data.subarray(0, 3).toString() === 'GIF');
      assert.equal(imageCount(decodeAllEmoticons('[s:' + category + ':' + name + ']', localSource)), 1);
      total++;
    }
  }
  assert.equal(total, 238);
});

test('new NG and numeric category emoticons also render inside reply quotes and links', () => {
  const html = renderArticleContent('[quote][s:ng:呲牙笑][s:ng:奸笑][s:ng:doge][s:0:1][s::1]' +
    '[url=https://bbs.nga.cn/][s:ng:茶][/url][/quote]', fixture.attachmentBase, localSource);
  assert.equal(imageCount(html), 6);
  assert.equal((html.match(/data:image\//g) || []).length, 6);
  assert.ok(!/\ue000|\ue001/.test(html));
  assert.ok(html.includes('<blockquote>'));
});

test('official 27 numeric mappings use real bundled GIFs; undefined codes stay readable', () => {
  let count = 0;
  for (let number = 1; number <= 43; number++) {
    const rawfile = getLegacyEmoticonRawfilePath(String(number));
    const token = '[s:' + number + ']';
    const html = decodeAllEmoticons(token, localSource);
    if (rawfile) {
      assert.ok(fs.readFileSync(path.join(rawfileRoot, rawfile)).subarray(0, 6).toString().startsWith('GIF8'));
      assert.equal(imageCount(html), 1);
      assert.ok(html.includes('data:image/gif;base64,'));
      count++;
    } else {
      assert.equal(html, token);
    }
  }
  assert.equal(count, 27);
  assert.equal(decodeAllEmoticons('[s:unknown:name][s:__proto__:toString]', localSource), '[s:unknown:name][s:__proto__:toString]');
});

test('image path variants resolve safely and preserve query strings and animated GIFs', () => {
  const expected = 'https://img.nga.cn/attachments/mon_202610/03/a.jpg';
  for (const value of ['./mon_202610/03/a.jpg', 'mon_202610/03/a.jpg', '/attachments/mon_202610/03/a.jpg', 'attachments/mon_202610/03/a.jpg']) {
    assert.equal(resolveArticleImageUrl(value, fixture.attachmentBase), expected);
  }
  assert.equal(resolveArticleImageUrl('http://example.com/a.gif.thumb.jpg?x=1&amp;y=2'), 'https://example.com/a.gif?x=1&y=2');
  assert.equal(resolveArticleImageUrl('//example.com/a.webp'), 'https://example.com/a.webp');
  assert.equal(imageCount(renderArticleContent('[IMG=600,400] ./mon_202610/03/a.jpg [/IMG]', fixture.attachmentBase)), 1);
});

test('NGA numbered image tags render attachments and emoticon images inside replies', () => {
  const html = renderArticleContent('[quote][b]Reply to [pid=123,456,3]Reply[/pid] Post by [uid=789]昵称[/uid][/b]' +
    '[img0]./mon_202610/03/a.jpg[/img][IMG50]//img.nga.cn/attachments/mon_202610/03/b.webp[/IMG]' +
    '[img100]http://img.nga.178.com/attachments/mon_201209/14/-47218_5052bc4cc6331.png[/img][/quote]',
    fixture.attachmentBase, localSource);
  assert.equal(imageCount(html), 3);
  assert.ok(html.includes('data:image/png;base64,'));
  assert.ok(html.includes('<blockquote>'));
  assert.ok(html.includes('href="https://bbs.nga.cn/read.php?searchpost=1&amp;pid=123"'));
  assert.ok(html.includes('昵称'));
  assert.ok(!/\[(?:img\d*|\/?pid|\/?uid)[^\]]*\]/i.test(html));
  assert.equal(imageCount(renderArticleContent('[img-1]二维码内容[/img]')), 0);
  assert.ok(!renderArticleContent('[pid=1,2,3][uid=123]name[/uid][s:ac:哭笑][/pid]',
    fixture.attachmentBase, localSource).includes('[uid='));
});

test('legacy raw and entity-encoded HTML images are rebuilt with safe attributes', () => {
  const html = renderArticleContent('<img src="http://img.nga.cn/attachments/mon_202610/03/a.jpg" onerror="bad()">' +
    '&lt;img src=&#39;./mon_202610/03/b.webp&#39; width=600&gt;' +
    '<IMG class="smile" src="http://img.nga.178.com/attachments/mon_201209/14/-47218_5052bc4cc6331.png">',
    fixture.attachmentBase, localSource);
  assert.equal(imageCount(html), 3);
  assert.ok(html.includes('data:image/png;base64,'));
  assert.ok(!/<[^>]+\son\w+=/i.test(html));
  assert.ok(!html.includes('bad()'));
  assert.ok(!html.includes('&lt;img'));
  assert.equal(imageCount(renderArticleContent('[code]<img src="https://x.test/a.jpg">[img50]./a.jpg[/img][s:ac:哭笑][/code]')), 0);
  assert.equal(imageCount(renderArticleContent('<img src="javascript:bad()"><img src="file:///a.jpg"><img src="data:image/svg+xml,test">')), 0);
});

test('existing smile image URLs reuse bundled resources even with a query string', () => {
  const url = 'http://img.nga.178.com/attachments/mon_201209/14/-47218_5052bc4cc6331.png?x=1';
  assert.equal(getPathByUrl(url), 'emoticon/ac/-47218_5052bc4cc6331.png');
  assert.ok(renderArticleContent('[img]' + url + '[/img]', fixture.attachmentBase, localSource).includes('data:image/png;base64,'));
  assert.equal(getEmoticonImageUrl('ac', '哭笑'), 'https://img.nga.cn/attachments/mon_201209/14/-47218_5052bc4cc6331.png');
});

test('formatting, HTML entities, and code samples retain their intended content', () => {
  const html = renderArticleContent('A &amp; B &lt;C&gt;<br/>[align=center][b]标题[/b][/align]\n[quote]回复[/quote][code][img]./x.jpg[/img]<script>sample</script>[/code]');
  assert.ok(html.includes('A &amp; B &lt;C&gt;<br>'));
  assert.ok(html.includes('<div style="text-align:center"><b>标题</b></div>'));
  assert.ok(html.includes('<blockquote>回复</blockquote>'));
  assert.ok(html.includes('<pre>[img]./x.jpg[/img]&lt;script&gt;sample&lt;/script&gt;</pre>'));
  assert.equal(imageCount(html), 0);
  assert.equal(renderArticleContent('第一行&lt;br/&gt;第二行<BR />第三行'), '第一行<br>第二行<br>第三行');
  assert.equal(renderArticleContent('[code]<br/>[s::1][/code]'), '<pre>&lt;br/&gt;[s::1]</pre>');
});

test('raw scripts, event attributes, dangerous URLs, and encoded controls never produce active markup', () => {
  const html = renderArticleContent('<script>alert(1)</script><img src=x onerror=alert(1)>' +
    '[img]javascript:alert(1)[/img][img]data:image/svg+xml,test[/img]' +
    '[url=javascript&#58;alert(1)]点击[/url][img]https://x.test/a.jpg\" onerror=\"alert(1)[/img]' +
    '[img]https://x.test/&#10;bad.jpg[/img]');
  assert.ok(!/<(?:script|iframe|svg)\b/i.test(html));
  assert.ok(!/<[^>]+\son\w+=/i.test(html));
  assert.ok(!/(?:href|src)=["'](?:javascript|data:image\/svg)/i.test(html));
  assert.equal(imageCount(html), 0);
  assert.ok(html.includes('&lt;script&gt;'));
  assert.equal(imageCount(renderArticleContent('[s:ac:哭笑]', fixture.attachmentBase, () => "javascript:alert(1)' onerror='x")), 0);
});

test('optional real public image URLs return image responses', { skip: !process.argv.includes('--live') }, async () => {
  const html = renderArticleContent(fixture.mainContent, fixture.attachmentBase);
  for (const match of html.matchAll(/src="([^"]+)"/g)) {
    const response = await fetch(match[1], { signal: AbortSignal.timeout(15000) });
    assert.equal(response.status, 200);
    assert.ok(response.headers.get('content-type').startsWith('image/'));
    await response.body?.cancel();
  }
});

test('native image links only open safe images present in the rendered article', () => {
  const url = 'https://img.nga.cn/attachments/mon_202610/08/a.jpg?x=1&y=2';
  const html = renderArticleContent('[img]' + url + '[/img][img]' + url + '[/img]' +
    '[code][img]https://other.test/code.jpg[/img][/code][s:ac:哭笑]', fixture.attachmentBase, localSource);
  assert.deepEqual(articleImageSources(html), [url]);
  const link = 'nga-image:' + encodeURIComponent(url);
  assert.ok(html.includes('href="' + link + '"'));
  assert.equal(articleImageFromLink(link, html), url);
  for (const target of ['https://other.test/absent.jpg', 'javascript:alert(1)', 'file:///private/a.jpg']) {
    assert.equal(articleImageFromLink('nga-image:' + encodeURIComponent(target), html), '');
  }
  assert.equal(articleImageFromLink('nga-image:%invalid', html), '');
  assert.equal(articleImageFromLink('https://img.nga.cn/', html), '');
  assert.equal(articleImageFromLink(link, renderArticleContent('no image')), '');
  assert.equal(articleImageSources(html).some(source => source.startsWith('data:')), false);
});

test('numeric entities in image queries normalize consistently for clicking and long-press saving', () => {
  const content = '[img]https://images.test/a.jpg?x=1&#38;y=2&#x26;z=3[/img]';
  const html = renderArticleContent(content);
  const source = 'https://images.test/a.jpg?x=1&y=2&z=3';
  assert.deepEqual(articleImageSources(html), [source]);
  assert.equal(articleImageFromLink('nga-image:' + encodeURIComponent(source), html), source);
  assert.ok(html.includes('src="https://images.test/a.jpg?x=1&amp;y=2&amp;z=3"'));
  assert.equal(articleImageSources(renderArticleContent('[img]https://images.test/&#x0a;a.jpg[/img]')).length, 0);
});

test('current-editor image callback receives canonical attachment URLs and renders safe local thumbnails', () => {
  const target = 'https://img.nga.cn/attachments/mon_202610/08/new.jpg';
  const thumbnail = localSource(getEmoticonRawfilePath('ac', '哭笑'));
  const requests = [];
  const html = renderArticleContent('[img]./mon_202610/08/new.jpg[/img]', fixture.attachmentBase,
    undefined, 'https://bbs.nga.cn/', url => { requests.push(url); return thumbnail; });
  assert.deepEqual(requests, [target]);
  assert.ok(html.includes('<img class="article-image" src="' + thumbnail + '"'));
  assert.ok(!html.includes('nga-image:'));
  assert.deepEqual(articleImageSources(html), []);
  assert.equal(articleImageFromLink('nga-image:' + encodeURIComponent(target), html), '');
  // A normal post without the current editor's map still uses the server attachment URL.
  assert.deepEqual(articleImageSources(renderArticleContent('[img]./mon_202610/08/new.jpg[/img]')), [target]);
});

test('editor thumbnail allowlist rejects unsafe, malformed, empty, oversized, and unsupported data sources', () => {
  const target = 'https://img.nga.cn/attachments/mon_202610/08/new.jpg';
  const content = '[img]' + target + '[/img]';
  for (const thumbnail of ['javascript:alert(1)', 'data:image/svg+xml;base64,PHN2Zz4=',
    'data:image/gif;base64,R0lGODlh', 'data:image/webp;base64,UklGRg==', 'data:image/png;base64,',
    'data:image/png;base64,abc', 'data:image/png;base64,ab==cd==', 'data:image/png;base64,YQ==\n',
    'data:image/png;base64,YQ==" onerror="bad()', 'data:image/png;base64,' + 'AAAA'.repeat(65536)]) {
    const html = renderArticleContent(content, fixture.attachmentBase, undefined, 'https://bbs.nga.cn/', () => thumbnail);
    assert.deepEqual(articleImageSources(html), [target]);
    assert.ok(!html.includes('src="data:'));
  }
  const html = renderArticleContent(content, fixture.attachmentBase, undefined, 'https://bbs.nga.cn/', () => {
    throw new Error('fixture source unavailable');
  });
  assert.deepEqual(articleImageSources(html), [target]);
});

test('editor thumbnails preserve local emoticon priority and code-block protection', () => {
  const emoticonUrl = getEmoticonImageUrl('ac', '哭笑');
  let calls = 0;
  const content = '[img]' + emoticonUrl + '[/img][code][img]./mon_202610/08/new.jpg[/img][/code]';
  const html = renderArticleContent(content, fixture.attachmentBase, localSource, 'https://bbs.nga.cn/', () => {
    calls++; return 'data:image/jpeg;base64,/9j/AA==';
  });
  assert.equal(calls, 0);
  assert.ok(html.includes('class="emoticon invertFilter"'));
  assert.equal(imageCount(html), 1);
  assert.deepEqual(articleImageSources(html), []);
});

test('safe JPEG editor data works for legacy HTML image tags without entering remote article actions', () => {
  const html = renderArticleContent('<img src="./mon_202610/08/new.jpg">', fixture.attachmentBase,
    undefined, 'https://bbs.nga.cn/', () => 'data:image/jpeg;base64,/9j/AA==');
  assert.ok(html.includes('src="data:image/jpeg;base64,/9j/AA=="'));
  assert.equal(imageCount(html), 1);
  assert.deepEqual(articleImageSources(html), []);
});

import { decodeAllEmoticons, getPathByUrl, LocalEmoticonSource } from './EmoticonUtils';

const DEFAULT_ATTACHMENT_BASE: string = 'https://img.nga.cn/attachments/';
const MAX_LOCAL_IMAGE_SOURCE_LENGTH: number = 256 * 1024;

/** Current-editor thumbnails keyed by their resolved HTTPS attachment URL. */
export type LocalArticleImageSource = (url: string) => string;

function escapeHtml(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/** 仅解码标准文字实体；解码后仍需先转义，再输出允许的 BBCode。 */
function decodeEntities(value: string): string {
  const named: Record<string, string> = {};
  named['amp'] = '&';
  named['lt'] = '<';
  named['gt'] = '>';
  named['quot'] = '"';
  named['apos'] = "'";
  named['nbsp'] = '\u00a0';
  return value.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi,
    (matched: string, entity: string): string => {
      if (entity.startsWith('#')) {
        const hexadecimal: boolean = entity.charAt(1).toLowerCase() === 'x';
        const codePoint: number = parseInt(entity.substring(hexadecimal ? 2 : 1), hexadecimal ? 16 : 10);
        return codePoint > 0 && codePoint <= 0x10ffff && !(codePoint >= 0xd800 && codePoint <= 0xdfff) ?
          String.fromCodePoint(codePoint) : matched;
      }
      return named[entity.toLowerCase()] ?? matched;
    });
}

function httpsUrl(value: string): string {
  const trimmed: string = decodeEntities(value).trim();
  if (/[\s'"<>\\\x00-\x1f\x7f]/.test(trimmed)) {
    return '';
  }
  const url: string = trimmed.startsWith('//') ? 'https:' + trimmed : trimmed.replace(/^http:\/\//i, 'https://');
  return /^https:\/\/[^/?#]+(?:[/?#].*)?$/i.test(url) ? url : '';
}

/** NGA 的 _ATTACH_BASE_VIEW 通常不带协议，例如 img.nga.cn/attachments。 */
function attachmentRoot(base: string): string {
  const normalized: string = decodeEntities(base).trim();
  const candidate: string = /^(?:https?:)?\/\//i.test(normalized) ? normalized : 'https://' + normalized;
  const safe: string = httpsUrl(candidate);
  return safe.length > 0 ? safe.replace(/\/+$/, '') + '/' : DEFAULT_ATTACHMENT_BASE;
}

/** 将论坛附件相对地址变为可从 Web 读取的绝对 HTTPS 图片地址。 */
export function resolveArticleImageUrl(value: string, attachmentBase: string = DEFAULT_ATTACHMENT_BASE,
  forumBase: string = 'https://bbs.nga.cn/'): string {
  let path: string = decodeEntities(value).trim();
  if (/[\s'"<>\\\x00-\x1f\x7f]/.test(path) || /(?:^|\/)\.\.(?:\/|$)/.test(path)) {
    return '';
  }
  path = path.replace(/(\.gif)\.(?:thumb_s|medium|thumb|thumb_ss)\.jpg(?=[?#]|$)/i, '$1');
  if (/^(?:https?:)?\/\//i.test(path)) {
    return httpsUrl(path);
  }
  const base: string = attachmentRoot(attachmentBase);
  if (path.startsWith('./')) {
    return base + path.substring(2);
  }
  if (/^\/?attachments\//i.test(path)) {
    return base + path.replace(/^\/?attachments\//i, '');
  }
  if (/^\/?mon_\d{6}\//i.test(path)) {
    return base + path.replace(/^\//, '');
  }
  if (/^[a-z0-9.-]+\.[a-z]{2,}(?:\:[0-9]+)?\//i.test(path)) {
    return httpsUrl('https://' + path);
  }
  if (path.startsWith('/')) {
    const domain: string = httpsUrl(forumBase).replace(/\/+$/, '');
    return domain.length > 0 ? domain + path : '';
  }
  return '';
}

function resolveArticleLink(value: string, forumBase: string): string {
  const url: string = decodeEntities(value).trim();
  const absolute: string = httpsUrl(url);
  if (absolute.length > 0) {
    return absolute;
  }
  if (/^\/(?!\/)[^\s'"<>\\]*$/.test(url)) {
    const domain: string = httpsUrl(forumBase).replace(/\/+$/, '');
    return domain.length > 0 ? domain + url : '';
  }
  return '';
}

function storeHtml(value: string, fragments: string[]): string {
  const index: number = fragments.push(value) - 1;
  return '\ue000' + index.toString() + '\ue001';
}

/** 不保留来源 HTML 的属性，仅按受支持的地址重新生成图片。 */
function articleImageHtml(target: string, attachmentBase: string,
  localEmoticonSource: LocalEmoticonSource | undefined, forumBase: string,
  localImageSource: LocalArticleImageSource | undefined): string {
  const url: string = resolveArticleImageUrl(target, attachmentBase, forumBase);
  if (url.length === 0) {
    return '';
  }
  const rawfile: string = getPathByUrl(url);
  const local: string = localEmoticonSource !== undefined && rawfile.length > 0 ? localEmoticonSource(rawfile) : '';
  const localValid: boolean = /^data:image\/(?:png|gif|jpe?g|webp);base64,[a-z0-9+/=]+$/i.test(local);
  let thumbnail: string = '';
  if (!localValid && localImageSource !== undefined) {
    try {
      thumbnail = localImageSource(url);
    } catch (error) {
      // A failed editor thumbnail keeps the original remote image available.
    }
  }
  const thumbnailValid: boolean = thumbnail.length > 0 && thumbnail.length <= MAX_LOCAL_IMAGE_SOURCE_LENGTH &&
    /^data:image\/(?:png|jpe?g);base64,(?:[a-z0-9+/]{4})*(?:[a-z0-9+/]{2}==|[a-z0-9+/]{3}=)?$/i.test(thumbnail) &&
    !thumbnail.endsWith(',');
  if (thumbnailValid) {
    // Editor-local data is never an article download/click target.
    return '<img class="article-image" src="' + thumbnail + '" alt="图片">';
  }
  const source: string = localValid ? local : url;
  const imageClass: string = localValid ?
    (rawfile.startsWith('emoticon/ac/') || rawfile.startsWith('emoticon/a2/') ? 'emoticon invertFilter' : 'emoticon') :
    'article-image';
  const image: string = '<img class="' + imageClass + '" src="' + escapeHtml(source) + '" alt="图片">';
  // A native URL interception handles viewing; article JavaScript remains disabled.
  return localValid ? image : '<a class="article-image-link" href="nga-image:' +
    encodeURIComponent(url) + '">' + image + '</a>';
}

/** Only URLs of images actually generated by the safe renderer may open or save. */
export function articleImageSources(html: string): string[] {
  const sources: string[] = [];
  const pattern: RegExp = /<img class="article-image" src="([^"]+)" alt="图片">/g;
  let match: RegExpExecArray | null = pattern.exec(html);
  while (match !== null) {
    const url: string = httpsUrl(match[1] ?? '');
    if (url.length > 0 && !sources.includes(url)) {
      sources.push(url);
    }
    match = pattern.exec(html);
  }
  return sources;
}

export function articleImageFromLink(link: string, html: string): string {
  if (!link.startsWith('nga-image:')) {
    return '';
  }
  try {
    const target: string = decodeURIComponent(link.substring('nga-image:'.length));
    return articleImageSources(html).includes(target) ? target : '';
  } catch (error) {
    return '';
  }
}

/**
 * 纯函数：正文先转义，随后只生成允许的 BBCode HTML。
 * resolver 接收 emoticon/ac/... 等 rawfile 路径，返回本地图片 data URI。
 */
export function renderArticleContent(content: string, attachmentBase: string = DEFAULT_ATTACHMENT_BASE,
  localEmoticonSource?: LocalEmoticonSource, forumBase: string = 'https://bbs.nga.cn/',
  localImageSource?: LocalArticleImageSource): string {
  const fragments: string[] = [];
  let result: string = escapeHtml(decodeEntities(content))
    .replace(/\ue000/g, '&#57344;').replace(/\ue001/g, '&#57345;');

  // 代码块和已生成的图片使用占位符保护，后续替换不再修改其属性或内容。
  result = result.replace(/\[code(?:=[^\]]*)?\]([\s\S]*?)\[\/code\]/gi,
    (matched: string, code: string): string => storeHtml('<pre>' + code + '</pre>', fragments));
  result = result.replace(/&lt;br\s*\/?&gt;/gi, '\n');
  // NGA [img0]/[img50] 等数字为显示尺寸；[img-1] 是二维码，不能按附件解释。
  result = result.replace(/\[img(?:\d{1,3}|=[^\]]*)?\]([\s\S]*?)\[\/img\]/gi,
    (matched: string, target: string): string => {
      const html: string = articleImageHtml(target, attachmentBase, localEmoticonSource, forumBase, localImageSource);
      return html.length > 0 ? storeHtml(html, fragments) : matched;
    });
  // 部分旧回复返回 HTML 图片；从已转义的文本取 src，再生成同一白名单图片。
  result = result.replace(/&lt;img\b([\s\S]*?)&gt;/gi,
    (matched: string, attributes: string): string => {
      const source: RegExpMatchArray | null = decodeEntities(attributes)
        .match(/(?:^|\s)src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/i);
      if (source === null) {
        return matched;
      }
      const html: string = articleImageHtml(source[1] ?? source[2] ?? source[3] ?? '',
        attachmentBase, localEmoticonSource, forumBase, localImageSource);
      return html.length > 0 ? storeHtml(html, fragments) : matched;
    });
  result = result.replace(/\[s:[^\]\r\n]+\]/gi, (matched: string): string => {
    const html: string = decodeAllEmoticons(matched, localEmoticonSource);
    return html !== matched ? storeHtml(html, fragments) : matched;
  });

  // 在链接片段被保护前处理用户标记，兼容引用内的用户名。
  result = result.replace(/\[uid=\d+\]([\s\S]*?)\[\/uid\]/gi,
    (matched: string, label: string): string => label);

  result = result.replace(/\[url=([^\]]+)\]([\s\S]*?)\[\/url\]/gi,
    (matched: string, target: string, label: string): string => {
      const url: string = resolveArticleLink(target, forumBase);
      return url.length > 0 ? storeHtml('<a href="' + escapeHtml(url) + '" rel="noreferrer">' + label + '</a>', fragments) : label;
    });
  result = result.replace(/\[url\]([^\]]+)\[\/url\]/gi,
    (matched: string, target: string): string => {
      const url: string = resolveArticleLink(target, forumBase);
      return url.length > 0 ? storeHtml('<a href="' + escapeHtml(url) + '" rel="noreferrer">' + target + '</a>', fragments) : target;
    });

  // 回复引用中的用户/楼层元信息不应把 UBB 标记暴露给读者。
  result = result.replace(/\[pid=(\d+)(?:,\d+,\d+)?\]([\s\S]*?)\[\/pid\]/gi,
    (matched: string, pid: string, label: string): string => {
      const url: string = resolveArticleLink('/read.php?searchpost=1&pid=' + pid, forumBase);
      return url.length > 0 ? storeHtml('<a href="' + escapeHtml(url) + '">' + label + '</a>', fragments) : label;
    });

  result = result.replace(/\[(\/)?(b|i|u|del|quote)\]/gi,
    (matched: string, closing: string, tag: string): string => {
      const name: string = tag.toLowerCase() === 'quote' ? 'blockquote' : tag.toLowerCase();
      return '<' + (closing ? '/' : '') + name + '>';
    });
  result = result.replace(/\[align=(left|center|right)\]/gi,
    (matched: string, alignment: string): string => '<div style="text-align:' + alignment.toLowerCase() + '">')
    .replace(/\[\/align\]/gi, '</div>');
  result = result.replace(/\[color=(#[0-9a-f]{3,8}|[a-z]{1,20})\]/gi,
    (matched: string, color: string): string => '<span style="color:' + color + '">')
    .replace(/\[\/color\]/gi, '</span>');
  result = result.replace(/\[size=(\d{1,3})%?\]/gi,
    (matched: string, size: string): string => '<span style="font-size:' + Math.min(200, Math.max(50, Number(size))).toString() + '%">')
    .replace(/\[\/size\]/gi, '</span>');
  result = result.replace(/\r\n?|\n/g, '<br>');

  // 片段可以包含此前生成的图片占位符，因此按逆序恢复。
  for (let index: number = fragments.length - 1; index >= 0; index--) {
    result = result.split('\ue000' + index.toString() + '\ue001').join(fragments[index]);
  }
  return result;
}

import { articleImageSources, resolveArticleImageUrl } from './ArticleHtml';
import { getEmoticonRawfilePath, getLegacyEmoticonRawfilePath, getPathByUrl } from './EmoticonUtils';

/** A paragraph is bounded for native text layout; all following content remains in later blocks. */
export const NATIVE_ARTICLE_PARAGRAPH_LIMIT: number = 4096;
const NATIVE_ARTICLE_DATA_LIMIT: number = 256 * 1024;

export interface NgaNativeArticleImage {
  src: string;
  alt: string;
  rawfilePath: string;
  invert: boolean;
  /** Only original, generated HTTPS article attachments are view/save targets. */
  openUrl: string;
}

export interface NgaNativeArticleInline {
  id: string;
  kind: 'text' | 'emoticon';
  text: string;
  image: NgaNativeArticleImage | undefined;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  strike: boolean;
  /** Empty means inherit the document foreground. */
  color: string;
  /** Relative to the document font size. */
  size: number;
  link: string;
}

export interface NgaNativeArticleBlock {
  id: string;
  kind: 'paragraph' | 'image';
  inlines: NgaNativeArticleInline[];
  image: NgaNativeArticleImage | undefined;
  quoteDepth: number;
  code: boolean;
  align: 'left' | 'center' | 'right';
}

export interface NgaNativeArticleDocument {
  blocks: NgaNativeArticleBlock[];
  fontSize: number;
  lineHeight: number;
  textColor: string;
  linkColor: string;
  quoteColor: string;
  invertEmoticons: boolean;
}

interface NgaNativeArticleContext {
  tag: string;
  blockBoundary: boolean;
  blockStart: number;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  strike: boolean;
  color: string;
  size: number;
  link: string;
  quoteDepth: number;
  code: boolean;
  align: 'left' | 'center' | 'right';
}

/** Decode text only after tokenizing markup, so an escaped tag remains ordinary text. */
function decodeNativeArticleEntities(value: string): string {
  return value.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi,
    (matched: string, entity: string): string => {
      if (entity.startsWith('#')) {
        const hexadecimal: boolean = entity.charAt(1).toLowerCase() === 'x';
        const point: number = parseInt(entity.substring(hexadecimal ? 2 : 1), hexadecimal ? 16 : 10);
        return point > 0 && point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff) ?
          String.fromCodePoint(point) : matched;
      }
      switch (entity.toLowerCase()) {
        case 'amp': return '&';
        case 'lt': return '<';
        case 'gt': return '>';
        case 'quot': return '"';
        case 'apos': return "'";
        case 'nbsp': return '\u00a0';
        default: return matched;
      }
    });
}

function nativeArticleAttributes(tag: string): Map<string, string> {
  const attributes: Map<string, string> = new Map<string, string>();
  const pattern: RegExp = /([a-z][a-z0-9_-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/gi;
  let matched: RegExpExecArray | null = pattern.exec(tag);
  while (matched !== null) {
    const name: string = (matched[1] ?? '').toLowerCase();
    if (!attributes.has(name)) {
      attributes.set(name, decodeNativeArticleEntities(matched[2] ?? matched[3] ?? matched[4] ?? ''));
    }
    matched = pattern.exec(tag);
  }
  return attributes;
}

function nativeArticleDeclarations(css: string): Map<string, string> {
  const values: Map<string, string> = new Map<string, string>();
  for (const declaration of css.split(';')) {
    const separator: number = declaration.indexOf(':');
    if (separator > 0) {
      values.set(declaration.substring(0, separator).trim().toLowerCase(),
        declaration.substring(separator + 1).trim());
    }
  }
  return values;
}

/** CSS #RGBA/#RRGGBBAA must become ArkUI #AARRGGBB. */
function nativeArticleColor(value: string): string {
  const color: string = value.trim().toLowerCase();
  if (/^#[0-9a-f]{3}$/.test(color)) {
    return '#' + color.charAt(1).repeat(2) + color.charAt(2).repeat(2) + color.charAt(3).repeat(2);
  }
  if (/^#[0-9a-f]{4}$/.test(color)) {
    return '#' + color.charAt(4).repeat(2) + color.charAt(1).repeat(2) +
      color.charAt(2).repeat(2) + color.charAt(3).repeat(2);
  }
  if (/^#[0-9a-f]{6}$/.test(color)) { return color; }
  if (/^#[0-9a-f]{8}$/.test(color)) { return '#' + color.substring(7) + color.substring(1, 7); }
  switch (color) {
    case 'black': return '#000000';
    case 'silver': return '#c0c0c0';
    case 'gray': case 'grey': return '#808080';
    case 'white': return '#ffffff';
    case 'maroon': return '#800000';
    case 'red': return '#ff0000';
    case 'purple': return '#800080';
    case 'fuchsia': case 'magenta': return '#ff00ff';
    case 'green': return '#008000';
    case 'lime': return '#00ff00';
    case 'olive': return '#808000';
    case 'yellow': return '#ffff00';
    case 'navy': return '#000080';
    case 'blue': return '#0000ff';
    case 'teal': return '#008080';
    case 'aqua': case 'cyan': return '#00ffff';
    case 'orange': return '#ffa500';
    case 'pink': return '#ffc0cb';
    case 'brown': return '#a52a2a';
    case 'transparent': return '#00000000';
    default: return '';
  }
}

function nativeArticleHttps(value: string): string {
  // Reuse the article renderer's protocol/path validation. A relative path is not an image source here.
  return /^https:\/\//i.test(value) ? resolveArticleImageUrl(value) : '';
}

function nativeArticleRawfile(alt: string, source: string): string {
  const category: RegExpMatchArray | null = alt.match(/^\[s:([a-z0-9_]*):([^\]\r\n]+)\]$/i);
  if (category !== null) {
    return getEmoticonRawfilePath((category[1] ?? '').toLowerCase(), category[2] ?? '');
  }
  const legacy: RegExpMatchArray | null = alt.match(/^\[s:(\d+)\]$/i);
  return legacy !== null ? getLegacyEmoticonRawfilePath(legacy[1] ?? '') : getPathByUrl(source);
}

/** A markup hint may name only a precise resource already in the bundled emoticon mappings. */
function nativeArticleRawfileHint(hint: string): string {
  const matched: RegExpMatchArray | null = hint.match(/^emoticon\/([a-z0-9]+)\/([a-z0-9_.-]+)$/);
  if (matched === null || hint.includes('..')) { return ''; }
  const category: string = matched[1] ?? '';
  const filename: string = matched[2] ?? '';
  // Legacy GIFs are mapped only under their real NGA smile origin/path by getPathByUrl.
  const url: string = category === 'legacy' ? 'https://img4.nga.cn/ngabbs/post/smile/' + filename :
    'https://img.nga.cn/attachments/' + filename;
  return getPathByUrl(url) === hint ? hint : '';
}

function nativeArticleImage(attributes: Map<string, string>, document: NgaNativeArticleDocument,
  attachmentSources: Set<string>): NgaNativeArticleImage | undefined {
  const classNames: string[] = (attributes.get('class') ?? '').trim().split(/\s+/);
  const isAttachment: boolean = classNames.includes('article-image');
  const isEmoticon: boolean = classNames.includes('emoticon');
  if ((!isAttachment && !isEmoticon) || classNames.some((name: string): boolean =>
    name !== 'article-image' && name !== 'emoticon' && name !== 'invertFilter')) {
    return undefined;
  }
  const original: string = attributes.get('src') ?? '';
  const remote: string = nativeArticleHttps(original);
  const data: boolean = original.length <= NATIVE_ARTICLE_DATA_LIMIT &&
    /^data:image\/(?:png|gif|jpe?g|webp);base64,(?:[a-z0-9+/]{4})*(?:[a-z0-9+/]{2}==|[a-z0-9+/]{3}=)?$/i
      .test(original) && !original.endsWith(',');
  if ((remote.length === 0 && !data) || (isAttachment && remote.length > 0 && !attachmentSources.has(remote))) {
    return undefined;
  }
  const alt: string = attributes.get('alt') ?? '';
  const source: string = remote.length > 0 ? remote : original;
  const altOrSourceRawfile: string = isEmoticon ? nativeArticleRawfile(alt, source) : '';
  const hintRawfile: string = isEmoticon && altOrSourceRawfile.length === 0 ?
    nativeArticleRawfileHint(attributes.get('data-nga-rawfile') ?? '') : '';
  const result: NgaNativeArticleImage = {
    src: source, alt: alt, rawfilePath: altOrSourceRawfile || hintRawfile,
    invert: document.invertEmoticons && classNames.includes('invertFilter'),
    openUrl: isAttachment && remote.length > 0 ? remote : ''
  };
  return result;
}

function nativeArticleDocument(html: string): NgaNativeArticleDocument {
  const document: NgaNativeArticleDocument = {
    blocks: [], fontSize: 16, lineHeight: 28, textColor: '#182538', linkColor: '#1765c1',
    quoteColor: '#1765c1', invertEmoticons: false
  };
  const head: RegExpMatchArray | null = html.match(/<head\b[^>]*>([\s\S]*?)<\/head\s*>/i);
  if (head === null) { return document; }
  let lineHeight: string = '1.75';
  const stylePattern: RegExp = /<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi;
  let style: RegExpExecArray | null = stylePattern.exec(head[1] ?? '');
  while (style !== null) {
    const rulePattern: RegExp = /([^{}]+)\{([^{}]*)\}/g;
    let rule: RegExpExecArray | null = rulePattern.exec(style[1] ?? '');
    while (rule !== null) {
      const selectors: string[] = (rule[1] ?? '').split(',').map((item: string): string => item.trim());
      const css: Map<string, string> = nativeArticleDeclarations(rule[2] ?? '');
      if (selectors.includes('body')) {
        const font: string = css.get('font-size') ?? '';
        if (/^\d+(?:\.\d+)?px$/i.test(font)) {
          document.fontSize = Math.max(8, Math.min(48, parseFloat(font)));
        }
        const color: string = nativeArticleColor(css.get('color') ?? '');
        if (color.length > 0) { document.textColor = color; }
        lineHeight = css.get('line-height') ?? lineHeight;
      }
      if (selectors.includes('a')) {
        const color: string = nativeArticleColor(css.get('color') ?? '');
        if (color.length > 0) { document.linkColor = color; }
      }
      if (selectors.includes('blockquote')) {
        const border: string = css.get('border-left') ?? '';
        const color: string = nativeArticleColor(border.trim().split(/\s+/).pop() ?? '');
        if (color.length > 0) { document.quoteColor = color; }
      }
      if (selectors.includes('img.invertFilter') && /^invert\(100%\)$/i.test(css.get('filter') ?? '')) {
        document.invertEmoticons = true;
      }
      rule = rulePattern.exec(style[1] ?? '');
    }
    style = stylePattern.exec(head[1] ?? '');
  }
  if (/^\d+(?:\.\d+)?$/.test(lineHeight)) {
    document.lineHeight = document.fontSize * Math.max(1, Math.min(3, Number(lineHeight)));
  } else if (/^\d+(?:\.\d+)?px$/i.test(lineHeight)) {
    document.lineHeight = Math.max(document.fontSize, Math.min(144, parseFloat(lineHeight)));
  }
  return document;
}

function nativeArticleContext(previous?: NgaNativeArticleContext): NgaNativeArticleContext {
  if (previous === undefined) {
    return { tag: '', blockBoundary: false, blockStart: 0, bold: false, italic: false, underline: false, strike: false,
      color: '', size: 1, link: '', quoteDepth: 0, code: false, align: 'left' };
  }
  return { tag: '', blockBoundary: false, blockStart: 0, bold: previous.bold, italic: previous.italic,
    underline: previous.underline, strike: previous.strike, color: previous.color, size: previous.size,
    link: previous.link, quoteDepth: previous.quoteDepth, code: previous.code, align: previous.align };
}

function nativeArticleInline(context: NgaNativeArticleContext, id: string, text: string,
  image?: NgaNativeArticleImage): NgaNativeArticleInline {
  return { id: id, kind: image === undefined ? 'text' : 'emoticon', text: text, image: image,
    bold: context.bold, italic: context.italic, underline: context.underline, strike: context.strike,
    color: context.color, size: context.size, link: context.link };
}

/** Parse the whitelist renderer's HTML into native layout data; it never loads or executes HTML. */
export function parseNativeArticleContent(html: string): NgaNativeArticleDocument {
  const document: NgaNativeArticleDocument = nativeArticleDocument(html);
  const attachmentSources: Set<string> = new Set<string>(articleImageSources(html));
  const bodyStart: RegExpExecArray | null = /<body\b[^>]*>/i.exec(html);
  let body: string = html;
  if (bodyStart !== null) {
    const start: number = bodyStart.index + bodyStart[0].length;
    const tail: string = html.substring(start);
    const close: number = tail.search(/<\/body\s*>/i);
    body = close >= 0 ? tail.substring(0, close) : tail;
  }
  const contexts: NgaNativeArticleContext[] = [nativeArticleContext()];
  let current: NgaNativeArticleBlock | undefined = undefined;
  let paragraphLength: number = 0;
  let inlineIndex: number = 0;
  let suppressedTag: string = '';

  const contextNow: () => NgaNativeArticleContext = (): NgaNativeArticleContext => contexts[contexts.length - 1];
  const flush: () => void = (): void => { current = undefined; paragraphLength = 0; };
  const paragraph: () => NgaNativeArticleBlock = (): NgaNativeArticleBlock => {
    if (current === undefined) {
      const context: NgaNativeArticleContext = contextNow();
      current = { id: 'b' + document.blocks.length.toString(), kind: 'paragraph', inlines: [], image: undefined,
        quoteDepth: context.quoteDepth, code: context.code, align: context.align };
      document.blocks.push(current);
    }
    return current;
  };
  const append: (text: string, image?: NgaNativeArticleImage) => void =
    (text: string, image?: NgaNativeArticleImage): void => {
      if (image !== undefined) {
        if (paragraphLength >= NATIVE_ARTICLE_PARAGRAPH_LIMIT) { flush(); }
        paragraph().inlines.push(nativeArticleInline(contextNow(), 'i' + (inlineIndex++).toString(), '', image));
        paragraphLength++;
        return;
      }
      let start: number = 0;
      while (start < text.length) {
        if (paragraphLength >= NATIVE_ARTICLE_PARAGRAPH_LIMIT) { flush(); }
        let end: number = Math.min(text.length, start + NATIVE_ARTICLE_PARAGRAPH_LIMIT - paragraphLength);
        // Avoid splitting a supplementary character between consecutive native Text nodes.
        if (end < text.length && end > start && text.charCodeAt(end - 1) >= 0xd800 &&
          text.charCodeAt(end - 1) <= 0xdbff) { end--; }
        if (end === start) { flush(); continue; }
        const fragment: string = text.substring(start, end);
        paragraph().inlines.push(nativeArticleInline(contextNow(), 'i' + (inlineIndex++).toString(), fragment));
        paragraphLength += fragment.length;
        start = end;
      }
    };

  // A single forward scan also covers malformed/unknown tags without dropping their text children.
  const tokens: RegExp = /<!--[\s\S]*?-->|<[^>]*>|[^<]+|</g;
  let token: RegExpExecArray | null = tokens.exec(body);
  while (token !== null) {
    const value: string = token[0];
    const tagMatch: RegExpMatchArray | null = value.match(/^<\s*(\/?)\s*([a-z][a-z0-9-]*)\b/i);
    if (suppressedTag.length > 0) {
      if (tagMatch !== null && tagMatch[1] === '/' && (tagMatch[2] ?? '').toLowerCase() === suppressedTag) {
        suppressedTag = '';
      }
    } else if (tagMatch === null) {
      if (!value.startsWith('<!--') && !value.startsWith('<!') && !value.startsWith('<?')) {
        append(decodeNativeArticleEntities(value));
      }
    } else {
      const tag: string = (tagMatch[2] ?? '').toLowerCase();
      const closing: boolean = tagMatch[1] === '/';
      const block: boolean = tag === 'blockquote' || tag === 'pre' || tag === 'div' || tag === 'p';
      if (tag === 'script' || tag === 'style' || tag === 'head') {
        if (!closing) { suppressedTag = tag; }
      } else if (closing) {
        for (let index: number = contexts.length - 1; index > 0; index--) {
          if (contexts[index].tag === tag) {
            if ((tag === 'blockquote' || tag === 'pre') && document.blocks.length === contexts[index].blockStart) {
              // Empty quoted/code sections still have their native block padding/boundary.
              paragraph();
            }
            if (contexts.slice(index).some((item: NgaNativeArticleContext): boolean => item.blockBoundary)) { flush(); }
            contexts.length = index;
            break;
          }
        }
      } else if (tag === 'br') {
        append('\n');
      } else if (tag === 'img') {
        const attributes: Map<string, string> = nativeArticleAttributes(value);
        const image: NgaNativeArticleImage | undefined = nativeArticleImage(attributes, document, attachmentSources);
        if (image === undefined) {
          append(attributes.get('alt') ?? '');
        } else if ((attributes.get('class') ?? '').split(/\s+/).includes('article-image')) {
          flush();
          const context: NgaNativeArticleContext = contextNow();
          document.blocks.push({ id: 'b' + document.blocks.length.toString(), kind: 'image', inlines: [], image: image,
            quoteDepth: context.quoteDepth, code: context.code, align: context.align });
        } else {
          append('', image);
        }
      } else if (tag === 'b' || tag === 'strong' || tag === 'i' || tag === 'em' || tag === 'u' ||
        tag === 'del' || tag === 's' || tag === 'span' || tag === 'a' || block) {
        if (block) { flush(); }
        const context: NgaNativeArticleContext = nativeArticleContext(contextNow());
        context.tag = tag;
        context.blockBoundary = block;
        context.blockStart = document.blocks.length;
        const attributes: Map<string, string> = nativeArticleAttributes(value);
        const css: Map<string, string> = nativeArticleDeclarations(attributes.get('style') ?? '');
        if (tag === 'b' || tag === 'strong') { context.bold = true; }
        if (tag === 'i' || tag === 'em') { context.italic = true; }
        if (tag === 'u') { context.underline = true; }
        if (tag === 'del' || tag === 's') { context.strike = true; }
        if (tag === 'blockquote') { context.quoteDepth++; }
        if (tag === 'pre') { context.code = true; }
        if (tag === 'a') { context.link = nativeArticleHttps(attributes.get('href') ?? ''); }
        const color: string = nativeArticleColor(css.get('color') ?? '');
        if (color.length > 0) { context.color = color; }
        const size: string = css.get('font-size') ?? '';
        if (/^\d+(?:\.\d+)?%$/.test(size)) {
          context.size = Math.max(0.5, Math.min(2, context.size * parseFloat(size) / 100));
        }
        const alignment: string = (css.get('text-align') ?? '').toLowerCase();
        if (alignment === 'left' || alignment === 'center' || alignment === 'right') { context.align = alignment; }
        if (!/\/\s*>$/.test(value)) { contexts.push(context); }
      }
    }
    token = tokens.exec(body);
  }
  return document;
}

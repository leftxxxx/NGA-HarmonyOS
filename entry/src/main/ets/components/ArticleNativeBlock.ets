import { NgaNativeArticleBlock, NgaNativeArticleInline, NgaNativeArticleImage } from '../model/ArticleNativeContent';
import { ArticleNativeImage } from './ArticleNativeImage';

/** Keep an existing native image alive when only the article theme changes. */
@Observed
export class NgaArticleBodyBlock {
  block: NgaNativeArticleBlock;
  articleHtml: string;
  renderKey: string;

  constructor(block: NgaNativeArticleBlock, articleHtml: string, revision: number) {
    this.block = block;
    this.articleHtml = articleHtml;
    this.renderKey = revision.toString() + ':' + block.id;
  }
}

@Component
export struct ArticleNativeBlock {
  @ObjectLink renderBlock: NgaArticleBodyBlock;
  @Prop articleFontSize: number = 16;
  @Prop articleLineHeight: number = 28;
  @Prop articleTextColor: string = '#182538';
  @Prop articleLinkColor: string = '#1765c1';
  @Prop articleQuoteColor: string = '#1765c1';
  @State failedEmoticonIds: string[] = [];
  onOpenImage: (url: string, articleHtml: string) => void = (): void => {};
  onSaveImage: (url: string, articleHtml: string) => void = (): void => {};
  onOpenLink: (url: string, articleHtml: string) => void = (): void => {};
  private attached: boolean = false;
  private identityFilter: ColorFilter = new ColorFilter([
    1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0
  ]);
  private inverseFilter: ColorFilter = new ColorFilter([
    -1, 0, 0, 0, 255, 0, -1, 0, 0, 255, 0, 0, -1, 0, 255, 0, 0, 0, 1, 0
  ]);

  aboutToAppear(): void {
    this.attached = true;
  }

  aboutToDisappear(): void {
    this.attached = false;
  }

  private inlineRenderKey(fragment: NgaNativeArticleInline): string {
    return fragment.id + ':' + (fragment.image?.invert ? 'inverse' : 'original') + ':' +
      (fragment.image?.rawfilePath ?? '') + ':' + (fragment.image?.src ?? '');
  }

  private inlineColor(fragment: NgaNativeArticleInline): string {
    if (fragment.color.length > 0) {
      return fragment.color;
    }
    return fragment.link.length > 0 ? this.articleLinkColor : this.articleTextColor;
  }

  private decorationType(fragment: NgaNativeArticleInline): TextDecorationType {
    if (fragment.strike) {
      return TextDecorationType.LineThrough;
    }
    return fragment.underline ? TextDecorationType.Underline : TextDecorationType.None;
  }

  private inlineSize(fragment: NgaNativeArticleInline): number {
    return this.articleFontSize * fragment.size;
  }

  private imageSource(image: NgaNativeArticleImage | undefined): ResourceStr {
    if (image === undefined) {
      return '';
    }
    return image.rawfilePath.length > 0 ? $rawfile(image.rawfilePath) : image.src;
  }

  private emoticonFilter(fragment: NgaNativeArticleInline): ColorFilter {
    return fragment.image?.invert ? this.inverseFilter : this.identityFilter;
  }

  private emoticonLabel(fragment: NgaNativeArticleInline): string {
    const alternate: string = fragment.image?.alt ?? '';
    const category: RegExpMatchArray | null = alternate.match(/^\[s:[a-z0-9_]*:([^\]\r\n]+)\]$/i);
    if (category !== null) {
      return '［' + (category[1] ?? '表情') + '］';
    }
    if (/^\[s:[^\]\r\n]+\]$/i.test(alternate)) {
      return '［表情］';
    }
    return alternate.length > 0 && alternate !== '图片' ? alternate : '［表情］';
  }

  private failEmoticon(fragment: NgaNativeArticleInline): void {
    if (this.attached && !this.failedEmoticonIds.includes(fragment.id)) {
      this.failedEmoticonIds = this.failedEmoticonIds.concat(fragment.id);
    }
  }

  private openInline(fragment: NgaNativeArticleInline): void {
    if (this.attached && fragment.link.length > 0) {
      this.onOpenLink(fragment.link, this.renderBlock.articleHtml);
    }
  }

  private paragraphAlign(): TextAlign {
    if (this.renderBlock.block.align === 'center') {
      return TextAlign.Center;
    }
    return this.renderBlock.block.align === 'right' ? TextAlign.End : TextAlign.Start;
  }

  private quoteInset(): number {
    return Math.min(4, this.renderBlock.block.quoteDepth) * 8;
  }

  private blockPadding(): Padding {
    return { left: this.quoteInset(), right: 0, top: this.renderBlock.block.code ? 8 : 0,
      bottom: this.renderBlock.block.code ? 8 : 0 };
  }

  build() {
    Column() {
      if (this.renderBlock.block.kind === 'image' && this.renderBlock.block.image !== undefined) {
        ArticleNativeImage({
          imageSrc: this.renderBlock.block.image?.src ?? '',
          rawfilePath: this.renderBlock.block.image?.rawfilePath ?? '',
          imageAlt: this.renderBlock.block.image?.alt ?? '图片',
          imageId: this.renderBlock.block.id,
          imageAlign: this.renderBlock.block.align,
          openUrl: this.renderBlock.block.image?.openUrl ?? '',
          articleHtml: this.renderBlock.articleHtml,
          placeholderColor: this.articleTextColor,
          onOpen: (url: string, articleHtml: string): void => { this.onOpenImage(url, articleHtml); },
          onSave: (url: string, articleHtml: string): void => { this.onSaveImage(url, articleHtml); }
        })
      } else {
        Text() {
          ForEach(this.renderBlock.block.inlines, (fragment: NgaNativeArticleInline) => {
            if (fragment.kind === 'emoticon' && fragment.image !== undefined &&
              !this.failedEmoticonIds.includes(fragment.id)) {
              ImageSpan(this.imageSource(fragment.image))
                .size({ width: this.inlineSize(fragment) * 1.75, height: this.inlineSize(fragment) * 1.75 })
                .verticalAlign(ImageSpanAlignment.CENTER)
                .objectFit(ImageFit.Contain)
                .colorFilter(this.emoticonFilter(fragment))
                .onError((): void => { this.failEmoticon(fragment); })
                .onClick((): void => { this.openInline(fragment); })
            } else if (fragment.kind === 'emoticon') {
              Span(this.emoticonLabel(fragment))
                .fontColor(this.inlineColor(fragment))
                .fontSize(this.inlineSize(fragment))
                .onClick((): void => { this.openInline(fragment); })
            } else {
              Span(fragment.text)
                .fontColor(this.inlineColor(fragment))
                .fontSize(this.inlineSize(fragment))
                .fontWeight(fragment.bold ? FontWeight.Bold : FontWeight.Normal)
                .fontStyle(fragment.italic ? FontStyle.Italic : FontStyle.Normal)
                .decoration({ type: this.decorationType(fragment), color: this.inlineColor(fragment) })
                .onClick((): void => { this.openInline(fragment); })
            }
          }, (fragment: NgaNativeArticleInline): string => this.inlineRenderKey(fragment))
        }
        .id('article-native-paragraph-' + this.renderBlock.block.id)
        .width('100%')
        .constraintSize({ minHeight: this.articleLineHeight })
        .fontSize(this.articleFontSize)
        .lineHeight(this.articleLineHeight)
        .fontColor(this.articleTextColor)
        .fontFamily(this.renderBlock.block.code ? 'monospace' : 'HarmonyOS Sans')
        .textAlign(this.paragraphAlign())
        .wordBreak(WordBreak.BREAK_WORD)
        .copyOption(CopyOptions.LocalDevice)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(this.blockPadding())
    .border({ width: { left: this.renderBlock.block.quoteDepth > 0 ? 3 : 0 }, color: this.articleQuoteColor })
  }
}



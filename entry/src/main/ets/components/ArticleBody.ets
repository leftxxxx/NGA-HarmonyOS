import { common, Want } from '@kit.AbilityKit';
import { COLOR_DAY_CARD } from '../model/AppTheme';
import { articleHtmlHasOnlyThemeChange, articleImageSources } from '../model/ArticleHtml';
import { NgaNativeArticleBlock, NgaNativeArticleDocument, NgaNativeArticleInline,
  parseNativeArticleContent } from '../model/ArticleNativeContent';
import { ArticleImageSaver, NgaArticleImageSaveResult } from '../model/ArticleImageSaver';
import { ArticleImageViewer } from './ArticleImageViewer';
import { ArticleNativeBlock, NgaArticleBodyBlock } from './ArticleNativeBlock';

/** Native text and images share the list's canvas, avoiding independent Web surfaces. */
@Component
export struct ArticleBody {
  @Prop @Watch('reloadHtml') html: string = '';
  @Prop bodyBackground: string = COLOR_DAY_CARD;
  @Prop baseUrl: string = 'https://bbs.nga.cn/';
  @State showImageViewer: boolean = false;
  @State activeImageUrl: string = '';
  @State isSavingImage: boolean = false;
  @State document: NgaNativeArticleDocument = parseNativeArticleContent('');
  @State renderBlocks: NgaArticleBodyBlock[] = [];
  private attached: boolean = false;
  private loadedHtml: string = '';
  private contentRevision: number = 0;
  private saveRevision: number = 0;
  private activeImageHtml: string = '';

  aboutToAppear(): void {
    this.attached = true;
    this.reloadHtml();
  }

  aboutToDisappear(): void {
    this.attached = false;
    this.saveRevision++;
    this.isSavingImage = false;
    this.showImageViewer = false;
    this.activeImageUrl = '';
    this.activeImageHtml = '';
  }

  private isCurrentArticle(articleHtml: string): boolean {
    return this.attached && (articleHtml === this.html || articleHtmlHasOnlyThemeChange(articleHtml, this.html));
  }

  private reloadHtml(): void {
    if (!this.attached) {
      return;
    }
    const sameContent: boolean = this.loadedHtml === this.html;
    const themeChange: boolean = articleHtmlHasOnlyThemeChange(this.loadedHtml, this.html);
    const nextDocument: NgaNativeArticleDocument = parseNativeArticleContent(this.html);
    if (!sameContent && !themeChange) {
      this.contentRevision++;
      this.saveRevision++;
      this.isSavingImage = false;
      this.showImageViewer = false;
      this.activeImageUrl = '';
      this.activeImageHtml = '';
    } else if (!articleImageSources(this.html).includes(this.activeImageUrl)) {
      this.showImageViewer = false;
      this.activeImageUrl = '';
      this.activeImageHtml = '';
    }
    if ((sameContent || themeChange) && this.renderBlocks.length === nextDocument.blocks.length) {
      // Preserve decoded image dimensions across a pure theme change.
      nextDocument.blocks.forEach((block: NgaNativeArticleBlock, index: number): void => {
        const existing: NgaArticleBodyBlock = this.renderBlocks[index];
        existing.block = block;
        existing.articleHtml = this.html;
      });
    } else {
      this.renderBlocks = nextDocument.blocks.map((block: NgaNativeArticleBlock): NgaArticleBodyBlock =>
        new NgaArticleBodyBlock(block, this.html, this.contentRevision));
    }
    this.document = nextDocument;
    this.loadedHtml = this.html;
  }

  private openImage(url: string, articleHtml: string): void {
    if (!this.isCurrentArticle(articleHtml) || !articleImageSources(this.html).includes(url)) {
      return;
    }
    this.activeImageUrl = url;
    this.activeImageHtml = articleHtml;
    this.showImageViewer = true;
  }

  private async openLink(url: string, articleHtml: string): Promise<void> {
    if (!this.isCurrentArticle(articleHtml) || !/^https?:\/\/[^/?#]+(?:[/?#].*)?$/i.test(url) ||
      /[\s'"<>\\\x00-\x1f\x7f]/.test(url)) {
      return;
    }
    const listed: boolean = this.document.blocks.some((block: NgaNativeArticleBlock): boolean =>
      block.inlines.some((inline: NgaNativeArticleInline): boolean => inline.link === url));
    if (!listed) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      return;
    }
    try {
      const want: Want = { action: 'ohos.want.action.viewData', uri: url };
      await context.startAbility(want);
    } catch (error) {
      if (this.isCurrentArticle(articleHtml)) {
        this.getUIContext().getPromptAction().showToast({ message: '链接暂时无法打开，请稍后重试' });
      }
    }
  }

  private async saveImage(url: string, articleHtml: string): Promise<void> {
    if (this.isSavingImage || !this.isCurrentArticle(articleHtml) || !articleImageSources(this.html).includes(url)) {
      return;
    }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    this.isSavingImage = true;
    const operation: number = ++this.saveRevision;
    const isCurrentArticle: () => boolean = (): boolean => this.isCurrentArticle(articleHtml) &&
      operation === this.saveRevision && articleImageSources(this.html).includes(url);
    try {
      const result: NgaArticleImageSaveResult = await ArticleImageSaver.save(url, context, isCurrentArticle);
      if (isCurrentArticle() && !result.cancelled && result.message.length > 0) {
        this.getUIContext().getPromptAction().showToast({ message: result.message });
      }
    } catch (error) {
      if (isCurrentArticle()) {
        this.getUIContext().getPromptAction().showToast({ message: '图片保存失败，请稍后重试' });
      }
    } finally {
      if (this.attached && operation === this.saveRevision) {
        this.isSavingImage = false;
      }
    }
  }

  @Builder
  private ImageViewer() {
    ArticleImageViewer({
      imageUrl: this.activeImageUrl,
      viewerBackground: this.bodyBackground,
      isSaving: this.isSavingImage,
      onClose: (): void => { this.showImageViewer = false; },
      onSave: (): void => { this.saveImage(this.activeImageUrl, this.activeImageHtml); }
    })
  }

  build() {
    Column() {
      ForEach(this.renderBlocks, (renderBlock: NgaArticleBodyBlock) => {
        ArticleNativeBlock({
          renderBlock: renderBlock,
          articleFontSize: this.document.fontSize,
          articleLineHeight: this.document.lineHeight,
          articleTextColor: this.document.textColor,
          articleLinkColor: this.document.linkColor,
          articleQuoteColor: this.document.quoteColor,
          onOpenImage: (url: string, articleHtml: string): void => { this.openImage(url, articleHtml); },
          onSaveImage: (url: string, articleHtml: string): void => { this.saveImage(url, articleHtml); },
          onOpenLink: (url: string, articleHtml: string): void => { this.openLink(url, articleHtml); }
        })
      }, (renderBlock: NgaArticleBodyBlock): string => renderBlock.renderKey)
    }
    .id('article-native-body')
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(this.bodyBackground)
    .bindContentCover($$this.showImageViewer, this.ImageViewer, { modalTransition: ModalTransition.DEFAULT })
  }
}


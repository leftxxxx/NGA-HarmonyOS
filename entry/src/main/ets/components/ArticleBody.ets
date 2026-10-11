import { webview } from '@kit.ArkWeb';
import { COLOR_DAY_CARD } from '../model/AppTheme';
import { articleImageFromLink, articleImageSources } from '../model/ArticleHtml';
import { ArticleImageSaver, NgaArticleImageSaveResult } from '../model/ArticleImageSaver';
import { ArticleImageViewer } from './ArticleImageViewer';

/** 异步绘制正文；超长楼层使用有界视口，滚动到边缘后交给帖子列表。 */
@Component
export struct ArticleBody {
  @Prop @Watch('reloadHtml') html: string = '';
  @Prop bodyBackground: string = COLOR_DAY_CARD;
  @Prop baseUrl: string = 'https://bbs.nga.cn/';
  @State showImageViewer: boolean = false;
  @State activeImageUrl: string = '';
  @State isSavingImage: boolean = false;
  @State bodyHeight: number = 32;
  private controller: webview.WebviewController = new webview.WebviewController();
  private attached: boolean = false;
  private measureTimers: number[] = [];
  private measureRevision: number = 0;
  private bodyWidth: number = 0;

  aboutToDisappear(): void {
    this.attached = false;
    this.cancelBodyMeasure();
    this.showImageViewer = false;
  }

  private reloadHtml(): void {
    this.showImageViewer = false;
    this.cancelBodyMeasure();
    this.bodyHeight = 32;
    if (this.attached) {
      try {
        this.controller.loadData(this.html, 'text/html', 'UTF-8', this.baseUrl, this.baseUrl);
      } catch (err) {
        console.warn('[NGA.ArticleBody] 正文加载失败');
      }
    }
  }

  private cancelBodyMeasure(): void {
    this.measureRevision++;
    this.measureTimers.forEach((timer: number): void => { clearTimeout(timer); });
    this.measureTimers = [];
  }

  private measureBodyHeight(): void {
    if (!this.attached) {
      return;
    }
    try {
      const pageHeight: number = this.controller.getPageHeight();
      if (Number.isFinite(pageHeight) && pageHeight > 0) {
        // ASYNC_RENDER 的 surface 不能超过 7680 物理像素，保留绘制余量。
        // 使用普通布局而非 FIT_CONTENT，超长正文仍可在 Web 内完整滚动。
        const maxHeight: number = this.getUIContext().px2vp(7000);
        this.bodyHeight = Math.min(Math.ceil(pageHeight), maxHeight);
      }
    } catch (error) {
      console.warn('[NGA.ArticleBody] 正文高度暂不可读取');
    }
  }

  private scheduleBodyMeasure(measureNow: boolean = true): void {
    this.cancelBodyMeasure();
    if (!this.attached) {
      return;
    }
    if (measureNow) {
      this.measureBodyHeight();
    }
    const currentHtml: string = this.html;
    const revision: number = this.measureRevision;
    // 图片解码可能晚于 onPageEnd；资源加载后再测量，避免图片被短视口裁住。
    [100, 500, 2000].forEach((delay: number): void => {
      this.measureTimers.push(setTimeout((): void => {
        if (this.attached && currentHtml === this.html && revision === this.measureRevision) {
          this.measureBodyHeight();
        }
      }, delay));
    });
  }

  private openImage(link: string): void {
    const url: string = articleImageFromLink(link, this.html);
    if (url.length > 0 && this.attached) {
      this.activeImageUrl = url;
      this.showImageViewer = true;
    }
  }

  private async saveImage(url: string): Promise<void> {
    if (this.isSavingImage || !this.attached || !articleImageSources(this.html).includes(url)) {
      return;
    }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    this.isSavingImage = true;
    const currentHtml: string = this.html;
    try {
      const result: NgaArticleImageSaveResult = await ArticleImageSaver.save(url, context,
        (): boolean => this.attached && currentHtml === this.html);
      if (this.attached && currentHtml === this.html && !result.cancelled && result.message.length > 0) {
        this.getUIContext().getPromptAction().showToast({ message: result.message });
      }
    } catch (error) {
      if (this.attached && currentHtml === this.html) {
        this.getUIContext().getPromptAction().showToast({ message: '图片保存失败，请稍后重试' });
      }
    } finally {
      if (this.attached) {
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
      onSave: (): void => { this.saveImage(this.activeImageUrl); }
    })
  }

  build() {
    Column() {
      Web({ src: '', controller: this.controller, renderMode: RenderMode.ASYNC_RENDER })
        .width('100%')
        .height(this.bodyHeight)
        .layoutMode(WebLayoutMode.NONE)
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .overScrollMode(OverScrollMode.NEVER)
        .imageAccess(true)
        .zoomAccess(false)
        .javaScriptAccess(false)
        .fileAccess(false)
        .mixedMode(MixedMode.Compatible)
        .backgroundColor(this.bodyBackground)
        .onOverrideUrlLoading((request: WebResourceRequest): boolean => {
          const url: string = request.getRequestUrl();
          if (url.startsWith('nga-image:')) {
            this.openImage(url);
            return true;
          }
          return false;
        })
        .onContextMenuShow((event: OnContextMenuShowEvent): boolean => {
          const url: string = event.param.getSourceUrl();
          if (event.param.existsImageContents() && articleImageSources(this.html).includes(url)) {
            event.result.closeContextMenu();
            this.saveImage(url);
            return true;
          }
          return false;
        })
        .onPageEnd((): void => { this.scheduleBodyMeasure(); })
        .onResourceLoad((): void => { this.scheduleBodyMeasure(); })
        .onAreaChange((oldArea: Area, newArea: Area): void => {
          const nextWidth: number = Number(newArea.width);
          if (nextWidth > 0 && nextWidth !== this.bodyWidth) {
            this.bodyWidth = nextWidth;
            this.bodyHeight = 32;
            this.scheduleBodyMeasure(false);
          }
        })
        .onControllerAttached(() => {
          this.attached = true;
          this.reloadHtml();
        })
    }
    .width('100%')
    .bindContentCover($$this.showImageViewer, this.ImageViewer, { modalTransition: ModalTransition.DEFAULT })
  }
}

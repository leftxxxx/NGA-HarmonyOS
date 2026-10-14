/** An attachment retains its real aspect ratio and leaves scrolling to the surrounding list. */
@Component
export struct ArticleNativeImage {
  @Prop @Watch('resetImage') imageSrc: string = '';
  @Prop @Watch('resetImage') rawfilePath: string = '';
  @Prop imageAlt: string = '图片';
  @Prop imageId: string = 'image';
  @Prop imageAlign: 'left' | 'center' | 'right' = 'left';
  @Prop openUrl: string = '';
  @Prop articleHtml: string = '';
  @Prop placeholderColor: string = '#53647a';
  @State imageLoaded: boolean = false;
  @State imageFailed: boolean = false;
  @State availableWidth: number = 0;
  @State naturalWidth: number = 0;
  @State naturalHeight: number = 0;
  @State requestKey: string = '';
  onOpen: (url: string, articleHtml: string) => void = (): void => {};
  onSave: (url: string, articleHtml: string) => void = (): void => {};
  private attached: boolean = false;
  private requestRevision: number = 0;

  aboutToAppear(): void {
    this.attached = true;
    this.resetImage();
  }

  aboutToDisappear(): void {
    this.attached = false;
    this.requestRevision++;
  }

  private resetImage(): void {
    if (!this.attached) {
      return;
    }
    this.imageLoaded = false;
    this.imageFailed = false;
    this.naturalWidth = 0;
    this.naturalHeight = 0;
    this.requestKey = (++this.requestRevision).toString() + ':' + this.rawfilePath + ':' + this.imageSrc;
  }

  private imageSource(): ResourceStr {
    return this.rawfilePath.length > 0 ? $rawfile(this.rawfilePath) : this.imageSrc;
  }

  private imageAlignment(): Alignment {
    if (this.imageAlign === 'center') {
      return Alignment.Center;
    }
    return this.imageAlign === 'right' ? Alignment.End : Alignment.Start;
  }

  private imageDisplayWidth(): Length {
    if (this.availableWidth <= 0 || this.naturalWidth <= 0) {
      return '100%';
    }
    return Math.min(this.availableWidth, this.naturalWidth);
  }

  private imageDisplayHeight(): number {
    if (this.imageFailed) {
      return 72;
    }
    if (this.availableWidth > 0 && this.naturalWidth > 0 && this.naturalHeight > 0) {
      // No surface-height cap: a tall image is fully visible in the native list.
      return Math.max(1, Math.min(this.availableWidth, this.naturalWidth) * this.naturalHeight / this.naturalWidth);
    }
    return this.availableWidth > 0 ? Math.min(240, this.availableWidth * 0.75) : 180;
  }

  private acceptImageLoad(request: string, sourceWidth: number, sourceHeight: number): void {
    if (!this.attached || request !== this.requestKey) {
      return;
    }
    if (Number.isFinite(sourceWidth) && Number.isFinite(sourceHeight) && sourceWidth > 0 && sourceHeight > 0) {
      this.naturalWidth = sourceWidth;
      this.naturalHeight = sourceHeight;
    }
    this.imageFailed = false;
    this.imageLoaded = true;
  }

  private rejectImageLoad(request: string): void {
    if (this.attached && request === this.requestKey) {
      this.imageLoaded = false;
      this.imageFailed = true;
    }
  }

  private openLoadedImage(request: string): void {
    if (this.attached && request === this.requestKey && this.imageLoaded && this.openUrl.length > 0) {
      this.onOpen(this.openUrl, this.articleHtml);
    }
  }

  private saveLoadedImage(request: string): void {
    if (this.attached && request === this.requestKey && this.imageLoaded && this.openUrl.length > 0) {
      this.onSave(this.openUrl, this.articleHtml);
    }
  }

  private retryImage(): void {
    if (this.attached) {
      this.resetImage();
    }
  }

  build() {
    Column() {
      if (this.imageFailed) {
        Button({ type: ButtonType.Normal }) {
          Text('图片加载失败，点击重试')
            .fontSize(14)
            .fontColor(this.placeholderColor)
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .id('article-native-image-retry-' + this.imageId)
        .width('100%')
        .height(72)
        .backgroundColor(Color.Transparent)
        .onClick((): void => { this.retryImage(); })
      } else {
        Stack({ alignContent: this.imageAlignment() }) {
          ForEach([this.requestKey], (request: string) => {
            Image(this.imageSource())
              .id('article-native-image-' + this.imageId)
              .width(this.imageDisplayWidth())
              .height(this.imageDisplayHeight())
              .objectFit(ImageFit.Contain)
              .autoResize(true)
              .draggable(false)
              .borderRadius(12)
              .accessibilityText(this.imageAlt)
              .onComplete((event?: ImageLoadResult): void => {
                this.acceptImageLoad(request, event?.width ?? 0, event?.height ?? 0);
              })
              .onError((): void => { this.rejectImageLoad(request); })
              .onClick((): void => { this.openLoadedImage(request); })
              .gesture(
                LongPressGesture({ duration: 600, repeat: false })
                  .onAction((): void => { this.saveLoadedImage(request); })
              )
          }, (request: string): string => request)
          if (!this.imageLoaded) {
            Text('正在加载图片…')
              .fontSize(13)
              .fontColor(this.placeholderColor)
          }
        }
        .width('100%')
        .height(this.imageDisplayHeight())
      }
    }
    .width('100%')
    .margin({ top: 12, bottom: 12 })
    .onAreaChange((_previous: Area, current: Area): void => {
      const nextWidth: number = Number(current.width);
      if (this.attached && Number.isFinite(nextWidth) && nextWidth > 0 && nextWidth !== this.availableWidth) {
        this.availableWidth = nextWidth;
      }
    })
  }
}



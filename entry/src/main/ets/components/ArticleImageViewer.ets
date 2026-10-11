import { window } from '@kit.ArkUI';
import { COLOR_ACCENT_BLUE, COLOR_DAY_CARD, COLOR_DAY_SUB, COLOR_DAY_TEXT,
  COLOR_NIGHT_CARD, COLOR_NIGHT_SUB, COLOR_NIGHT_TEXT } from '../model/AppTheme';

/** Native full-screen viewer; the article Web never receives a JavaScript bridge. */
@Component
export struct ArticleImageViewer {
  @Prop imageUrl: string = '';
  @Prop viewerBackground: string = COLOR_DAY_CARD;
  @Prop isSaving: boolean = false;
  @State imageScale: number = 1;
  @State imageOffsetX: number = 0;
  @State imageOffsetY: number = 0;
  @State imageFailed: boolean = false;
  @State imageLoaded: boolean = false;
  @State safeInsetTop: number = 0;
  @State safeInsetBottom: number = 0;
  @State safeInsetLeft: number = 0;
  @State safeInsetRight: number = 0;
  @State safeAreaReady: boolean = false;
  onClose: () => void = (): void => {};
  onSave: () => void = (): void => {};
  private pinchStart: number = 1;
  private panStartX: number = 0;
  private panStartY: number = 0;
  private viewportWidth: number = 0;
  private viewportHeight: number = 0;
  private viewerWindow: window.Window | undefined = undefined;
  private systemAvoidArea: window.AvoidArea | undefined = undefined;
  private cutoutAvoidArea: window.AvoidArea | undefined = undefined;
  private navigationAvoidArea: window.AvoidArea | undefined = undefined;
  private observingWindow: boolean = false;
  private avoidRetryTimer: number = -1;
  private onAvoidAreaChanged = (event: window.AvoidAreaOptions): void => {
    if (!this.observingWindow) {
      return;
    }
    if (event.type === window.AvoidAreaType.TYPE_SYSTEM) {
      this.systemAvoidArea = event.area;
    } else if (event.type === window.AvoidAreaType.TYPE_CUTOUT) {
      this.cutoutAvoidArea = event.area;
    } else if (event.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
      this.navigationAvoidArea = event.area;
    } else {
      return;
    }
    try {
      this.updateSafeInsets();
    } catch (error) {
      // Preserve the last valid insets if the window is changing or being destroyed.
    }
  };

  aboutToAppear(): void {
    this.observingWindow = true;
    this.observeSafeArea(false);
  }

  aboutToDisappear(): void {
    this.observingWindow = false;
    if (this.avoidRetryTimer >= 0) {
      clearTimeout(this.avoidRetryTimer);
      this.avoidRetryTimer = -1;
    }
    this.stopSafeAreaObservation();
  }

  private stopSafeAreaObservation(): void {
    if (this.viewerWindow !== undefined) {
      try {
        this.viewerWindow.off('avoidAreaChange', this.onAvoidAreaChanged);
      } catch (error) {}
      this.viewerWindow = undefined;
    }
  }

  private async observeSafeArea(retried: boolean): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('Missing viewer window context');
      }
      const currentWindow: window.Window = await window.getLastWindow(context);
      if (!this.observingWindow) {
        return;
      }
      this.viewerWindow = currentWindow;
      this.systemAvoidArea = currentWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.cutoutAvoidArea = currentWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      this.navigationAvoidArea = currentWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      currentWindow.on('avoidAreaChange', this.onAvoidAreaChanged);
      this.updateSafeInsets();
      this.safeAreaReady = true;
    } catch (error) {
      this.stopSafeAreaObservation();
      if (!this.observingWindow) {
        return;
      }
      if (!retried) {
        this.avoidRetryTimer = setTimeout(() => {
          this.avoidRetryTimer = -1;
          if (this.observingWindow) {
            this.observeSafeArea(true);
          }
        }, 150);
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '图片窗口暂时不可用，请重试' });
        this.onClose();
      }
    }
  }

  private updateSafeInsets(): void {
    if (this.viewerWindow === undefined) {
      return;
    }
    const bounds: window.Rect = this.viewerWindow.getWindowProperties().windowRect;
    const areas: (window.AvoidArea | undefined)[] =
      [this.systemAvoidArea, this.cutoutAvoidArea, this.navigationAvoidArea];
    let topInset: number = 0;
    let bottomInset: number = 0;
    let leftInset: number = 0;
    let rightInset: number = 0;
    for (const area of areas) {
      if (area === undefined) {
        continue;
      }
      if (area.topRect.height > 0) {
        topInset = Math.max(topInset, area.topRect.top + area.topRect.height);
      }
      if (area.bottomRect.height > 0) {
        bottomInset = Math.max(bottomInset, bounds.height - area.bottomRect.top);
      }
      if (area.leftRect.width > 0) {
        leftInset = Math.max(leftInset, area.leftRect.left + area.leftRect.width);
      }
      if (area.rightRect.width > 0) {
        rightInset = Math.max(rightInset, bounds.width - area.rightRect.left);
      }
    }
    const uiContext = this.getUIContext();
    this.safeInsetTop = uiContext.px2vp(Math.max(0, topInset));
    this.safeInsetBottom = uiContext.px2vp(Math.max(0, bottomInset));
    this.safeInsetLeft = uiContext.px2vp(Math.max(0, leftInset));
    this.safeInsetRight = uiContext.px2vp(Math.max(0, rightInset));
  }

  private textColor(): string {
    return this.viewerBackground === COLOR_NIGHT_CARD ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT;
  }

  private secondaryColor(): string {
    return this.viewerBackground === COLOR_NIGHT_CARD ? COLOR_NIGHT_SUB : COLOR_DAY_SUB;
  }

  private clampOffsets(): void {
    const maxX: number = this.viewportWidth * (this.imageScale - 1) / 2;
    const maxY: number = this.viewportHeight * (this.imageScale - 1) / 2;
    this.imageOffsetX = Math.max(-maxX, Math.min(maxX, this.imageOffsetX));
    this.imageOffsetY = Math.max(-maxY, Math.min(maxY, this.imageOffsetY));
  }

  private toggleZoom(): void {
    this.imageScale = this.imageScale > 1 ? 1 : 2.5;
    this.imageOffsetX = 0;
    this.imageOffsetY = 0;
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(20)
            .fontColor([this.textColor()])
        }
        .id('article-image-close')
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .accessibilityText('关闭图片')
        .onClick(() => this.onClose())

        Text('查看图片')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.textColor())
          .layoutWeight(1)

        Button() {
          SymbolGlyph($r('sys.symbol.download'))
            .fontSize(20)
            .fontColor([COLOR_ACCENT_BLUE])
        }
        .id('article-image-save')
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .accessibilityText('保存图片到图库')
        .enabled(!this.isSaving && this.imageLoaded)
        .onClick(() => this.onSave())
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .visibility(this.safeAreaReady ? Visibility.Visible : Visibility.Hidden)

      Stack({ alignContent: Alignment.Center }) {
        Image(this.imageUrl)
          .id('article-image-fullscreen')
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .autoResize(true)
          .draggable(false)
          .scale({ x: this.imageScale, y: this.imageScale })
          .translate({ x: this.imageOffsetX, y: this.imageOffsetY })
          .onComplete(() => {
            this.imageLoaded = true;
            this.imageFailed = false;
          })
          .onError(() => {
            this.imageFailed = true;
            this.imageLoaded = false;
          })

        if (!this.imageLoaded && !this.imageFailed) {
          LoadingProgress().width(36).height(36).color(COLOR_ACCENT_BLUE)
        }
        if (this.imageFailed) {
          Text('图片加载失败，请关闭后重试')
            .fontSize(14)
            .fontColor(this.secondaryColor())
        }
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)
      .onAreaChange((_previous: Area, current: Area) => {
        this.viewportWidth = Number(current.width);
        this.viewportHeight = Number(current.height);
        this.clampOffsets();
      })
      .gesture(
        GestureGroup(GestureMode.Parallel,
          PinchGesture({ fingers: 2 })
            .onActionStart(() => { this.pinchStart = this.imageScale; })
            .onActionUpdate((event: GestureEvent) => {
              this.imageScale = Math.min(5, Math.max(1, this.pinchStart * event.scale));
              this.clampOffsets();
            }),
          PanGesture({ fingers: 1, direction: PanDirection.All })
            .onActionStart(() => {
              this.panStartX = this.imageOffsetX;
              this.panStartY = this.imageOffsetY;
            })
            .onActionUpdate((event: GestureEvent) => {
              this.imageOffsetX = this.panStartX + event.offsetX;
              this.imageOffsetY = this.panStartY + event.offsetY;
              this.clampOffsets();
            }),
          GestureGroup(GestureMode.Exclusive,
            LongPressGesture({ duration: 600, repeat: false })
              .onAction(() => {
                if (!this.isSaving && this.imageLoaded) {
                  this.onSave();
                }
              }),
            TapGesture({ count: 2 })
              .onAction(() => this.toggleZoom())
          )
        )
      )

      Text(this.isSaving ? '正在保存图片…' : '双指缩放 · 双击放大 · 长按保存')
        .fontSize(12)
        .fontColor(this.secondaryColor())
        .padding({ top: 12, bottom: 16 })
        .visibility(this.safeAreaReady ? Visibility.Visible : Visibility.Hidden)
    }
    .id('article-image-viewer')
    .width('100%')
    .height('100%')
    .padding({ top: this.safeInsetTop, bottom: this.safeInsetBottom,
      left: this.safeInsetLeft, right: this.safeInsetRight })
    .backgroundColor(this.viewerBackground)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}

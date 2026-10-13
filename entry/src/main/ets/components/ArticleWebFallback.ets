import { webview } from '@kit.ArkWeb';
import { HttpClient } from '../model/HttpClient';
import { LoginStore } from '../model/LoginStore';
import { COLOR_ACCENT_BLUE, COLOR_DAY_BG, COLOR_DAY_CARD, COLOR_DAY_SUB, COLOR_DAY_TEXT,
  COLOR_NIGHT_BG, COLOR_NIGHT_CARD, COLOR_NIGHT_SUB, COLOR_NIGHT_TEXT,
  themeAccentTextColor, themeDividerColor, themeSecondarySurfaceColor } from '../model/AppTheme';

/** Same-topic HTML reader used only when the native API response is incomplete. */
@Component
export struct ArticleWebFallback {
  @Prop @Watch('onTargetChanged') tid: number = 0;
  @Prop @Watch('onTargetChanged') page: number = 1;
  @Prop nightMode: boolean = false;
  @Prop @Watch('onBottomInsetChanged') bottomSafeAreaInset: number = 0;
  @State private webLoading: boolean = true;
  @State private webFailureMessage: string = '';
  @State private navigationNotice: string = '';
  onRetryNative: (page: number) => void = (page: number): void => {};
  private readerController: webview.WebviewController = new webview.WebviewController();
  private controllerAttached: boolean = false;
  private readerActive: boolean = false;
  private initialBlankFinished: boolean = false;
  private initialTopicStarted: boolean = false;
  private selectedDomain: string = '';
  private currentWebPage: number = 1;
  private webViewportWidth: number = 0;
  private loadTimeout: number = -1;

  aboutToAppear(): void {
    this.readerActive = true;
    this.initialBlankFinished = false;
    this.initialTopicStarted = false;
    this.selectedDomain = HttpClient.getDomain();
    this.currentWebPage = this.page;
  }

  aboutToDisappear(): void {
    this.readerActive = false;
    this.clearLoadTimeout();
    if (this.controllerAttached) {
      try {
        this.readerController.stop();
      } catch (error) {}
    }
    this.controllerAttached = false;
    this.initialBlankFinished = false;
    this.initialTopicStarted = false;
  }

  private onTargetChanged(): void {
    if (this.readerActive && this.controllerAttached && this.initialTopicStarted) {
      this.loadCurrentTopic();
    }
  }

  private onBottomInsetChanged(): void {
    this.updateBottomDocumentInset();
  }

  private onWebViewportChanged(current: Area): void {
    const currentWidth: number = Number(current.width);
    if (!Number.isFinite(currentWidth) || currentWidth <= 0 || currentWidth === this.webViewportWidth) {
      return;
    }
    this.webViewportWidth = currentWidth;
    this.updateBottomDocumentInset();
  }

  private async updateBottomDocumentInset(): Promise<void> {
    if (!this.readerActive || !this.controllerAttached || this.webLoading ||
      this.webFailureMessage.length > 0 || !Number.isFinite(this.webViewportWidth) ||
      this.webViewportWidth <= 0 || !Number.isFinite(this.bottomSafeAreaInset) || this.bottomSafeAreaInset < 0) {
      return;
    }
    try {
      const currentUrl: string = this.readerController.getUrl();
      if (!this.isCurrentTopicUrl(currentUrl)) {
        return;
      }
      // Keep the viewport immersive. Only its scrollable document tail avoids the indicator.
      // ArkWeb pages can have a desktop-width viewport, so translate vp through CSS viewport width.
      const script: string = '(() => { if (window.location.href !== ' + JSON.stringify(currentUrl) +
        ' || !document.body || !Number.isFinite(window.innerWidth) || window.innerWidth <= 0) return;' +
        'const id="nga-harmony-gesture-end-spacer";let tail=document.getElementById(id);' +
        'if(!tail){tail=document.createElement("div");tail.id=id;}' +
        'tail.setAttribute("aria-hidden","true");' +
        'const height=Math.ceil(' + this.bottomSafeAreaInset.toString() + '*window.innerWidth/' +
        this.webViewportWidth.toString() + ');' +
        'tail.style.cssText="display:block;box-sizing:border-box;width:100%;height:"+height+' +
        '"px;min-height:"+height+"px;max-height:none;flex-shrink:0;clear:both;' +
        'margin:0;padding:0;border:0;pointer-events:none;";' +
        'document.body.appendChild(tail); })();';
      await this.readerController.runJavaScript(script);
    } catch (error) {
      // A closing/navigating Web controller must not interrupt otherwise readable content.
    }
  }

  private tryStartInitialTopic(): void {
    if (!this.readerActive || !this.controllerAttached || !this.initialBlankFinished ||
      this.initialTopicStarted) {
      return;
    }
    // The initial src must finish before loadUrl, otherwise its pending navigation can
    // replace the topic URL. Mark first to prevent duplicate/reentrant initial loads.
    this.initialTopicStarted = true;
    this.loadCurrentTopic();
  }

  private onReaderControllerAttached(): void {
    if (!this.readerActive) {
      return;
    }
    this.controllerAttached = true;
    if (!this.initialTopicStarted) {
      this.startLoadTimeout();
      this.tryStartInitialTopic();
    }
  }

  private clearLoadTimeout(): void {
    if (this.loadTimeout >= 0) {
      clearTimeout(this.loadTimeout);
      this.loadTimeout = -1;
    }
  }

  private startLoadTimeout(): void {
    this.clearLoadTimeout();
    this.loadTimeout = setTimeout((): void => {
      this.loadTimeout = -1;
      if (this.readerActive && this.webLoading) {
        this.showMainFrameFailure('网页加载超时，请重新加载或返回应用阅读');
      }
    }, 20000);
  }

  private showMainFrameFailure(message: string): void {
    if (!this.readerActive) {
      return;
    }
    this.clearLoadTimeout();
    this.webLoading = false;
    this.webFailureMessage = message;
  }

  private loadCurrentTopic(): void {
    if (!this.readerActive || !this.controllerAttached) {
      return;
    }
    this.webFailureMessage = '';
    this.navigationNotice = '';
    this.webLoading = true;
    this.currentWebPage = this.page;
    // The Cookie destination must remain the currently selected HTTPS forum origin.
    if (!/^https:\/\/[a-zA-Z0-9.-]+$/.test(this.selectedDomain) ||
      this.selectedDomain !== HttpClient.getDomain() || this.tid <= 0 ||
      !Number.isSafeInteger(this.tid) || this.page < 1 || !Number.isSafeInteger(this.page)) {
      this.showMainFrameFailure('当前话题地址已变化，请返回应用重新打开');
      return;
    }
    try {
      this.readerController.stop();
      // Incognito Cookie storage may outlive an individual Web component. Replace only
      // the two authentication names for this origin before applying the active account.
      webview.WebCookieManager.configCookieSync(this.selectedDomain,
        'ngaPassportUid=; Path=/; Max-Age=0; Secure; HttpOnly', true);
      webview.WebCookieManager.configCookieSync(this.selectedDomain,
        'ngaPassportCid=; Path=/; Max-Age=0; Secure; HttpOnly', true);
      const cookieEntries: string[] = LoginStore.getCookie().split(';');
      for (const cookieEntry of cookieEntries) {
        const cookiePair: string = cookieEntry.trim();
        if (/^ngaPassport(Uid|Cid)=[^;\r\n]+$/.test(cookiePair)) {
          webview.WebCookieManager.configCookieSync(this.selectedDomain,
            cookiePair + '; Path=/; Secure; HttpOnly', true);
        }
      }
      this.startLoadTimeout();
      this.readerController.loadUrl(this.selectedDomain + '/read.php?tid=' +
        this.tid.toString() + '&page=' + this.page.toString());
    } catch (error) {
      // Never expose Cookie values or the underlying Web API exception to the UI/logs.
      this.showMainFrameFailure('网页暂时无法打开，请重新加载或返回应用阅读');
    }
  }

  private isCurrentTopicUrl(requestUrl: string): boolean {
    if (this.selectedDomain !== HttpClient.getDomain() ||
      !requestUrl.startsWith(this.selectedDomain + '/read.php?')) {
      return false;
    }
    const withoutFragment: string = requestUrl.split('#')[0];
    const queryStart: number = withoutFragment.indexOf('?');
    const queryItems: string[] = withoutFragment.substring(queryStart + 1).split('&');
    let topicFound: boolean = false;
    let pageFound: boolean = false;
    for (const queryItem of queryItems) {
      const separator: number = queryItem.indexOf('=');
      if (separator <= 0) {
        return false;
      }
      const queryName: string = queryItem.substring(0, separator);
      const queryValue: string = queryItem.substring(separator + 1);
      if (queryName === 'tid') {
        if (topicFound || queryValue !== this.tid.toString()) {
          return false;
        }
        topicFound = true;
      } else if (queryName === 'page') {
        if (pageFound || !/^[1-9][0-9]*$/.test(queryValue) ||
          !Number.isSafeInteger(Number(queryValue))) {
          return false;
        }
        pageFound = true;
      } else {
        // Keep this reader scoped to ordinary pagination, excluding other actions.
        return false;
      }
    }
    return topicFound;
  }

  private pageFromValidatedUrl(requestUrl: string): number {
    const withoutFragment: string = requestUrl.split('#')[0];
    const queryItems: string[] = withoutFragment.substring(withoutFragment.indexOf('?') + 1).split('&');
    for (const queryItem of queryItems) {
      if (queryItem.startsWith('page=')) {
        const requestedPage: number = Number(queryItem.substring(5));
        if (Number.isSafeInteger(requestedPage) && requestedPage >= 1) {
          return requestedPage;
        }
      }
    }
    return 1;
  }

  private onPageBegan(event: OnPageBeginEvent): void {
    if (this.readerActive && this.isCurrentTopicUrl(event.url)) {
      this.webLoading = true;
      this.webFailureMessage = '';
      this.startLoadTimeout();
    }
  }

  private onPageFinished(event: OnPageEndEvent): void {
    if (this.readerActive && event.url === 'about:blank') {
      this.initialBlankFinished = true;
      this.tryStartInitialTopic();
      return;
    }
    if (this.readerActive && this.isCurrentTopicUrl(event.url)) {
      this.currentWebPage = this.pageFromValidatedUrl(event.url);
      this.clearLoadTimeout();
      this.webLoading = false;
      this.updateBottomDocumentInset();
    }
  }

  private onNavigationCommitted(details: LoadCommittedDetails): void {
    // NGA can paginate with AJAX and pushState without another onPageEnd event.
    if (this.readerActive && details.isMainFrame && details.isSameDocument &&
      this.isCurrentTopicUrl(details.url)) {
      this.currentWebPage = this.pageFromValidatedUrl(details.url);
      this.updateBottomDocumentInset();
    }
  }

  private onMainFrameError(event: OnErrorReceiveEvent): void {
    if (event.request.isMainFrame() && event.request.getRequestUrl() !== 'about:blank') {
      this.showMainFrameFailure('网页加载失败，请检查网络后重新加载');
    }
  }

  private onMainFrameHttpError(event: OnHttpErrorReceiveEvent): void {
    if (event.request.isMainFrame()) {
      this.showMainFrameFailure('网页暂时不可用（HTTP ' +
        event.response.getResponseCode().toString() + '），请稍后重试');
    }
  }

  private interceptNavigation(event: OnLoadInterceptEvent): boolean {
    const requestUrl: string = event.data.getRequestUrl();
    if (requestUrl === 'about:blank') {
      return false;
    }
    if (!event.data.isMainFrame()) {
      return false;
    }
    if (this.readerActive && event.data.getRequestMethod().toUpperCase() === 'GET' &&
      this.isCurrentTopicUrl(requestUrl)) {
      return false;
    }
    if (this.readerActive) {
      this.navigationNotice = '网页阅读仅查看当前话题；其他操作请返回应用';
    }
    return true;
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('网页阅读')
          .id('article-web-fallback-label')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT)
          .layoutWeight(1)
        Button('重新加载', { type: ButtonType.Capsule })
          .id('article-web-reload')
          .fontSize(12)
          .fontColor(themeAccentTextColor(this.nightMode))
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
          .height(32)
          .padding({ left: 12, right: 12 })
          .enabled(!this.webLoading)
          .onClick((): void => this.loadCurrentTopic())
        Button('返回应用阅读', { type: ButtonType.Capsule })
          .id('article-web-return-native')
          .fontSize(12)
          .fontColor('#ffffffff')
          .backgroundColor(COLOR_ACCENT_BLUE)
          .height(32)
          .padding({ left: 12, right: 12 })
          .onClick((): void => this.onRetryNative(this.currentWebPage))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor(this.nightMode ? COLOR_NIGHT_CARD : COLOR_DAY_CARD)
      .border({ width: { bottom: 0.5 }, color: themeDividerColor(this.nightMode) })

      if (this.navigationNotice.length > 0) {
        Text(this.navigationNotice)
          .id('article-web-navigation-notice')
          .fontSize(12)
          .fontColor(this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB)
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
      }

      Stack() {
        Web({ src: 'about:blank', controller: this.readerController, incognitoMode: true })
          .id('article-web-fallback-' + this.tid.toString())
          .width('100%')
          .height('100%')
          .onAreaChange((_previous: Area, current: Area): void => this.onWebViewportChanged(current))
          .backgroundColor(this.nightMode ? COLOR_NIGHT_BG : COLOR_DAY_BG)
          .javaScriptAccess(true)
          .domStorageAccess(false)
          .fileAccess(false)
          .imageAccess(true)
          .geolocationAccess(false)
          .multiWindowAccess(false)
          .mediaPlayGestureAccess(true)
          .mixedMode(MixedMode.None)
          .cacheMode(CacheMode.None)
          .darkMode(this.nightMode ? WebDarkMode.On : WebDarkMode.Off)
          .forceDarkAccess(this.nightMode)
          .onControllerAttached((): void => this.onReaderControllerAttached())
          .onLoadIntercept((event: OnLoadInterceptEvent): boolean => this.interceptNavigation(event))
          .onPageBegin((event: OnPageBeginEvent): void => this.onPageBegan(event))
          .onPageEnd((event: OnPageEndEvent): void => this.onPageFinished(event))
          .onNavigationEntryCommitted((details: LoadCommittedDetails): void => this.onNavigationCommitted(details))
          .onErrorReceive((event: OnErrorReceiveEvent): void => this.onMainFrameError(event))
          .onHttpErrorReceive((event: OnHttpErrorReceiveEvent): void => this.onMainFrameHttpError(event))
          .onSslErrorEventReceive((event: OnSslErrorEventReceiveEvent): void => {
            event.handler.handleCancel();
          })
          .onRenderExited((): void => {
            this.showMainFrameFailure('网页阅读已中断，请重新加载或返回应用阅读');
          })

        if (this.webFailureMessage.length > 0) {
          Column({ space: 12 }) {
            Text('暂时无法显示话题')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT)
            Text(this.webFailureMessage)
              .id('article-web-load-error')
              .fontSize(14)
              .textAlign(TextAlign.Center)
              .fontColor(this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB)
              .padding({ left: 28, right: 28 })
            Button('重试网页', { type: ButtonType.Capsule })
              .id('article-web-error-reload')
              .fontSize(14)
              .fontColor('#ffffffff')
              .backgroundColor(COLOR_ACCENT_BLUE)
              .onClick((): void => this.loadCurrentTopic())
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.nightMode ? COLOR_NIGHT_BG : COLOR_DAY_BG)
        } else if (this.webLoading) {
          Column({ space: 10 }) {
            LoadingProgress()
              .width(32)
              .height(32)
              .color(themeAccentTextColor(this.nightMode))
            Text('正在加载话题网页…')
              .fontSize(14)
              .fontColor(this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.nightMode ? COLOR_NIGHT_BG : COLOR_DAY_BG)
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.nightMode ? COLOR_NIGHT_BG : COLOR_DAY_BG)
  }
}

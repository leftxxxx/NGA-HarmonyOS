/*
 * 帖子详情页（ArticleListPage）。
 * 展示帖子内容和回复，支持底栏翻页与原生页码面板，WebView 渲染帖子 HTML 内容。
 * 支持收藏话题、支持/反对指定楼层、回复帖子。
 * 对应 Android ArticleListFragment + BookmarkTask + LikeTask。
 */

import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import {
  COLOR_ACCENT_BLUE,
  COLOR_DAY_BG, COLOR_NIGHT_BG,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB, themeAccentTextColor,
  themeErrorTextColor, WINDOW_TOP_SAFE_AREA_PX_KEY
} from '../model/AppTheme';
import { ArticleBody } from '../components/ArticleBody';
import { ArticleWebFallback } from '../components/ArticleWebFallback';
import { TopicActionMaterialModifier, topicTitleOptions, topicSurfaceColor,
  topicSecondarySurfaceColor, topicDividerColor } from '../components/TopicUiStyle';
import { SettingsStore, SettingKeys, SettingDefaults, NIGHT_MODE_STORAGE_KEY } from '../model/AppSettings';
import { LoginStore } from '../model/LoginStore';
import { HttpClient, PostFieldMap } from '../model/HttpClient';
import { UrlBuilder } from '../model/UrlBuilder';
import { NgaJsonParser } from '../model/NgaJsonParser';
import { ThreadRowInfo } from '../model/ThreadRowInfo';
import { ThreadData } from '../model/ThreadData';
import { AvatarUtils } from '../model/AvatarUtils';
import { renderArticleContent } from '../model/ArticleHtml';
import { ArticleCacheStore } from '../model/ArticleCacheStore';

const PAGE_SIZE: number = 20;

@Entry
@Component
struct ArticleListPage {
  @StorageLink(WINDOW_TOP_SAFE_AREA_PX_KEY) private topSafeAreaPx: number = 0;
  @StorageLink(NIGHT_MODE_STORAGE_KEY) nightMode: boolean = SettingDefaults.NIGHT;
  @State themeIndex: number = SettingDefaults.THEME;
  @State tid: number = 0;
  @State title: string = '';
  @State rowList: ThreadRowInfo[] = [];
  @State articleRevision: number = 0;
  @State currentPage: number = 1;
  @State requestedPage: number = 1;
  @State totalPages: number = 1;
  @State isLoading: boolean = false;
  @State isRefreshing: boolean = false;
  @State isTurningPage: boolean = false;
  @State pageTurnFeedback: string = '';
  @State loadError: string = '';
  @State webFallbackPage: number = 0;
  @State webFallbackAvailable: boolean = false;
  @State webFallbackTargetPage: number = 1;
  @State totalRows: number = 0;
  @State isFavorited: boolean = false;
  @State actionMsg: string = '';
  @State voteFeedback: Map<string, string> = new Map<string, string>();
  @State private selectedVotes: Map<string, number> = new Map<string, number>();
  @State private voteAccountUid: string = '';
  @State isPerformingAction: boolean = false;
  @State fid: number = 0;
  @State loadCache: boolean = false;
  @State rawData: string = '';
  @State isCacheMode: boolean = false;
  @State cacheMsg: string = '';
  @State currentPageCached: boolean = false;
  @State attachmentBase: string = 'https://img.nga.cn/attachments/';
  @State showPageSheet: boolean = false;
  @State pageInput: string = '';
  @State pageInputError: string = '';
  @State bottomSafeAreaInset: number = 0;

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private readerStack: NavPathStack = new NavPathStack();
  private articleScroller: Scroller = new Scroller();
  private emoticonSources: Map<string, string> = new Map<string, string>();
  private base64: util.Base64Helper = new util.Base64Helper();
  private readerMounted: boolean = false;
  private loadVersion: number = 0;
  private readerAtEnd: boolean = false;
  private pageTurnDistance: number = 0;
  private turnGestureConsumed: boolean = false;
  private refreshRequest: boolean = false;
  private readerWindow: window.Window | undefined = undefined;
  private observingReaderWindow: boolean = false;
  private onBottomAvoidAreaChanged: (options: window.AvoidAreaOptions) => void =
    (options: window.AvoidAreaOptions): void => {
      if (this.readerMounted && (options.type === window.AvoidAreaType.TYPE_SYSTEM ||
        options.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR)) {
        this.updateBottomSafeArea();
      }
    };

  aboutToAppear(): void {
    this.readerMounted = true;
    this.observeBottomSafeArea();
    SettingsStore.init(this.ctx);
    LoginStore.init(this.ctx);
    this.syncVoteAccount();
    ArticleCacheStore.init(this.ctx);
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);

    let initialPage: number = 1;
    // 从路由参数获取话题信息
    const params: Record<string, Object> = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (params !== null && params !== undefined) {
      const tidVal: Object | undefined = params['tid'];
      if (typeof tidVal === 'number') {
        this.tid = tidVal;
      }
      const titleVal: Object | undefined = params['title'];
      if (typeof titleVal === 'string') {
        this.title = titleVal;
      }
      const fidVal: Object | undefined = params['fid'];
      if (typeof fidVal === 'number') {
        this.fid = fidVal;
      }
      const loadCacheVal: Object | undefined = params['loadCache'];
      if (typeof loadCacheVal === 'boolean') {
        this.loadCache = loadCacheVal;
      }
      const pageVal: Object | undefined = params['page'];
      if (typeof pageVal === 'number' && Number.isSafeInteger(pageVal) && pageVal >= 1) {
        initialPage = pageVal;
      }
    }

    if (this.loadCache) {
      this.isCacheMode = true;
      this.loadArticleDataFromCache(initialPage);
    } else {
      this.loadArticleData(initialPage);
    }
  }

  onPageShow(): void {
    this.syncVoteAccount();
    this.currentPageCached = ArticleCacheStore.hasCachePage(this.tid, this.currentPage);
    if (this.readerWindow !== undefined) {
      this.updateBottomSafeArea();
    } else {
      this.observeBottomSafeArea();
    }
  }

  aboutToDisappear(): void {
    this.readerMounted = false;
    if (this.readerWindow !== undefined) {
      this.readerWindow.off('avoidAreaChange', this.onBottomAvoidAreaChanged);
      this.readerWindow = undefined;
    }
    this.loadVersion++;
    this.isLoading = false;
    this.isRefreshing = false;
    this.isTurningPage = false;
    this.refreshRequest = false;
  }

  /* ---------- 状态与工具方法 ---------- */

  private async observeBottomSafeArea(): Promise<void> {
    if (this.observingReaderWindow || this.readerWindow !== undefined || !this.readerMounted) {
      return;
    }
    this.observingReaderWindow = true;
    try {
      const readerWindow: window.Window = await window.getLastWindow(this.ctx);
      if (!this.readerMounted) {
        return;
      }
      this.readerWindow = readerWindow;
      this.updateBottomSafeArea();
      readerWindow.on('avoidAreaChange', this.onBottomAvoidAreaChanged);
    } catch (error) {
      console.warn('[NGA.ArticleReader] 底部安全区暂不可读取');
    } finally {
      this.observingReaderWindow = false;
    }
  }

  private updateBottomSafeArea(): void {
    if (this.readerWindow === undefined) {
      return;
    }
    try {
      const systemArea: window.AvoidArea = this.readerWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navigationArea: window.AvoidArea = this.readerWindow
        .getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.bottomSafeAreaInset = this.getUIContext()
        .px2vp(Math.max(systemArea.bottomRect.height, navigationArea.bottomRect.height));
    } catch (error) {
      // 窗口切换期间保留上次有效间距。
    }
  }

  private accentColor(): string {
    return COLOR_ACCENT_BLUE;
  }

  private pageBg(): string {
    return this.nightMode ? COLOR_NIGHT_BG : COLOR_DAY_BG;
  }

  private cardBg(): string {
    return topicSurfaceColor(this.nightMode);
  }

  private mainTextColor(): string {
    return this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT;
  }

  private subTextColor(): string {
    return this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB;
  }

  private async loadArticleData(page: number, retainContent: boolean = false): Promise<void> {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    this.requestedPage = page;
    this.loadError = '';
    this.pageTurnFeedback = '';
    this.webFallbackAvailable = false;
    const version: number = ++this.loadVersion;
    try {
      const url: string = UrlBuilder.buildArticleUrl(this.tid, page);
      // 系统 HTTP 缓存会随进程复用响应，异常数据不能被重试、刷新或翻页继续命中。
      let result = await HttpClient.get(url, undefined, false);
      if (!this.readerMounted || version !== this.loadVersion) {
        return;
      }
      let threadData: ThreadData = NgaJsonParser.parseThreadData(result.body);
      // 接口偶发以 HTTP 200 返回半截 JSON；仅为已确认未完整返回的响应补请求，最多两次。
      for (const retryDelay of [300, 900]) {
        if (!result.success || !threadData.responseIncomplete) {
          break;
        }
        console.warn('[NGA.Article] tid=' + this.tid.toString() + ' page=' + page.toString() +
          ' response=incomplete retryDelayMs=' + retryDelay.toString());
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, retryDelay);
        });
        if (!this.readerMounted || version !== this.loadVersion) {
          return;
        }
        result = await HttpClient.get(url, undefined, false);
        if (!this.readerMounted || version !== this.loadVersion) {
          return;
        }
        threadData = NgaJsonParser.parseThreadData(result.body);
      }
      if (result.success && threadData.success) {
        this.applyArticleData(threadData, result.body, page);
        console.info('[NGA.Article] tid=' + this.tid.toString() + ' page=' + page.toString() +
          ' rows=' + this.rowList.length.toString());
      } else {
        if (result.success && threadData.responseIncomplete) {
          this.webFallbackAvailable = true;
          this.webFallbackTargetPage = page;
          if (!retainContent || this.rowList.length === 0) {
            this.openWebFallback();
          }
        }
        this.reportReadError(page, result.body.length > 0 && threadData.error.length > 0 ?
          threadData.error : '加载失败，请检查网络后重试', retainContent);
      }
    } catch (err) {
      if (this.readerMounted && version === this.loadVersion) {
        this.reportReadError(page, '加载失败，请检查网络后重试', retainContent);
      }
    } finally {
      if (version === this.loadVersion) {
        this.isLoading = false;
        this.isRefreshing = false;
        this.isTurningPage = false;
        this.refreshRequest = false;
      }
    }
  }

  private reportReadError(page: number, message: string, retainContent: boolean): void {
    if (retainContent && this.rowList.length > 0) {
      if (this.isRefreshing) {
        this.getUIContext().getPromptAction().showToast({ message: '刷新失败：' + message });
      } else {
        this.pageTurnFeedback = '第 ' + page.toString() + ' 页' + message + '，继续上滑可重试';
      }
    } else {
      this.loadError = message;
    }
  }

  private accentTextColor(): string {
    return themeAccentTextColor(this.nightMode);
  }

  private openWebFallback(): void {
    if (!this.readerMounted || !this.webFallbackAvailable || this.isCacheMode ||
      !Number.isSafeInteger(this.webFallbackTargetPage) || this.webFallbackTargetPage < 1) {
      return;
    }
    this.showPageSheet = false;
    this.webFallbackPage = this.webFallbackTargetPage;
  }

  private retryNativeReading(page: number = this.webFallbackPage): void {
    if (!this.readerMounted || this.isLoading || this.isCacheMode ||
      !Number.isSafeInteger(this.webFallbackPage) || this.webFallbackPage < 1 ||
      !Number.isSafeInteger(page) || page < 1) {
      return;
    }
    this.webFallbackPage = 0;
    this.loadArticleData(page);
  }

  private applyArticleData(threadData: ThreadData, rawContent: string, page: number): void {
    this.webFallbackPage = 0;
    this.webFallbackAvailable = false;
    this.rawData = rawContent;
    this.attachmentBase = threadData.attachmentBase;
    this.rowList = threadData.rowList;
    if (threadData.threadInfo.subject.length > 0) {
      this.title = threadData.threadInfo.subject;
    }
    // 各页缓存可能保存于不同时间，旧页不能缩小已知的可阅读范围。
    this.totalRows = this.isCacheMode ? Math.max(this.totalRows, threadData.__ROWS) : threadData.__ROWS;
    this.currentPage = page;
    this.currentPageCached = ArticleCacheStore.hasCachePage(this.tid, page);
    // __ROWS 包含楼主，直接按每页 20 条计算。
    this.totalPages = Math.max(this.isCacheMode ? this.totalPages : 1,
      this.isCacheMode ? page : 1, Math.ceil(this.totalRows / PAGE_SIZE));
    if (this.fid === 0 && threadData.__F !== undefined) {
      const fidStr: string | undefined = threadData.__F['fid'];
      if (fidStr !== undefined) {
        const parsedFid: number = parseInt(fidStr, 10);
        if (Number.isSafeInteger(parsedFid) && parsedFid > 0) {
          this.fid = parsedFid;
        }
      }
    }
    this.loadError = '';
    this.pageTurnFeedback = '';
    this.readerAtEnd = false;
    this.pageTurnDistance = 0;
    // 成功提交后重建阅读列表，快速网络响应与同步缓存翻页都从顶部开始。
    this.articleRevision++;
  }

  /**
   * 从缓存加载帖子数据。
   * 对应 Android ArticleListPresenter.loadCachePage。
   */
  private loadArticleDataFromCache(page: number): void {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    this.requestedPage = page;
    this.loadError = '';
    try {
      const cachedData: string = ArticleCacheStore.loadCachePage(this.tid, page);
      if (cachedData.length === 0) {
        this.reportCachePageError(page, '缓存不存在或读取失败');
        return;
      }
      const threadData: ThreadData = NgaJsonParser.parseThreadData(cachedData);
      if (!threadData.success) {
        this.reportCachePageError(page, '缓存内容无法读取');
        return;
      }
      this.applyArticleData(threadData, cachedData, page);
    } catch (err) {
      this.reportCachePageError(page, '缓存内容无法读取');
    } finally {
      this.isLoading = false;
      this.isRefreshing = false;
      this.isTurningPage = false;
      this.refreshRequest = false;
    }
  }

  private reportCachePageError(page: number, message: string): void {
    const feedback: string = '第 ' + page.toString() + ' 页' + message;
    if (this.rowList.length === 0) {
      this.loadError = feedback;
    } else {
      this.getUIContext().getPromptAction().showToast({ message: feedback });
    }
  }

  /**
   * 缓存当前页。
   * 对应 Android ArticleListPresenter.cachePage → ArticleListModel.cachePage。
   */
  private cacheCurrentPage(): void {
    if (this.isLoading || this.isCacheMode || this.rawData.length === 0) {
      return;
    }

    // 构造话题描述 JSON（ThreadPageInfo 序列化）
    const topicInfo: Record<string, Object> = {};
    topicInfo['tid'] = this.tid;
    topicInfo['subject'] = this.title;
    if (this.rowList.length > 0) {
      topicInfo['author'] = this.rowList[0].author;
      topicInfo['authorid'] = this.rowList[0].authorId;
    }
    topicInfo['replies'] = this.totalRows;
    topicInfo['page'] = this.currentPage;
    const topicInfoJson: string = JSON.stringify(topicInfo);

    const success: boolean = ArticleCacheStore.cachePage(this.tid, this.currentPage, this.rawData, topicInfoJson);
    if (success) {
      this.currentPageCached = true;
      this.cacheMsg = '缓存成功';
    } else {
      this.cacheMsg = '缓存失败';
    }
    this.getUIContext().getPromptAction().showToast({ message: this.cacheMsg });

    // 2 秒后清除提示
    setTimeout(() => {
      this.cacheMsg = '';
    }, 2000);
  }

  /* ---------- 帖子操作 ---------- */

  /**
   * 收藏/取消收藏话题。
   * 对应 Android BookmarkTask。
   */
  private async toggleFavorite(): Promise<void> {
    if (this.isPerformingAction || this.isLoading || this.tid <= 0) {
      return;
    }
    if (!LoginStore.hasUser()) {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录后收藏话题' });
      return;
    }
    const addingFavorite: boolean = !this.isFavorited;
    this.isPerformingAction = true;
    this.actionMsg = '';
    try {
      const fields: PostFieldMap = {};
      const url: string = addingFavorite ? UrlBuilder.buildAddFavoriteUrl(this.tid) :
        UrlBuilder.buildRemoveFavoriteUrl();
      if (!addingFavorite) {
        fields['__lib'] = 'topic_favor';
        fields['__act'] = 'topic_favor';
        fields['__output'] = '8';
        fields['action'] = 'del';
        fields['page'] = '1';
        fields['tidarray'] = this.tid.toString();
      }
      const result = await HttpClient.post(url, fields, true);
      const message: string = NgaJsonParser.parsePostActionResult(result.body);
      const confirmed: boolean = addingFavorite ?
        /操作成功|收藏成功|添加成功|已经收藏|已收藏|已经存在|已存在/.test(message) :
        /操作成功|取消收藏成功|删除成功|移除成功/.test(message);
      if (result.success && confirmed && !/失败|未成功|不成功|错误/.test(message)) {
        this.isFavorited = addingFavorite;
        this.actionMsg = addingFavorite ? '收藏成功' : '取消收藏成功';
      } else {
        this.actionMsg = message.length > 0 ? message :
          (addingFavorite ? '未能确认收藏结果，请稍后重试' : '未能确认取消收藏结果，请稍后重试');
      }
    } catch (err) {
      this.actionMsg = addingFavorite ? '收藏失败，请检查网络后重试' : '取消收藏失败，请检查网络后重试';
    } finally {
      this.isPerformingAction = false;
    }
    this.getUIContext().getPromptAction().showToast({ message: this.actionMsg });
  }

  /**
   * 支持/反对当前楼层，不能将未知回复 ID 当作主帖 ID。
   * 对应 Android LikeTask。
   * value=1 支持，value=-1 反对
   */
  private async likePost(row: ThreadRowInfo, value: number): Promise<void> {
    if (this.isPerformingAction || this.isLoading || (value !== 1 && value !== -1)) {
      return;
    }
    const feedbackKey: string = this.postKey(row);
    if (!this.isValidPostTarget(row)) {
      this.voteFeedback.set(feedbackKey, '无法确认这条回复，请重新加载话题后再试');
      return;
    }
    // 翻页或异步响应期间始终保留点击时的楼层身份。
    const targetTid: number = row.tid;
    const targetPid: number = row.pid;
    const targetLabel: string = this.postTargetLabel(row);
    this.syncVoteAccount();
    const targetAccountUid: string = this.voteAccountUid;
    const voteStateKey: string = targetAccountUid + ':' + feedbackKey;
    const actionLabel: string = value === 1 ? '支持' : '反对';
    this.isPerformingAction = true;
    this.voteFeedback.set(feedbackKey, '正在' + actionLabel + targetLabel + '…');
    try {
      const url: string = UrlBuilder.buildLikeUrl();
      const fields: PostFieldMap = {};
      fields['__lib'] = 'topic_recommend';
      fields['__act'] = 'add';
      fields['raw'] = '3';
      fields['__output'] = '8';
      fields['value'] = value.toString();
      fields['tid'] = targetTid.toString();
      fields['pid'] = targetPid.toString();

      const result = await HttpClient.post(url, fields, true);
      if (!this.readerMounted) {
        return;
      }
      if (result.success) {
        const confirmedDirection: number | undefined = NgaJsonParser.parsePostVoteDirection(result.body, value);
        if (targetAccountUid.length > 0 && confirmedDirection !== undefined) {
          this.selectedVotes.set(voteStateKey, confirmedDirection);
        }
      }
      this.voteFeedback.set(feedbackKey, result.success ?
        this.formatVoteResult(result.body, targetLabel, value) :
        targetLabel + '：' + actionLabel + '失败，请稍后重试');
    } catch (err) {
      this.voteFeedback.set(feedbackKey, targetLabel + '：' + actionLabel + '失败，请检查网络后重试');
    } finally {
      this.isPerformingAction = false;
    }
  }

  private isValidPostTarget(row: ThreadRowInfo): boolean {
    return Number.isSafeInteger(this.tid) && this.tid > 0 && row.tid === this.tid &&
      Number.isSafeInteger(row.pid) && row.pid >= 0 &&
      Number.isSafeInteger(row.lou) && row.lou >= 0 &&
      ((row.pid === 0 && row.lou === 0) || (row.pid > 0 && row.lou > 0));
  }

  private postKey(row: ThreadRowInfo): string {
    const identity: string = String(row.tid) + '_' + String(row.pid) + '_' + String(row.lou);
    // 缺失身份的行仍可阅读，用本页位置区分，避免重复键隐藏其它回复。
    const hasIdentity: boolean = Number.isSafeInteger(row.pid) && row.pid >= 0 &&
      Number.isSafeInteger(row.lou) && row.lou >= 0;
    return hasIdentity ? identity : identity + '_' + this.currentPage.toString() + '_' +
      this.rowList.indexOf(row).toString();
  }

  private postTargetLabel(row: ThreadRowInfo): string {
    if (row.lou < 0) {
      return '这条回复';
    }
    return row.pid === 0 && row.lou === 0 ? '楼主正文' : '第 ' + row.lou.toString() + ' 楼回复';
  }

  private voteMessage(row: ThreadRowInfo): string {
    return this.voteFeedback.get(this.postKey(row)) ?? '';
  }

  private syncVoteAccount(): void {
    this.voteAccountUid = LoginStore.getUser().uid;
  }

  private isVoteSelected(row: ThreadRowInfo, direction: number): boolean {
    return (direction === 1 || direction === -1) &&
      (this.selectedVotes.get(this.voteAccountUid + ':' + this.postKey(row)) ?? 0) === direction;
  }

  private voteIconColor(row: ThreadRowInfo, direction: number): string {
    return this.isVoteSelected(row, direction) ? this.accentTextColor() : this.subTextColor();
  }

  private voteButtonBackground(row: ThreadRowInfo, direction: number): ResourceColor {
    return this.isVoteSelected(row, direction) ? topicSecondarySurfaceColor(this.nightMode) : Color.Transparent;
  }

  /**
   * 跳转到回复页面。
   */
  private goToReply(): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ReplyPage',
      params: { action: 'reply', tid: this.tid, fid: this.fid, title: this.title }
    });
  }

  /**
   * 保留接口反馈语义，同时明确它所对应的楼层。
   */
  private formatVoteResult(body: string, targetLabel: string, value: number): string {
    const message: string = NgaJsonParser.parsePostActionResult(body);
    if (message.length > 0) {
      const scopedMessage: string = message.replace(/这个帖子|该帖子|本帖/g, targetLabel);
      return scopedMessage.indexOf(targetLabel) >= 0 ? scopedMessage : targetLabel + '：' + scopedMessage;
    }
    return targetLabel + '：未能确认' + (value === 1 ? '支持' : '反对') + '结果，请刷新后查看';
  }

  /* ---------- 工具方法 ---------- */

  private getLouText(lou: number): string {
    if (lou < 0) {
      return '回复';
    }
    if (lou === 0) {
      return '楼主';
    }
    return lou.toString() + '#';
  }

  private getAvatarUrl(avatar: string): string {
    if (avatar.length === 0) {
      return '';
    }
    // 使用 AvatarUtils 解析多帧头像 JSON 转义字符串
    const parsed: string = AvatarUtils.parseAvatarUrl(avatar);
    if (parsed.length === 0) {
      return '';
    }
    if (parsed.startsWith('http://') || parsed.startsWith('https://')) {
      return parsed;
    }
    return 'https://bbs.nga.cn' + parsed;
  }

  /**
   * 跳转到作者用户主页。
   */
  private goToUserProfile(authorId: number): void {
    if (authorId <= 0) {
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/UserProfilePage',
      params: { uid: authorId }
    });
  }

  private getLocalEmoticonSource(path: string): string {
    const cached: string | undefined = this.emoticonSources.get(path);
    if (cached !== undefined) {
      return cached;
    }
    let source: string = '';
    try {
      const bytes: Uint8Array = this.ctx.resourceManager.getRawFileContentSync(path);
      const mime: string = path.endsWith('.gif') ? 'image/gif' : 'image/png';
      source = 'data:' + mime + ';base64,' + this.base64.encodeToStringSync(bytes);
    } catch (err) {
      // 缺失资源交给解码器回退，正文仍然可读。
    }
    this.emoticonSources.set(path, source);
    return source;
  }

  private buildHtmlContent(content: string): string {
    const bgColor: string = '#' + this.cardBg().substring(3);
    const textColor: string = '#' + this.mainTextColor().substring(3);
    const linkColor: string = '#' + themeAccentTextColor(this.nightMode).substring(3);
    const decodedContent: string = renderArticleContent(content, this.attachmentBase,
      (path: string): string => this.getLocalEmoticonSource(path), HttpClient.getDomain() + '/');
    const html: string = '<!DOCTYPE html><html><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width,initial-scale=1.0">' +
      '<style>' +
      'html{background:' + bgColor + ';}' +
      'body{background:' + bgColor + ';color:' + textColor + ';font-size:16px;line-height:1.75;padding:0;margin:0;overflow-wrap:anywhere;}' +
      'img{max-width:100%;height:auto;}' +
      'img.article-image{display:block;margin:12px 0;border-radius:12px;}' +
      'img.emoticon{height:1.5em;width:auto;vertical-align:middle;display:inline-block;}' +
      'blockquote{margin:8px 0;padding:8px;border-left:3px solid ' + linkColor + ';}' +
      (this.nightMode ? 'img.invertFilter{filter:invert(100%);}' : '') +
      'a{color:' + linkColor + ';}' +
      '</style></head><body>' + decodedContent + '</body></html>';
    return html;
  }

  /* ---------- 阅读操作 ---------- */

  private openPageSheet(): void {
    this.pageInput = '';
    this.pageInputError = '';
    this.showPageSheet = true;
  }

  private changePage(page: number): void {
    if (!Number.isSafeInteger(page) || page < 1 || page > this.totalPages || this.isLoading) {
      return;
    }
    if (page === this.currentPage && this.loadError.length === 0) {
      this.showPageSheet = false;
      return;
    }
    if (this.isCacheMode && !ArticleCacheStore.hasCachePage(this.tid, page)) {
      const message: string = '第 ' + page.toString() + ' 页尚未缓存';
      if (this.showPageSheet) {
        this.pageInputError = message;
      } else {
        this.getUIContext().getPromptAction().showToast({ message: message });
      }
      return;
    }
    this.showPageSheet = false;
    if (this.isCacheMode) {
      this.loadArticleDataFromCache(page);
    } else {
      this.loadArticleData(page);
    }
  }

  private nearbyPages(): number[] {
    const pageCount: number = Math.min(5, this.totalPages);
    const firstPage: number = Math.max(1, Math.min(this.currentPage - 2, this.totalPages - pageCount + 1));
    const pages: number[] = [];
    for (let page: number = firstPage; page < firstPage + pageCount; page++) {
      pages.push(page);
    }
    return pages;
  }

  private submitPage(): void {
    const input: string = this.pageInput.trim();
    if (!/^\d+$/.test(input)) {
      this.pageInputError = '请输入有效页码';
      return;
    }
    const target: number = Number(input);
    if (!Number.isSafeInteger(target) || target < 1 || target > this.totalPages) {
      this.pageInputError = '页码范围为 1–' + this.totalPages.toString();
      return;
    }
    this.changePage(target);
  }

  private replyToPost(row: ThreadRowInfo): void {
    if (!this.isValidPostTarget(row)) {
      this.getUIContext().getPromptAction().showToast({ message: '无法确认这条回复，请重新加载话题后再试' });
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ReplyPage',
      params: { action: 'reply', tid: this.tid, fid: this.fid, pid: row.pid, title: this.title }
    });
  }

  private refreshArticle(): void {
    // 成功页码只在成功加载后更新，失败重试仍请求原目标页。
    const targetPage: number = this.loadError.length > 0 ? this.requestedPage : this.currentPage;
    if (this.isCacheMode) {
      this.loadArticleDataFromCache(targetPage);
    } else {
      this.loadArticleData(targetPage);
    }
  }

  private pullRefreshArticle(): void {
    if (this.isLoading || !this.readerMounted) {
      // 重复刷新保留正在进行的刷新；其他请求期间结束误置的双向绑定。
      this.isRefreshing = this.isLoading && this.refreshRequest;
      return;
    }
    this.refreshRequest = true;
    this.isRefreshing = true;
    this.pageTurnDistance = 0;
    this.turnGestureConsumed = true;
    if (this.isCacheMode) {
      this.loadArticleDataFromCache(this.currentPage);
    } else {
      this.loadArticleData(this.currentPage, true);
    }
  }

  private readerTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.pageTurnDistance = 0;
      this.turnGestureConsumed = false;
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.pageTurnDistance = 0;
    }
  }

  private readerScroll(scrollOffset: number, scrollSource: ScrollSource): void {
    // 只响应手指在页尾继续向后浏览；惯性、回弹和程序滚动都不能自动翻页。
    if (scrollSource !== ScrollSource.DRAG || this.isLoading || this.isRefreshing ||
      this.turnGestureConsumed || !this.readerMounted || this.rowList.length === 0) {
      return;
    }
    if (scrollOffset < 0) {
      this.readerAtEnd = false;
      this.pageTurnDistance = 0;
      return;
    }
    // 图片解码后的正文可能增高，旧的 onReachEnd 状态不能触发中途翻页。
    if (!this.articleScroller.isAtEnd()) {
      this.readerAtEnd = false;
      this.pageTurnDistance = 0;
      return;
    }
    if (!this.readerAtEnd || scrollOffset <= 0 || this.currentPage >= this.totalPages) {
      return;
    }
    this.pageTurnDistance += scrollOffset;
    if (this.pageTurnDistance < 48) {
      return;
    }
    this.turnGestureConsumed = true;
    this.pageTurnDistance = 0;
    const current: number = this.currentPage;
    const version: number = this.loadVersion;
    // 避免在滚动布局回调中销毁当前 List。
    setTimeout(() => {
      if (this.readerMounted && !this.isLoading && current === this.currentPage && version === this.loadVersion) {
        if (!this.articleScroller.isAtEnd()) {
          this.readerAtEnd = false;
          this.pageTurnDistance = 0;
          this.turnGestureConsumed = false;
          return;
        }
        this.turnNextPage();
      }
    }, 0);
  }

  private turnNextPage(): void {
    if (this.isLoading || !this.readerMounted || this.currentPage >= this.totalPages) {
      return;
    }
    const page: number = this.currentPage + 1;
    if (this.isCacheMode && !ArticleCacheStore.hasCachePage(this.tid, page)) {
      this.pageTurnFeedback = '第 ' + page.toString() + ' 页尚未缓存，可使用底栏选择其他已缓存页';
      return;
    }
    this.isTurningPage = true;
    if (this.isCacheMode) {
      this.loadArticleDataFromCache(page);
    } else {
      this.loadArticleData(page, true);
    }
  }

  @Builder
  TopicHeading() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(this.isCacheMode ? '离线缓存' : '话题')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentTextColor())
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
          .borderRadius(16)
        Text(Math.max(0, this.totalRows - 1).toString() + ' 条回复')
          .fontSize(12)
          .fontColor(this.subTextColor())
      }
      Text(this.title.length > 0 ? this.title : '话题详情')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.mainTextColor())
        .lineHeight(34)
        .width('100%')
      Text('第 ' + this.currentPage.toString() + ' 页 · 共 ' + this.totalPages.toString() + ' 页')
        .fontSize(12)
        .fontColor(this.subTextColor())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8, bottom: 24 })
  }

  @Builder
  FeedbackBanner(message: string) {
    Text(message)
      .fontSize(14)
      .fontColor(this.accentTextColor())
      .width('100%')
      .padding(12)
      .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
      .borderRadius(16)
  }

  @Builder
  ErrorView() {
    Column({ space: 16 }) {
      SymbolGlyph($r('sys.symbol.message'))
        .fontSize(36)
        .fontColor([this.subTextColor()])
      Text('第 ' + this.requestedPage.toString() + ' 页加载失败')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.mainTextColor())
      Text(this.loadError)
        .fontSize(16)
        .fontColor(this.subTextColor())
        .textAlign(TextAlign.Center)
        .id('article-load-error-' + this.tid.toString())
      Button('重试')
        .fontSize(16)
        .height(44)
        .padding({ left: 28, right: 28 })
        .backgroundColor(this.accentColor())
        .fontColor(Color.White)
        .enabled(!this.isLoading)
        .onClick(() => this.refreshArticle())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 64, bottom: 96 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  EmptyView() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.message'))
        .fontSize(36)
        .fontColor([this.subTextColor()])
      Text('该话题暂无内容')
        .fontSize(16)
        .fontColor(this.subTextColor())
    }
    .width('100%')
    .height('100%')
    .padding({ top: 64, bottom: 96 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  ArticleListView() {
    List({ space: 12, scroller: this.articleScroller }) {
      ListItem() {
        this.TopicHeading()
      }
      if (this.webFallbackAvailable) {
        ListItem() {
          Column({ space: 8 }) {
            Text('第 ' + this.webFallbackTargetPage.toString() + ' 页响应不完整，已保留当前正文')
              .fontSize(13)
              .fontColor(this.subTextColor())
            Button('使用网页阅读')
              .fontSize(14)
              .height(40)
              .fontColor(this.accentTextColor())
              .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
              .enabled(!this.isLoading)
              .id('article-open-web-fallback')
              .onClick(() => this.openWebFallback())
          }
          .width('100%')
          .padding(12)
          .backgroundColor(this.cardBg())
          .borderRadius(16)
        }
      }
      if (this.actionMsg.length > 0) {
        ListItem() {
          this.FeedbackBanner(this.actionMsg)
        }
      }
      if (this.cacheMsg.length > 0) {
        ListItem() {
          this.FeedbackBanner(this.cacheMsg)
        }
      }
      ForEach(this.rowList, (row: ThreadRowInfo) => {
        ListItem() {
          this.PostItem(row)
        }
      }, (row: ThreadRowInfo) => this.postKey(row))

      ListItem() {
        Column({ space: 12 }) {
          if (this.isTurningPage) {
            Row({ space: 8 }) {
              LoadingProgress().width(20).height(20).color(this.accentTextColor())
              Text('正在加载第 ' + this.requestedPage.toString() + ' 页')
                .fontSize(13).fontColor(this.subTextColor())
            }
            .justifyContent(FlexAlign.Center)
          } else {
            Text(this.pageTurnFeedback.length > 0 ? this.pageTurnFeedback :
              (this.currentPage < this.totalPages ? '继续上滑，进入下一页' : '已到最后一页'))
              .fontSize(13).fontColor(this.subTextColor()).textAlign(TextAlign.Center)
              .id('article-page-end-hint')
          }
          if (this.webFallbackAvailable) {
            Button('使用网页查看第 ' + this.webFallbackTargetPage.toString() + ' 页')
              .fontSize(14)
              .height(40)
              .fontColor(this.accentTextColor())
              .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
              .enabled(!this.isLoading)
              .id('article-page-end-web-fallback')
              .onClick(() => this.openWebFallback())
          }
          Row({ space: 12 }) {
          Button('上一页')
            .fontSize(14)
            .height(40)
            .fontColor(this.accentTextColor())
            .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
            .layoutWeight(1)
            .enabled(this.currentPage > 1 && !this.isLoading)
            .onClick(() => this.changePage(this.currentPage - 1))
          Button(this.currentPage < this.totalPages ? '下一页' : '已到最后一页')
            .fontSize(14)
            .height(40)
            .fontColor(this.accentTextColor())
            .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
            .layoutWeight(1)
            .enabled(this.currentPage < this.totalPages && !this.isLoading)
            .onClick(() => this.changePage(this.currentPage + 1))
          }
          .width('100%')
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .contentStartOffset(64)
    .contentEndOffset(96 + this.bottomSafeAreaInset)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onTouch((event: TouchEvent) => this.readerTouch(event))
    .onReachEnd(() => { this.readerAtEnd = true; })
    .onWillScroll((scrollOffset: number, scrollState: ScrollState, scrollSource: ScrollSource) => {
      this.readerScroll(scrollOffset, scrollSource);
    })
    .onAppear(() => {
      this.articleScroller.scrollEdge(Edge.Top);
    })
  }

  @Builder
  PostItem(row: ThreadRowInfo) {
    Column({ space: 16 }) {
      Row({ space: 10 }) {
        Image(this.getAvatarUrl(row.avatar).length > 0 ?
          this.getAvatarUrl(row.avatar) : $r('app.media.default_board_icon'))
          .width(36)
          .height(36)
          .borderRadius(18)
          .alt($r('app.media.default_board_icon'))
          .onClick(() => this.goToUserProfile(row.authorId))

        Column({ space: 4 }) {
          Text(row.author)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.mainTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick(() => this.goToUserProfile(row.authorId))
          if (row.postdate.length > 0) {
            Text(row.postdate)
              .fontSize(11)
              .fontColor(this.subTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.getLouText(row.lou))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(row.lou === 0 ? this.accentTextColor() : this.subTextColor())
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
          .borderRadius(12)
      }
      .width('100%')

      if (row.content.length > 0) {
        ArticleBody({ html: this.buildHtmlContent(row.content), bodyBackground: this.cardBg(),
          baseUrl: HttpClient.getDomain() + '/' })
          .width('100%')
      }

      Row({ space: 8 }) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.hand_thumbsup'))
            .fontSize(16)
            .fontColor([this.voteIconColor(row, 1)])
        }
        .width(36)
        .height(36)
        .backgroundColor(this.voteButtonBackground(row, 1))
        .accessibilityText('支持' + this.postTargetLabel(row))
        .accessibilitySelected(this.isVoteSelected(row, 1))
        .enabled(!this.isPerformingAction && !this.isLoading)
        .onClick(() => { this.likePost(row, 1); })

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.hand_thumbsdown'))
            .fontSize(16)
            .fontColor([this.voteIconColor(row, -1)])
        }
        .width(36)
        .height(36)
        .backgroundColor(this.voteButtonBackground(row, -1))
        .accessibilityText('反对' + this.postTargetLabel(row))
        .accessibilitySelected(this.isVoteSelected(row, -1))
        .enabled(!this.isPerformingAction && !this.isLoading)
        .onClick(() => { this.likePost(row, -1); })

        Blank()

        Button({ type: ButtonType.Capsule }) {
          Row({ space: 5 }) {
            SymbolGlyph($r('sys.symbol.arrowshape_turn_up_left'))
              .fontSize(16)
              .fontColor([this.accentTextColor()])
            Text('回复').fontSize(12).fontColor(this.accentTextColor())
          }
        }
        .height(36)
        .padding({ left: 10, right: 10 })
        .backgroundColor(Color.Transparent)
        .onClick(() => this.replyToPost(row))
      }
      .width('100%')
      .border({ width: { top: 0.5 }, color: topicDividerColor(this.nightMode) })
      .padding({ top: 8 })

      if (this.voteMessage(row).length > 0) {
        Text(this.voteMessage(row))
          .fontSize(12)
          .fontColor(this.accentTextColor())
          .width('100%')
          .padding(12)
          .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
          .borderRadius(12)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(this.cardBg())
    .borderRadius(20)
  }

  @Builder
  PageSheet() {
    Column({ space: 20 }) {
      Text('当前第 ' + this.currentPage.toString() + ' 页，共 ' + this.totalPages.toString() + ' 页')
        .fontSize(14)
        .fontColor(this.subTextColor())
      Row({ space: 8 }) {
        ForEach(this.nearbyPages(), (pageNumber: number) => {
          Button(pageNumber.toString(), { type: ButtonType.Capsule })
            .height(44)
            .layoutWeight(1)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(pageNumber === this.currentPage ? Color.White : this.mainTextColor())
            .backgroundColor(pageNumber === this.currentPage ? this.accentColor() :
              topicSecondarySurfaceColor(this.nightMode))
            .accessibilityText('第' + pageNumber.toString() + '页' +
              (pageNumber === this.currentPage ? '，当前页' : ''))
            .enabled(!this.isLoading)
            .onClick(() => this.changePage(pageNumber))
        }, (pageNumber: number): string => pageNumber.toString())
      }
      .width('100%')
      Row({ space: 12 }) {
        TextInput({ text: this.pageInput, placeholder: '输入 1–' + this.totalPages.toString() + ' 页' })
          .type(InputType.Number)
          .layoutWeight(1)
          .height(48)
          .fontColor(this.mainTextColor())
          .placeholderColor(this.subTextColor())
          .caretColor(this.accentTextColor())
          .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
          .borderRadius(24)
          .onChange((text: string) => {
            this.pageInput = text;
            this.pageInputError = '';
          })
          .onSubmit(() => this.submitPage())
        Button('跳转')
          .height(48)
          .fontSize(16)
          .backgroundColor(this.accentColor())
          .fontColor(Color.White)
          .enabled(!this.isLoading)
          .onClick(() => this.submitPage())
      }
      .width('100%')

      if (this.pageInputError.length > 0) {
        Text(this.pageInputError).fontSize(13).fontColor(themeErrorTextColor(this.nightMode))
      }
      if (this.isCacheMode) {
        Text('离线阅读仅可跳转到已缓存的页码')
          .fontSize(12)
          .fontColor(this.subTextColor())
      }
      Row({ space: 12 }) {
        Button('首页')
          .height(44)
          .layoutWeight(1)
          .fontColor(this.accentTextColor())
          .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
          .enabled(this.currentPage > 1 && !this.isLoading)
          .onClick(() => this.changePage(1))
        Button('末页')
          .height(44)
          .layoutWeight(1)
          .fontColor(this.accentTextColor())
          .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
          .enabled(this.currentPage < this.totalPages && !this.isLoading)
          .onClick(() => this.changePage(this.totalPages))
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 16, bottom: 32 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ReplyActionButton() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.message'))
        .fontSize(24)
        .fontColor([this.accentTextColor()])
    }
    .width(44)
    .height(44)
    .backgroundColor(Color.Transparent)
    .id('article-reply-button')
    .accessibilityText('回复话题')
    .enabled(this.tid > 0)
    .onClick(() => this.goToReply())
  }

  @Builder
  PageActionGroup() {
    Row({ space: 2 }) {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(20)
          .fontColor([this.mainTextColor()])
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .opacity(this.currentPage > 1 ? 1 : 0.35)
      .accessibilityText('上一页')
      .enabled(this.currentPage > 1 && !this.isLoading)
      .onClick(() => this.changePage(this.currentPage - 1))

      Button({ type: ButtonType.Capsule }) {
        Text(this.currentPage.toString() + ' / ' + this.totalPages.toString())
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.mainTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      .height(44)
      .layoutWeight(1)
      .padding({ left: 4, right: 4 })
      .backgroundColor(Color.Transparent)
      .accessibilityText('跳转页码，当前第' + this.currentPage.toString() + '页，共' + this.totalPages.toString() + '页')
      .enabled(!this.isLoading)
      .onClick(() => this.openPageSheet())
      .bindSheet($$this.showPageSheet, this.PageSheet, {
        height: SheetSize.FIT_CONTENT,
        title: { title: '跳转页码' },
        backgroundColor: this.cardBg(),
        dragBar: true,
        showClose: true
      })

      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(20)
          .fontColor([this.mainTextColor()])
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .opacity(this.currentPage < this.totalPages ? 1 : 0.35)
      .accessibilityText('下一页')
      .enabled(this.currentPage < this.totalPages && !this.isLoading)
      .onClick(() => this.changePage(this.currentPage + 1))

      Button({ type: ButtonType.Circle }) {
        SymbolGlyph(this.isFavorited ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
          .fontSize(24)
          .fontColor([this.isFavorited ? this.accentTextColor() : this.mainTextColor()])
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .id('article-favorite-button')
      .accessibilityText(this.isFavorited ? '取消收藏话题' : '收藏话题')
      .enabled(this.tid > 0 && !this.isPerformingAction && !this.isLoading)
      .onClick(() => { this.toggleFavorite(); })

      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.download'))
          .fontSize(24)
          .fontColor([this.currentPageCached ? this.accentTextColor() : this.mainTextColor()])
      }
      .width(44)
      .height(44)
      .backgroundColor(Color.Transparent)
      .id('article-cache-button')
      .accessibilityText(this.isCacheMode ? '当前页已缓存' :
        (this.currentPageCached ? '更新当前页缓存' : '缓存当前页'))
      .enabled(!this.isCacheMode && this.rawData.length > 0 && !this.isLoading)
      .onClick(() => this.cacheCurrentPage())
    }
    .layoutWeight(1)
    .constraintSize({ maxWidth: 244 })
    .padding({ top: 6, bottom: 6 })
    .borderRadius(28)
    .id('article-page-action-group')
    .attributeModifier(new TopicActionMaterialModifier(this.nightMode))
  }

  @Builder
  BottomActionBar() {
    Row({ space: 8 }) {
      this.PageActionGroup()
      Row() {
        this.ReplyActionButton()
      }
      .width(56)
      .height(56)
      .padding(6)
      .borderRadius(28)
      .id('article-reply-action-group')
      .attributeModifier(new TopicActionMaterialModifier(this.nightMode))
    }
    .width('100%')
    // 仅操作栏保留手势区间距，阅读列表不受这段透明留白压缩。
    .padding({ left: 12, right: 12, top: 12, bottom: 12 + this.bottomSafeAreaInset })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ReaderDestination(name: string, param: Object) {
    NavDestination() {
      if (this.webFallbackPage > 0) {
        Column() {
          ArticleWebFallback({ tid: this.tid, page: this.webFallbackPage, nightMode: this.nightMode,
            bottomSafeAreaInset: this.bottomSafeAreaInset,
            onRetryNative: (page: number): void => this.retryNativeReading(page) })
            .width('100%')
            .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .padding({ top: 64 })
        .backgroundColor(this.pageBg())
      } else {
      // HarmonyOS 7 的操作材质在横向底部 TabBar 内生效。
      Tabs({ barPosition: BarPosition.End }) {
        TabContent() {
          Stack() {
            if (this.isLoading && !this.isRefreshing && !this.isTurningPage) {
              Column() {
                LoadingProgress().width(40).height(40).color(this.accentTextColor())
                Text('正在加载第 ' + this.requestedPage.toString() + ' 页')
                  .fontSize(14).fontColor(this.subTextColor()).margin({ top: 12 })
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
            } else if (this.loadError.length > 0) {
              this.ErrorView()
            } else if (this.rowList.length === 0) {
              this.EmptyView()
            } else {
              Refresh({ refreshing: $$this.isRefreshing }) {
                Column() {
                  ForEach([this.articleRevision], (revision: number) => {
                    this.ArticleListView()
                  }, (revision: number): string => revision.toString())
                }
                .width('100%')
                .height('100%')
              }
              .width('100%')
              .height('100%')
              .pullToRefresh(!this.isLoading)
              .onRefreshing(() => this.pullRefreshArticle())
              .id('article-pull-refresh')
            }
          }
          .width('100%')
          .height('100%')
        }
        .height(LayoutPolicy.matchParent)
        .clip(false)
        .tabBar(this.BottomActionBar)
      }
      .vertical(false)
      .scrollable(false)
      .barOverlap(true)
      .barHeight(80 + this.bottomSafeAreaInset)
      .barBackgroundColor(Color.Transparent)
      .barBackgroundBlurStyle(BlurStyle.NONE)
      .divider(null)
      .expandSafeArea([], [])
      .width('100%')
      .height(LayoutPolicy.matchParent)
      .safeAreaPadding({ bottom: 0 })
      .backgroundColor(this.pageBg())
      }
    }
    // 仅扩展底部正文布局，顶部继续由原生标题栏避让。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .title('话题详情', topicTitleOptions(this.nightMode))
    .hideBackButton(false)
    .hideToolBar(true)
    .backgroundColor(this.pageBg())
    .onBackPressed(() => {
      this.getUIContext().getRouter().back();
      return true;
    })
  }

  build() {
    Column() {
      Navigation(this.readerStack) {
      }
      .width('100%')
      .height(LayoutPolicy.matchParent)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)
      .navDestination(this.ReaderDestination)
      .backgroundColor(this.pageBg())
      .onAppear(() => {
        if (this.readerStack.size() === 0) {
          this.readerStack.pushPath({ name: 'ArticleReader' }, { animated: false });
        }
      })
    }
    .width('100%')
    .height(LayoutPolicy.matchParent)
    .padding({ top: this.getUIContext().px2vp(this.topSafeAreaPx) })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .backgroundColor(this.pageBg())
    // 页面延伸到底部，操作栏独立避让系统手势区。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

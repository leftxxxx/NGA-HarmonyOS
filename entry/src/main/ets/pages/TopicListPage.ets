/*
 * 话题列表页（TopicListPage）。
 * 展示某板块下的话题列表，支持下拉刷新、滚动到底部自动加载下一页。
 * 对应 Android TopicListFragment。
 */

import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import {
  COLOR_ACCENT_BLUE,
  COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB, themeAccentTextColor, applyWindowTheme,
  WINDOW_TOP_SAFE_AREA_PX_KEY
} from '../model/AppTheme';
import { SettingsStore, SettingKeys, SettingDefaults, NIGHT_MODE_STORAGE_KEY } from '../model/AppSettings';
import { LoginStore } from '../model/LoginStore';
import { TopicPostStore } from '../model/TopicPostStore';
import { PostGripObserver } from '../model/PostGripObserver';
import { RecentBoardStore } from '../model/RecentBoardStore';
import { HttpClient } from '../model/HttpClient';
import { UrlBuilder } from '../model/UrlBuilder';
import { NgaJsonParser } from '../model/NgaJsonParser';
import { ThreadPageInfo } from '../model/ThreadPageInfo';
import { TopicListInfo } from '../model/TopicListInfo';
import {
  topicTitleOptions, topicSecondarySurfaceColor
} from '../components/TopicUiStyle';

const FLOATING_POST_BUTTON_WIDTH: number = 56;
const FLOATING_POST_BUTTON_INSET: number = 18;

@Entry
@Component
struct TopicListPage {
  @StorageLink(WINDOW_TOP_SAFE_AREA_PX_KEY) private topSafeAreaPx: number = 0;
  @StorageLink(NIGHT_MODE_STORAGE_KEY) nightMode: boolean = SettingDefaults.NIGHT;
  @State themeIndex: number = SettingDefaults.THEME;
  @State fid: number = 0;
  @State stid: number = 0;
  @State title: string = '';
  @State threadList: ThreadPageInfo[] = [];
  @State private showBoardRecommendations: boolean = false;
  @State currentPage: number = 1;
  @State isLoading: boolean = false;
  @State isRefreshing: boolean = false;
  @State isLoadingMore: boolean = false;
  @State hasMore: boolean = true;
  @State loadError: string = '';
  @State loadMoreError: string = '';
  @State refreshFeedback: string = '';
  @State pageStack: NavPathStack = new NavPathStack();
  @State private postButtonOnLeft: boolean = false;
  @State private postContentWidth: number = 0;
  @State private bottomSafeAreaInset: number = 0;

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private postGripObserver: PostGripObserver = new PostGripObserver();
  private publishAccountKey: string = '';
  private publishRevision: number = 0;
  private boardMounted: boolean = false;
  private boardWindow: window.Window | undefined = undefined;
  private observingBoardWindow: boolean = false;
  private onBottomAvoidAreaChanged: (options: window.AvoidAreaOptions) => void =
    (options: window.AvoidAreaOptions): void => {
      if (this.boardMounted && (options.type === window.AvoidAreaType.TYPE_SYSTEM ||
        options.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR)) {
        this.updateBottomSafeArea();
      }
    };

  aboutToAppear(): void {
    this.boardMounted = true;
    this.observeBottomSafeArea();
    SettingsStore.init(this.ctx);
    LoginStore.init(this.ctx);
    RecentBoardStore.init(this.ctx);
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);

    // 从路由参数获取板块信息
    const params: Record<string, Object> = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (params !== null && params !== undefined) {
      const fidVal: Object | undefined = params['fid'];
      if (typeof fidVal === 'number') {
        this.fid = fidVal;
      }
      const stidVal: Object | undefined = params['stid'];
      if (typeof stidVal === 'number') {
        this.stid = stidVal;
      }
      const titleVal: Object | undefined = params['title'];
      if (typeof titleVal === 'string') {
        this.title = titleVal;
      }
    }

    // 记录最近访问板块
    if (this.fid !== 0 || this.stid > 0) {
      RecentBoardStore.record(this.fid, this.stid, this.title);
    }

    this.publishAccountKey = LoginStore.getUser().uid;
    this.publishRevision = TopicPostStore.getRevision(this.publishAccountKey, this.fid, this.stid);
    this.loadTopicList(1);
  }

  onPageShow(): void {
    if (this.boardWindow !== undefined) {
      this.updateBottomSafeArea();
    } else {
      this.observeBottomSafeArea();
    }
    applyWindowTheme(this.ctx, this.nightMode);
    this.refreshPublishedTopics();
    this.postGripObserver.start((isLeft: boolean): void => this.updatePostButtonSide(isLeft));
  }

  onPageHide(): void {
    this.postGripObserver.stop();
  }

  aboutToDisappear(): void {
    this.boardMounted = false;
    if (this.boardWindow !== undefined) {
      this.boardWindow.off('avoidAreaChange', this.onBottomAvoidAreaChanged);
      this.boardWindow = undefined;
    }
    this.postGripObserver.stop();
  }

  private async observeBottomSafeArea(): Promise<void> {
    if (this.observingBoardWindow || this.boardWindow !== undefined || !this.boardMounted) {
      return;
    }
    this.observingBoardWindow = true;
    try {
      const boardWindow: window.Window = await window.getLastWindow(this.ctx);
      if (!this.boardMounted) {
        return;
      }
      this.boardWindow = boardWindow;
      boardWindow.on('avoidAreaChange', this.onBottomAvoidAreaChanged);
      this.updateBottomSafeArea();
    } catch (error) {
      // 底部背景始终延伸；控件避让读取失败时在页面再次显示时重试。
    } finally {
      this.observingBoardWindow = false;
    }
  }

  private updateBottomSafeArea(): void {
    if (this.boardWindow === undefined) {
      return;
    }
    try {
      const systemArea: window.AvoidArea = this.boardWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navigationArea: window.AvoidArea = this.boardWindow
        .getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.bottomSafeAreaInset = this.getUIContext()
        .px2vp(Math.max(systemArea.bottomRect.height, navigationArea.bottomRect.height));
    } catch (error) {
      // 窗口切换期间保留上次有效间距。
    }
  }

  private updatePostButtonSide(isLeft: boolean): void {
    if (this.postButtonOnLeft === isLeft) {
      return;
    }
    this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseInOut }, (): void => {
      this.postButtonOnLeft = isLeft;
    });
  }

  private postButtonTranslation(): number {
    return this.postButtonOnLeft ? 0 :
      Math.max(0, this.postContentWidth - FLOATING_POST_BUTTON_WIDTH - FLOATING_POST_BUTTON_INSET * 2);
  }

  private updatePostContentWidth(area: Area): void {
    let measuredWidth: number = 0;
    if (typeof area.width === 'number') {
      measuredWidth = area.width;
    } else if (typeof area.width === 'string') {
      measuredWidth = Number.parseFloat(area.width);
    }
    if (Number.isFinite(measuredWidth) && measuredWidth > 0) {
      this.postContentWidth = measuredWidth;
    }
  }

  /** 只在账号或发布版本变化时刷新；旧分页完成后也会检查，避免漏掉发布。 */
  private refreshPublishedTopics(): void {
    const accountKey: string = LoginStore.getUser().uid;
    const revision: number = TopicPostStore.getRevision(accountKey, this.fid, this.stid);
    if ((accountKey === this.publishAccountKey && revision === this.publishRevision) ||
      this.isLoading || this.isLoadingMore) {
      return;
    }
    this.publishAccountKey = accountKey;
    this.publishRevision = revision;
    this.loadTopicList(1);
  }

  private async goToPost(): Promise<void> {
    if (!Number.isSafeInteger(this.fid) || !Number.isSafeInteger(this.stid) || this.stid < 0 ||
      (this.fid === 0 && this.stid <= 0)) {
      this.getUIContext().getPromptAction().showToast({ message: '板块信息无效，请返回后重新进入' });
      return;
    }
    try {
      if (!LoginStore.hasUser()) {
        const decision = await this.getUIContext().getPromptAction().showDialog({
          title: '登录后发帖', message: '请先登录 NGA 账号，再在当前板块发表话题。',
          buttons: [
            { text: '稍后', color: this.subTextColor() },
            { text: '去登录', color: this.replyCountColor() }
          ]
        });
        if (decision.index === 1) {
          await this.getUIContext().getRouter().pushUrl({ url: 'pages/LoginPage' });
        }
        return;
      }
      await this.getUIContext().getRouter().pushUrl({
        url: 'pages/ReplyPage', params: { action: 'new', fid: this.fid, stid: this.stid, title: this.title }
      });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: '发帖页面打开失败，请重试' });
    }
  }

  /* ---------- 状态与工具方法 ---------- */

  private accentColor(): string {
    return COLOR_ACCENT_BLUE;
  }

  private pageBg(): string {
    return this.nightMode ? COLOR_NIGHT_BG : COLOR_DAY_BG;
  }

  private cardBg(): string {
    return this.nightMode ? COLOR_NIGHT_CARD : COLOR_DAY_CARD;
  }

  private mainTextColor(): string {
    return this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT;
  }

  private subTextColor(): string {
    return this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB;
  }

  private replyCountColor(): string {
    return themeAccentTextColor(this.nightMode);
  }

  private async loadTopicList(page: number): Promise<void> {
    if (this.isLoading || this.isLoadingMore) {
      return;
    }
    if (page === 1) {
      this.isLoading = true;
      this.loadError = '';
      this.refreshFeedback = '';
    } else {
      this.isLoadingMore = true;
    }
    this.loadMoreError = '';
    try {
      const url: string = UrlBuilder.buildTopicListUrl(this.fid, page, this.stid);
      // 在线列表始终重新请求，避免下拉刷新或发帖返回时复用系统 HTTP 缓存。
      const result = await HttpClient.get(url, undefined, false);
      const topicInfo: TopicListInfo = NgaJsonParser.parseTopicList(result.body);
      if (result.success && topicInfo.success) {
        const nextThreads: ThreadPageInfo[] = page === 1 ? [] : this.threadList.slice();
        let added: number = 0;
        for (const thread of topicInfo.threadPageList) {
          if (!nextThreads.some((existing: ThreadPageInfo): boolean => existing.tid === thread.tid)) {
            nextThreads.push(thread);
            added++;
          }
        }
        this.threadList = nextThreads;
        this.hasMore = added > 0;
        this.currentPage = page;
        this.loadError = '';
      } else {
        const message: string = result.body.length > 0 && topicInfo.error.length > 0 ?
          topicInfo.error : '加载失败，请检查网络后重试';
        this.reportListError(page, message);
      }
    } catch (err) {
      this.reportListError(page, '加载失败，请检查网络后重试');
    } finally {
      this.isLoading = false;
      this.isLoadingMore = false;
      this.isRefreshing = false;
      this.refreshPublishedTopics();
    }
  }

  private reportListError(page: number, message: string): void {
    if (page === 1) {
      if (this.threadList.length === 0) {
        this.loadError = message;
      } else {
        this.refreshFeedback = message;
      }
    } else {
      this.loadMoreError = message;
    }
  }

  private onRefresh(): void {
    if (this.isLoading || this.isLoadingMore) {
      return;
    }
    this.isRefreshing = true;
    this.loadTopicList(1);
  }

  private onLoadMore(): void {
    if (this.isLoadingMore || !this.hasMore || this.isLoading || this.loadMoreError.length > 0) {
      return;
    }
    this.loadTopicList(this.currentPage + 1);
  }

  private isBoardRecommendation(thread: ThreadPageInfo): boolean {
    // 原客户端按 recommend > 9 识别网事杂谈的特殊推荐；仅收纳首条，保留其他高推荐话题的位置。
    return this.fid === -7 && this.stid === 0 && thread.recommend > 9 &&
      this.threadList.length > 0 && this.threadList[0].tid === thread.tid;
  }

  private recommendedThreads(): ThreadPageInfo[] {
    return this.threadList.filter((thread: ThreadPageInfo): boolean => this.isBoardRecommendation(thread));
  }

  private latestThreads(): ThreadPageInfo[] {
    return this.threadList.filter((thread: ThreadPageInfo): boolean => !this.isBoardRecommendation(thread));
  }

  private onThreadClick(thread: ThreadPageInfo): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ArticleListPage',
      params: { tid: thread.tid, title: thread.subject, fid: this.fid }
    });
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

  /* ---------- 构建 ---------- */

  @Builder
  FloatingPostButton() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($r('sys.symbol.plus'))
        .fontSize(24)
        .fontColor(['#ffffffff'])
    }
      .width(FLOATING_POST_BUTTON_WIDTH)
      .height(56)
      .backgroundColor(this.accentColor())
      .shadow({ radius: 16, color: this.nightMode ? '#40000000' : '#261765c1', offsetY: 6 })
      .margin({ left: FLOATING_POST_BUTTON_INSET, bottom: 24 + this.bottomSafeAreaInset })
      .translate({ x: this.postButtonTranslation() })
      .opacity(this.postContentWidth > 0 ? 1 : 0)
      .zIndex(1)
      .id('board-floating-post-button')
      .accessibilityText('在' + (this.title.length > 0 ? this.title : '当前板块') + '发帖')
      .onClick(() => this.goToPost())
  }

  build() {
    Column() {
      Navigation(this.pageStack) {
      }
      .navDestination(this.TopicDestination)
      .hideTitleBar(true)
      .mode(NavigationMode.Stack)
      .width('100%')
      .height(LayoutPolicy.matchParent)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
      .backgroundColor(this.pageBg())
      .onAppear(() => {
        if (this.pageStack.size() === 0) {
          this.pageStack.pushPath({ name: 'TopicBoard' }, { animated: false });
        }
      })
    }
    .width('100%')
    .height(LayoutPolicy.matchParent)
    .padding({ top: this.getUIContext().px2vp(this.topSafeAreaPx) })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .backgroundColor(this.pageBg())
    // 路由首帧即铺满底部，发帖按钮与列表末项使用动态避让。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  TopicDestination(name: string) {
    if (name === 'TopicBoard') {
      NavDestination() {
        this.TopicContent()
      }
      // 背景和列表延伸到手势区，发帖按钮与页尾内容独立避让。
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
      .title(this.title, topicTitleOptions(this.nightMode))
      .hideBackButton(false)
      .backgroundColor(this.pageBg())
      .onShown(() => this.refreshPublishedTopics())
      .onBackPressed((): boolean => {
        this.getUIContext().getRouter().back();
        return true;
      })
    }
  }

  @Builder
  TopicContent() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column() {
        if (this.isLoading && this.threadList.length === 0) {
          Column() {
            LoadingProgress()
              .width(48)
              .height(48)
              .color(this.replyCountColor())
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.loadError.length > 0) {
          this.ErrorView()
        } else if (this.threadList.length === 0) {
          this.EmptyView()
        } else {
          this.TopicListView()
        }
      }
      .width('100%')
      .height('100%')
      this.FloatingPostButton()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
    .onAreaChange((_oldArea: Area, newArea: Area): void => this.updatePostContentWidth(newArea))
  }

  @Builder
  ErrorView() {
    Column() {
      Text(this.loadError)
        .fontSize(16)
        .fontColor(this.subTextColor())
        .margin({ bottom: 16 })

      Button('重试', { type: ButtonType.Capsule })
        .fontSize(16)
        .backgroundColor(this.accentColor())
        .fontColor('#ffffffff')
        .height(44)
        .padding({ left: 28, right: 28 })
        .enabled(!this.isLoading)
        .onClick(() => {
          this.loadTopicList(1);
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  EmptyView() {
    Column() {
      Text('该板块暂无话题')
        .fontSize(16)
        .fontColor(this.subTextColor())
        .margin({ bottom: 16 })
      Button('刷新', { type: ButtonType.Capsule })
        .fontSize(16)
        .backgroundColor(this.accentColor())
        .fontColor('#ffffffff')
        .height(44)
        .padding({ left: 28, right: 28 })
        .enabled(!this.isLoading)
        .onClick(() => {
          this.loadTopicList(1);
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  TopicListView() {
    Refresh({ refreshing: $$this.isRefreshing }) {
      List({ space: 8 }) {
        if (this.recommendedThreads().length > 0) {
          ListItem() {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 8 }) {
                Text('板块推荐').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.replyCountColor())
                Text(this.recommendedThreads().length.toString()).fontSize(12).fontColor(this.subTextColor())
                Blank()
                Text(this.showBoardRecommendations ? '收起' : '展开').fontSize(12)
                  .fontColor(this.replyCountColor())
              }
              .width('100%')
              .padding({ left: 16, right: 16 })
            }
            .width('100%')
            .height(44)
            .borderRadius(16)
            .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
            .id('board-recommendations-toggle')
            .accessibilityText('板块推荐，' + this.recommendedThreads().length.toString() + '个话题，' +
              (this.showBoardRecommendations ? '点击收起' : '点击展开'))
            .onClick((): void => {
              this.showBoardRecommendations = !this.showBoardRecommendations;
            })
          }
          if (this.showBoardRecommendations) {
            ForEach(this.recommendedThreads(), (recommendedThread: ThreadPageInfo) => {
              ListItem() {
                this.ThreadItem(recommendedThread)
              }
            }, (recommendedThread: ThreadPageInfo) => recommendedThread.tid.toString())
          }
        }
        ListItem() {
          Row() {
            Text('最新话题').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.subTextColor())
            Blank()
            Text(this.latestThreads().length.toString() + ' 个话题').fontSize(12).fontColor(this.subTextColor())
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
        }
        if (this.refreshFeedback.length > 0) {
          ListItem() {
            Column({ space: 8 }) {
              Text(this.refreshFeedback).fontSize(13).fontColor(this.subTextColor())
              Button('重新刷新').height(44).fontColor(this.replyCountColor())
                .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
                .enabled(!this.isLoading && !this.isLoadingMore)
                .onClick(() => this.onRefresh())
            }
            .width('100%').padding(16).borderRadius(20).backgroundColor(this.cardBg())
          }
        }
        ForEach(this.latestThreads(), (thread: ThreadPageInfo) => {
          ListItem() {
            this.ThreadItem(thread)
          }
        }, (thread: ThreadPageInfo) => thread.tid.toString())

        // 底部加载更多指示器
        if (this.isLoadingMore) {
          ListItem() {
            Row() {
              LoadingProgress()
                .width(24)
                .height(24)
                .color(this.replyCountColor())
              Text('加载中...')
                .fontSize(14)
                .fontColor(this.subTextColor())
                .margin({ left: 8 })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding(16)
          }
        }

        if (this.loadMoreError.length > 0) {
          ListItem() {
            Column({ space: 8 }) {
              Text(this.loadMoreError).fontSize(13).fontColor(this.subTextColor())
              Button('重试加载下一页').height(44).fontColor(this.replyCountColor())
                .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
                .enabled(!this.isLoading && !this.isLoadingMore)
                .onClick(() => this.loadTopicList(this.currentPage + 1))
            }
            .width('100%').padding(16)
          }
        }
        if (!this.hasMore && this.threadList.length > 0) {
          ListItem() {
            Text('没有更多了')
              .fontSize(14)
              .fontColor(this.subTextColor())
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding(16)
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .contentStartOffset(64)
      .contentEndOffset(104 + this.bottomSafeAreaInset)
      .padding({ left: 16, right: 16 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onReachEnd(() => {
        this.onLoadMore();
      })
    }
    .onRefreshing(() => {
      this.onRefresh();
    })
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  ThreadItem(thread: ThreadPageInfo) {
    Column({ space: 12 }) {
        Text(thread.subject)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .lineHeight(26)
          .fontColor(this.mainTextColor())
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)

        Row({ space: 8 }) {
          Text(thread.author)
            .fontSize(12)
            .lineHeight(18)
            .fontColor(this.subTextColor())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick(() => {
              this.goToUserProfile(thread.authorId);
            })

          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.message')).fontSize(14).fontColor([this.replyCountColor()])
            Text(thread.replies.toString()).fontSize(12).fontWeight(FontWeight.Medium)
              .fontColor(this.replyCountColor())
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(topicSecondarySurfaceColor(this.nightMode))
          .borderRadius(16)
          .accessibilityText(thread.replies.toString() + '条回复')
        }
        .width('100%')
      if (thread.lastPoster.length > 0) {
        Text('最新回复 · ' + thread.lastPoster).fontSize(12).fontColor(this.subTextColor())
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .backgroundColor(this.cardBg())
    .borderRadius(20)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onThreadClick(thread);
    })
  }
}

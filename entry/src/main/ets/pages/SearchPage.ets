/*
 * 搜索页面（SearchPage）。
 * 支持主题搜索和板块搜索两个 Tab。
 * 对应 Android SearchActivity + SearchHistoryTopicFragment + SearchHistoryBoardFragment。
 *
 * 主题搜索：GET thread.php?key={keyword}&page={page}&lite=js&noprefix（关键词 UTF-8 编码）
 * 板块搜索：GET forum.php?&__output=8&key={keyword}（关键词 GBK 编码）
 */

import { common } from '@kit.AbilityKit';
import { AppSubPage } from '../components/AppSubPage';
import {
  COLOR_ACCENT_BLUE,
  COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB,
  themeAccentTextColor, themeSecondarySurfaceColor, themeDividerColor
} from '../model/AppTheme';
import { SettingsStore, SettingKeys, SettingDefaults, NIGHT_MODE_STORAGE_KEY } from '../model/AppSettings';
import { LoginStore } from '../model/LoginStore';
import { HttpClient } from '../model/HttpClient';
import { UrlBuilder } from '../model/UrlBuilder';
import { NgaJsonParser } from '../model/NgaJsonParser';
import { GbkEncoder } from '../model/GbkEncoder';
import { ThreadPageInfo } from '../model/ThreadPageInfo';
import { TopicListInfo } from '../model/TopicListInfo';
import { BoardSearchResult } from '../model/SearchResult';

@Entry
@Component
struct SearchPage {
  @StorageLink(NIGHT_MODE_STORAGE_KEY) nightMode: boolean = SettingDefaults.NIGHT;
  @State private bottomSafeAreaInset: number = 0;
  @State themeIndex: number = SettingDefaults.THEME;
  @State currentTab: number = 0; // 0=主题搜索, 1=板块搜索
  @State keyword: string = '';
  @State searchContent: boolean = false; // 是否搜索内容
  @State topicResults: ThreadPageInfo[] = [];
  @State boardResults: BoardSearchResult[] = [];
  @State currentPage: number = 1;
  @State isLoading: boolean = false;
  @State hasMore: boolean = true;
  @State searchError: string = '';
  @State hasSearched: boolean = false;

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    SettingsStore.init(this.ctx);
    LoginStore.init(this.ctx);
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);
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

  private accentTextColor(): string {
    return themeAccentTextColor(this.nightMode);
  }

  /* ---------- 搜索逻辑 ---------- */

  private async searchTopic(page: number): Promise<void> {
    if (this.keyword.length === 0) {
      return;
    }
    if (page === 1) {
      this.isLoading = true;
      this.searchError = '';
      this.topicResults = [];
    }
    this.hasSearched = true;

    const url: string = UrlBuilder.buildTopicSearchUrl(this.keyword, page, 0, this.searchContent ? 1 : 0);
    const result = await HttpClient.get(url);

    this.isLoading = false;

    if (result.success) {
      const topicInfo: TopicListInfo = NgaJsonParser.parseTopicList(result.body);
      if (!topicInfo.success) {
        this.searchError = topicInfo.error;
        return;
      }
      if (page === 1) {
        this.topicResults = topicInfo.threadPageList;
      } else {
        for (const thread of topicInfo.threadPageList) {
          this.topicResults.push(thread);
        }
      }
      if (topicInfo.threadPageList.length === 0) {
        this.hasMore = false;
      }
      this.currentPage = page;
      this.searchError = '';
    } else {
      this.searchError = '搜索失败，请重试';
    }
  }

  private async searchBoard(): Promise<void> {
    if (this.keyword.length === 0) {
      return;
    }
    this.isLoading = true;
    this.searchError = '';
    this.boardResults = [];
    this.hasSearched = true;

    // 板块搜索关键词用 GBK 编码
    const baseUrl: string = UrlBuilder.buildBoardSearchBaseUrl();
    const url: string = baseUrl + GbkEncoder.encode(this.keyword);
    const result = await HttpClient.get(url);

    this.isLoading = false;

    if (result.success) {
      try {
        const root: Record<string, Object> = JSON.parse(result.body) as Record<string, Object>;
        const dataObj: Object | undefined = root['data'];
        if (dataObj !== undefined) {
          const dataRecord: Record<string, Object> = dataObj as Record<string, Object>;
          // data.0 是第一个匹配的板块
          const boardObj: Object | undefined = dataRecord['0'];
          if (boardObj !== undefined) {
            const boardRecord: Record<string, Object> = boardObj as Record<string, Object>;
            const board: BoardSearchResult = new BoardSearchResult();
            const fid: Object | undefined = boardRecord['fid'];
            if (typeof fid === 'number') {
              board.fid = fid;
            }
            const name: Object | undefined = boardRecord['name'];
            if (typeof name === 'string') {
              board.name = name;
            }
            this.boardResults.push(board);
          }
        }
      } catch (err) {
        this.searchError = '解析搜索结果失败';
      }
    } else {
      this.searchError = '搜索失败，请重试';
    }
  }

  private onSearch(): void {
    this.hasMore = true;
    this.currentPage = 1;
    if (this.currentTab === 0) {
      this.searchTopic(1);
    } else {
      this.searchBoard();
    }
  }

  private onLoadMore(): void {
    if (this.isLoading || !this.hasMore || this.currentTab !== 0) {
      return;
    }
    this.searchTopic(this.currentPage + 1);
  }

  private onTopicClick(thread: ThreadPageInfo): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ArticleListPage',
      params: { tid: thread.tid, title: thread.subject }
    });
  }

  private onBoardClick(board: BoardSearchResult): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/TopicListPage',
      params: { fid: board.fid, title: board.name }
    });
  }

  /* ---------- 构建 ---------- */

  build() {
    Column() {
      AppSubPage({ pageTitle: '搜索', nightMode: this.nightMode, pageBackground: this.pageBg(),
        onBottomInsetChanged: (inset: number): void => { this.bottomSafeAreaInset = inset; } }) {
        this.PageContent()
      }
    }
    .width('100%')
    .height(LayoutPolicy.matchParent)
    .backgroundColor(this.pageBg())
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  PageContent() {
    Column() {
      this.SearchInput()
      this.TabBar()

      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(this.accentTextColor())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.searchError.length > 0) {
        this.ErrorView()
      } else if (this.hasSearched && this.currentTab === 0 && this.topicResults.length === 0) {
        this.EmptyView('没有找到相关主题')
      } else if (this.hasSearched && this.currentTab === 1 && this.boardResults.length === 0) {
        this.EmptyView('没有找到相关板块')
      } else if (!this.hasSearched) {
        this.EmptyView('输入关键词开始搜索')
      } else {
        if (this.currentTab === 0) {
          this.TopicSearchResults()
        } else {
          this.BoardSearchResults()
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  SearchInput() {
    Row() {
      TextInput({ placeholder: '输入搜索关键词' })
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .placeholderColor(this.subTextColor())
        .caretColor(this.accentTextColor())
        .layoutWeight(1)
        .height(40)
        .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
        .borderRadius(20)
        .padding({ left: 16, right: 16 })
        .onChange((value: string) => {
          this.keyword = value;
        })
        .onSubmit(() => {
          this.onSearch();
        })

      Button('搜索')
        .fontSize(16)
        .backgroundColor(this.accentColor())
        .fontColor('#ffffffff')
        .height(40)
        .margin({ left: 8 })
        .onClick(() => {
          this.onSearch();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 8 })
    .backgroundColor(this.pageBg())

    // 主题搜索时显示"搜索内容"选项
    if (this.currentTab === 0) {
      Row() {
        Checkbox()
          .select(this.searchContent)
          .selectedColor(this.accentColor())
          .unselectedColor(this.subTextColor())
          .onChange((value: boolean) => {
            this.searchContent = value;
          })
          .width(20)
          .height(20)
          .margin({ right: 8 })

        Text('同时搜索帖子内容')
          .fontSize(14)
          .fontColor(this.subTextColor())
      }
      .width('100%')
      .padding({ left: 16, top: 4, bottom: 8 })
      .backgroundColor(this.pageBg())
    }
  }

  @Builder
  TabBar() {
    Row() {
      Text('主题')
        .fontSize(16)
        .fontColor(this.currentTab === 0 ? this.accentTextColor() : this.subTextColor())
        .backgroundColor(this.currentTab === 0 ? this.cardBg() : themeSecondarySurfaceColor(this.nightMode))
        .padding({ left: 24, right: 24, top: 8, bottom: 8 })
        .borderRadius({ topLeft: 4, topRight: 4 })
        .onClick(() => {
          this.currentTab = 0;
          this.hasSearched = false;
          this.topicResults = [];
          this.boardResults = [];
          this.searchError = '';
        })

      Text('板块')
        .fontSize(16)
        .fontColor(this.currentTab === 1 ? this.accentTextColor() : this.subTextColor())
        .backgroundColor(this.currentTab === 1 ? this.cardBg() : themeSecondarySurfaceColor(this.nightMode))
        .padding({ left: 24, right: 24, top: 8, bottom: 8 })
        .borderRadius({ topLeft: 4, topRight: 4 })
        .onClick(() => {
          this.currentTab = 1;
          this.hasSearched = false;
          this.topicResults = [];
          this.boardResults = [];
          this.searchError = '';
        })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 4, bottom: 4 })
    .backgroundColor(this.pageBg())
  }

  @Builder
  ErrorView() {
    Column() {
      Text(this.searchError)
        .fontSize(16)
        .fontColor(this.subTextColor())
        .margin({ bottom: 16 })

      Button('重试')
        .fontSize(16)
        .backgroundColor(this.accentColor())
        .fontColor('#ffffffff')
        .onClick(() => {
          this.onSearch();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  EmptyView(msg: string) {
    Column() {
      Text(msg)
        .fontSize(16)
        .fontColor(this.subTextColor())
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  TopicSearchResults() {
    List() {
      ForEach(this.topicResults, (thread: ThreadPageInfo) => {
        ListItem() {
          this.TopicItem(thread)
        }
      }, (thread: ThreadPageInfo) => thread.tid.toString())

      if (!this.hasMore && this.topicResults.length > 0) {
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
    .divider({ strokeWidth: 1, color: themeDividerColor(this.nightMode) })
    .contentEndOffset(12 + this.bottomSafeAreaInset)
    .onReachEnd(() => {
      this.onLoadMore();
    })
  }

  @Builder
  TopicItem(thread: ThreadPageInfo) {
    Column() {
      Text(thread.subject)
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row() {
        Text(thread.author)
          .fontSize(12)
          .fontColor(this.subTextColor())
          .layoutWeight(1)

        Text('回复:' + thread.replies.toString())
          .fontSize(12)
          .fontColor(this.subTextColor())
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(this.cardBg())
    .onClick(() => {
      this.onTopicClick(thread);
    })
  }

  @Builder
  BoardSearchResults() {
    List() {
      ForEach(this.boardResults, (board: BoardSearchResult) => {
        ListItem() {
          this.BoardItem(board)
        }
      }, (board: BoardSearchResult) => board.fid.toString())
    }
    .width('100%')
    .layoutWeight(1)
    .divider({ strokeWidth: 1, color: themeDividerColor(this.nightMode) })
    .contentEndOffset(12 + this.bottomSafeAreaInset)
  }

  @Builder
  BoardItem(board: BoardSearchResult) {
    Row() {
      Text(board.name)
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)

      Text('进入')
        .fontSize(14)
        .fontColor(this.accentTextColor())
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(this.cardBg())
    .onClick(() => {
      this.onBoardClick(board);
    })
  }
}

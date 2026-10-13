/*
 * 首页：收藏、板块、消息、我的四个主入口。
 */

import { common } from '@kit.AbilityKit';
import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { NotificationContent } from '../components/NotificationContent';
import {
  COLOR_ACCENT_BLUE,
  COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB, COLOR_DAY_ERROR,
  applyWindowTheme, themeAccentTextColor, themeSecondarySurfaceColor, themeErrorTextColor,
  WINDOW_TOP_SAFE_AREA_PX_KEY, themeMaterialSurfaceColor
} from '../model/AppTheme';
import { topicTitleOptions } from '../components/TopicUiStyle';
import { util } from '@kit.ArkTS';
import { SettingsStore, SettingKeys, SettingDefaults, NIGHT_MODE_STORAGE_KEY } from '../model/AppSettings';
import { LoginStore } from '../model/LoginStore';
import { UserManager } from '../model/UserManager';
import { FavoriteStore } from '../model/FavoriteStore';
import { RecentBoardStore } from '../model/RecentBoardStore';
import { Board } from '../model/Board';
import { UrlBuilder } from '../model/UrlBuilder';
import { BottomSafeAreaObserver } from '../model/BottomSafeAreaObserver';

/* 分类数据结构 */
interface CategoryItem {
  id: string;
  name: string;
  sub: SubCategoryItem[];
}

interface SubCategoryItem {
  name: string;
  content: BoardItem[];
}

interface BoardItem {
  fid: number;
  name: string;
  info?: string;
  nameS?: string;
  infoS?: string;
  stid?: number;
  head?: string;
}

const HOME_FLOATING_BAR_HEIGHT: number = 56;
const HOME_FLOATING_BAR_BOTTOM_MARGIN: number = 12;
// 胶囊和底距共同决定列表末项需要的滚动留白，系统避让区另行动态累加。
const HOME_FLOATING_CONTENT_INSET: number = HOME_FLOATING_BAR_HEIGHT + HOME_FLOATING_BAR_BOTTOM_MARGIN + 24;

// 点分 API 版本需要 apiAvailable 判断；较早系统保留原生底栏。
function supportsFloatingBottomBar(): boolean {
  if (deviceInfo.sdkApiVersion >= 26) {
    if (deviceInfo.apiAvailable('26.0.0')) {
      return true;
    }
  }
  return false;
}

class HomeBottomBarModifier implements AttributeModifier<TabsAttribute> {
  private nightMode: boolean;
  private bottomSafeAreaInset: number;

  constructor(nightMode: boolean, bottomSafeAreaInset: number) {
    this.nightMode = nightMode;
    this.bottomSafeAreaInset = bottomSafeAreaInset;
  }

  applyNormalAttribute(tabs: TabsAttribute): void {
    const background: string = this.nightMode ? COLOR_NIGHT_BG : COLOR_DAY_BG;
    tabs.barOverlap(true);
    // 材质只作用于胶囊本体，小白条与底部间隙直接显示当前页内容。
    tabs.barBackgroundColor(Color.Transparent);
    tabs.safeAreaPadding({ bottom: 0 });
    if (deviceInfo.sdkApiVersion >= 26) {
      if (deviceInfo.apiAvailable('26.0.0')) {
        let material: uiMaterial.ImmersiveMaterial | undefined = undefined;
        try {
          if (uiMaterial.isImmersiveMaterialSupported()) {
            material = new uiMaterial.ImmersiveMaterial({
              style: uiMaterial.ImmersiveStyle.THIN,
              materialColor: themeMaterialSurfaceColor(this.nightMode, 0.6),
              colorInvert: false,
              applyShadow: true,
              interactive: true,
              lightEffect: { color: Color.White }
            });
          }
        } catch (error) {
          // 材质能力读取失败时保留可读的悬浮胶囊。
        }
        tabs.barFloatingStyle({
          // 用原生尺寸档位控制长度，窄窗口仍按左右边距收缩。
          barWidth: { smallBarWidth: 320, mediumBarWidth: 360, largeBarWidth: 400 },
          barSideMargin: 28,
          barBottomMargin: HOME_FLOATING_BAR_BOTTOM_MARGIN + this.bottomSafeAreaInset,
          maskHeight: 0,
          maskColor: Color.Transparent,
          systemMaterial: material !== undefined ? material : uiMaterial.Material.empty
        });
        if (material === undefined) {
          tabs.barBackgroundColor(background);
          tabs.barBackgroundBlurStyle(BlurStyle.NONE);
        }
        return;
      }
    }
    tabs.barBackgroundBlurStyle(BlurStyle.NONE);
  }
}

/* 添加板块对话框 */
@CustomDialog
struct AddBoardDialogView {
  controller: CustomDialogController;
  @State addBoardName: string = '';
  @State addBoardFid: string = '';
  @State addBoardStid: string = '';
  @StorageLink(NIGHT_MODE_STORAGE_KEY) nightMode: boolean = false;
  @Prop themeIndex: number = SettingDefaults.THEME;
  onConfirm: (name: string, fid: string, stid: string) => void = () => {};

  build() {
    Column() {
      Text('添加板块到收藏')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT)
        .margin({ bottom: 20 })

      Column() {
        Text('板块名称')
          .fontSize(14)
          .fontColor(this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB)
          .margin({ bottom: 4 })

        TextInput({ placeholder: '输入板块名称', text: this.addBoardName })
          .fontSize(16)
          .fontColor(this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT)
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
          .placeholderColor(this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB)
          .caretColor(themeAccentTextColor(this.nightMode))
          .width('100%')
          .borderRadius(12)
          .onChange((value: string) => {
            this.addBoardName = value;
          })
      }
      .width('100%')
      .margin({ bottom: 16 })

      Column() {
        Text('板块ID (fid)')
          .fontSize(14)
          .fontColor(this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB)
          .margin({ bottom: 4 })

        TextInput({ placeholder: '输入板块ID', text: this.addBoardFid })
          .fontSize(16)
          .fontColor(this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT)
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
          .placeholderColor(this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB)
          .caretColor(themeAccentTextColor(this.nightMode))
          .width('100%')
          .borderRadius(12)
          .onChange((value: string) => {
            this.addBoardFid = value;
          })
      }
      .width('100%')
      .margin({ bottom: 16 })

      Column() {
        Text('子板块ID (stid，可选)')
          .fontSize(14)
          .fontColor(this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB)
          .margin({ bottom: 4 })

        TextInput({ placeholder: '输入子板块ID（可选）', text: this.addBoardStid })
          .fontSize(16)
          .fontColor(this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT)
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
          .placeholderColor(this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB)
          .caretColor(themeAccentTextColor(this.nightMode))
          .width('100%')
          .borderRadius(12)
          .type(InputType.Number)
          .onChange((value: string) => {
            this.addBoardStid = value;
          })
      }
      .width('100%')
      .margin({ bottom: 24 })

      Row() {
        Button('取消')
          .fontSize(16)
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
          .fontColor(this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT)
          .layoutWeight(1)
          .margin({ right: 12 })
          .borderRadius(12)
          .onClick(() => {
            this.controller.close();
          })

        Button('添加')
          .fontSize(16)
          .backgroundColor(COLOR_ACCENT_BLUE)
          .fontColor(Color.White)
          .layoutWeight(1)
          .borderRadius(12)
          .onClick(() => {
            this.onConfirm(this.addBoardName, this.addBoardFid, this.addBoardStid);
            this.controller.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(24)
    .backgroundColor(this.nightMode ? COLOR_NIGHT_CARD : COLOR_DAY_CARD)
    .borderRadius(16)
  }
}

/* 清空收藏确认对话框 */
@CustomDialog
struct ClearFavoriteDialogView {
  controller: CustomDialogController;
  @StorageLink(NIGHT_MODE_STORAGE_KEY) nightMode: boolean = false;
  onConfirm: () => void = () => {};

  build() {
    Column() {
      Text('确认清空收藏？')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT)
        .margin({ bottom: 8 })

      Text('将删除所有已收藏的板块，此操作不可撤销。')
        .fontSize(14)
        .fontColor(this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB)
        .margin({ bottom: 24 })

      Row() {
        Button('取消')
          .fontSize(16)
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
          .fontColor(this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT)
          .layoutWeight(1)
          .margin({ right: 12 })
          .borderRadius(12)
          .onClick(() => {
            this.controller.close();
          })

        Button('清空')
          .fontSize(16)
          .backgroundColor(COLOR_DAY_ERROR)
          .fontColor(Color.White)
          .layoutWeight(1)
          .borderRadius(12)
          .onClick(() => {
            this.onConfirm();
            this.controller.close();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(24)
    .backgroundColor(this.nightMode ? COLOR_NIGHT_CARD : COLOR_DAY_CARD)
    .borderRadius(16)
  }
}

@Entry
@Component
struct Index {
  @StorageLink(WINDOW_TOP_SAFE_AREA_PX_KEY) private topSafeAreaPx: number = 0;
  @StorageLink(NIGHT_MODE_STORAGE_KEY) nightMode: boolean = SettingDefaults.NIGHT;
  @State themeIndex: number = SettingDefaults.THEME;
  @State categories: CategoryItem[] = [];
  @State currentMainTab: number = 0;
  @State homeVisible: boolean = true;
  @State bottomSafeAreaInset: number = 0;
  @State bottomSafeAreaReady: boolean = false;
  @State currentCategoryIndex: number = 0;
  @State boardKeyword: string = '';
  @State loggedIn: boolean = false;
  @State currentUserName: string = '';
  @State currentAccountKey: string = '';
  @State accountCount: number = 0;

  @State favorites: Board[] = [];
  @State managingFavorites: boolean = false;
  @State recentBoards: Board[] = [];
  @State loadError: string = '';
  @State feedbackMsg: string = '';

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private favoriteScroller: Scroller = new Scroller();
  private searchScroller: Scroller = new Scroller();
  private myScroller: Scroller = new Scroller();
  private categoryScrollers: Scroller[] = [];
  private floatingBottomBar: boolean = supportsFloatingBottomBar();
  private bottomSafeAreaObserver: BottomSafeAreaObserver = new BottomSafeAreaObserver();
  private addBoardDialogController: CustomDialogController = new CustomDialogController({
    builder: AddBoardDialogView({
      themeIndex: this.themeIndex,
      onConfirm: (name: string, fid: string, stid: string) => {
        this.handleAddBoard(name, fid, stid);
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
  });
  private clearFavoriteDialogController: CustomDialogController = new CustomDialogController({
    builder: ClearFavoriteDialogView({
      onConfirm: () => {
        this.confirmClearFavorites();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
  });

  aboutToAppear(): void {
    this.observeBottomSafeArea();
    SettingsStore.init(this.ctx);
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);
    this.currentCategoryIndex = SettingsStore.getInt('home_board_category', 0);
    LoginStore.init(this.ctx);
    this.refreshAccount();
    FavoriteStore.init(this.ctx);
    RecentBoardStore.init(this.ctx);
    this.loadCategoryData();
    this.loadFavorites();
    this.loadRecentBoards();
  }

  aboutToDisappear(): void {
    this.bottomSafeAreaObserver.stop();
  }

  private observeBottomSafeArea(): void {
    this.bottomSafeAreaObserver.start(this.getUIContext(), (inset: number): void => {
      this.bottomSafeAreaInset = inset;
      this.bottomSafeAreaReady = true;
    });
  }

  onPageShow(): void {
    this.homeVisible = true;
    this.bottomSafeAreaObserver.refresh();
    if (!this.bottomSafeAreaReady) {
      this.observeBottomSafeArea();
    }
    this.loadFavorites();
    this.loadRecentBoards();
    this.refreshAccount();
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);
    applyWindowTheme(this.ctx, this.nightMode);
  }

  onPageHide(): void {
    this.homeVisible = false;
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

  private bottomContentInset(): number {
    return (this.floatingBottomBar ? HOME_FLOATING_CONTENT_INSET : 76) + this.bottomSafeAreaInset;
  }

  private accentTextColor(): string {
    return themeAccentTextColor(this.nightMode);
  }


  private loadFavorites(): void {
    this.favorites = FavoriteStore.getList();
    if (this.favorites.length === 0) {
      this.managingFavorites = false;
    }
  }

  private favoritePosition(board: Board): number {
    return this.favorites.findIndex((saved: Board): boolean => saved.fid === board.fid && saved.stid === board.stid);
  }

  private toggleFavoriteManagement(): void {
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
      this.managingFavorites = !this.managingFavorites;
    });
  }

  private loadRecentBoards(): void {
    this.recentBoards = RecentBoardStore.getList();
  }

  private loadCategoryData(): void {
    try {
      const rawBytes: Uint8Array = this.ctx.resourceManager.getRawFileContentSync('category.json');
      const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      const raw: string = textDecoder.decode(rawBytes);
      const parsed: object[] = JSON.parse(raw) as object[];
      const result: CategoryItem[] = [];
      for (const cat of parsed) {
        const catRecord: Record<string, Object> = cat as Record<string, Object>;
        const item: CategoryItem = { id: '', name: '', sub: [] };

        const id: Object | undefined = catRecord['id'];
        if (typeof id === 'string') {
          item.id = id;
        }

        const name: Object | undefined = catRecord['name'];
        if (typeof name === 'string') {
          item.name = name;
        }

        const subData: Object | undefined = catRecord['sub'];
        if (subData !== undefined) {
          const subArray: object[] = subData as object[];
          for (const sub of subArray) {
            const subRecord: Record<string, Object> = sub as Record<string, Object>;
            const subItem: SubCategoryItem = { name: '', content: [] };

            const subName: Object | undefined = subRecord['name'];
            if (typeof subName === 'string') {
              subItem.name = subName;
            }

            const contentData: Object | undefined = subRecord['content'];
            if (contentData !== undefined) {
              const contentArray: object[] = contentData as object[];
              const seenBoards: Set<string> = new Set<string>();
              for (const board of contentArray) {
                const boardRecord: Record<string, Object> = board as Record<string, Object>;
                const boardItem: BoardItem = { fid: 0, name: '' };

                const fid: Object | undefined = boardRecord['fid'];
                if (typeof fid === 'number') {
                  boardItem.fid = fid;
                }

                const boardName: Object | undefined = boardRecord['name'];
                if (typeof boardName === 'string') {
                  boardItem.name = boardName;
                }

                const info: Object | undefined = boardRecord['info'];
                if (typeof info === 'string') {
                  boardItem.info = info;
                }

                const nameS: Object | undefined = boardRecord['nameS'];
                if (typeof nameS === 'string') {
                  boardItem.nameS = nameS;
                }

                const infoS: Object | undefined = boardRecord['infoS'];
                if (typeof infoS === 'string') {
                  boardItem.infoS = infoS;
                }

                const stid: Object | undefined = boardRecord['stid'];
                if (typeof stid === 'number') {
                  boardItem.stid = stid;
                }

                const head: Object | undefined = boardRecord['head'];
                if (typeof head === 'string') {
                  boardItem.head = head;
                }

                const boardKey: string = boardItem.fid.toString() + '_' +
                  (boardItem.stid !== undefined ? boardItem.stid : 0).toString() + '_' + boardItem.name;
                if (!seenBoards.has(boardKey)) {
                  seenBoards.add(boardKey);
                  subItem.content.push(boardItem);
                }
              }
            }

            item.sub.push(subItem);
          }
        }

        result.push(item);
      }
      this.categories = result;
      this.categoryScrollers = result.map(() => new Scroller());
      if (this.currentCategoryIndex < 0 || this.currentCategoryIndex >= result.length) {
        this.currentCategoryIndex = 0;
      }
      this.loadError = '';
    } catch (err) {
      this.loadError = '板块数据加载失败';
    }
  }

  private showFeedback(msg: string): void {
    this.feedbackMsg = msg;
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (err) {
    }
    setTimeout(() => {
      this.feedbackMsg = '';
    }, 2000);
  }

  private getBoardIconUrl(board: Board): string {
    if (board.stid > 0) {
      return UrlBuilder.buildSubBoardIconUrl(board.stid);
    }
    return UrlBuilder.buildBoardIconUrl(board.fid);
  }

  private getBoardItemIconUrl(board: BoardItem): string {
    const stid: number = board.stid !== undefined ? board.stid : 0;
    if (stid > 0) {
      return UrlBuilder.buildSubBoardIconUrl(stid);
    }
    return UrlBuilder.buildBoardIconUrl(board.fid);
  }

  private onBoardClick(board: BoardItem): void {
    const fid: number = board.fid;
    const stid: number = board.stid !== undefined ? board.stid : 0;
    const title: string = board.name;
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/TopicListPage',
      params: { fid: fid, stid: stid, title: title }
    });
  }

  private onFavoriteBoardClick(board: Board): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/TopicListPage',
      params: { fid: board.fid, stid: board.stid, title: board.name }
    });
  }

  private addFavorite(board: BoardItem): void {
    const b: Board = new Board(board.fid, board.stid !== undefined ? board.stid : 0, board.name);
    if (this.isFavorite(board.fid, b.stid)) {
      return;
    }
    FavoriteStore.add(b);
    this.loadFavorites();
    this.showFeedback('已收藏');
  }

  private removeFavorite(fid: number, stid: number): void {
    FavoriteStore.remove(fid, stid);
    this.loadFavorites();
    this.showFeedback('已取消收藏');
  }

  private handleAddBoard(name: string, fid: string, stid: string): void {
    const fidNum: number = Number(fid.trim());
    const stidNum: number = stid.trim().length === 0 ? 0 : Number(stid.trim());
    if (!Number.isInteger(fidNum) || !Number.isInteger(stidNum) || stidNum < 0 ||
      (fidNum === 0 && stidNum === 0)) {
      this.showFeedback('请输入有效的板块ID');
      return;
    }
    if (name.trim().length === 0) {
      this.showFeedback('请输入板块名称');
      return;
    }
    const success: boolean = FavoriteStore.addByFidStid(fidNum, stidNum, name.trim());
    if (success) {
      this.showFeedback('添加成功');
      this.loadFavorites();
    } else {
      this.showFeedback('该板块已收藏');
    }
  }

  private confirmClearFavorites(): void {
    FavoriteStore.clearAll();
    this.loadFavorites();
    this.showFeedback('已清空收藏');
  }

  private moveFavoriteUp(index: number): void {
    if (index <= 0 || index >= this.favorites.length) {
      return;
    }
    FavoriteStore.moveUp(index);
    this.loadFavorites();
  }

  private moveFavoriteDown(index: number): void {
    if (index < 0 || index >= this.favorites.length - 1) {
      return;
    }
    FavoriteStore.moveDown(index);
    this.loadFavorites();
  }

  private isFavorite(fid: number, stid: number): boolean {
    for (const item of this.favorites) {
      if (item.fid === fid && item.stid === stid) {
        return true;
      }
    }
    return false;
  }

  private gotoPage(url: string): void {

    this.getUIContext().getRouter().pushUrl({ url: url });
  }


  private refreshAccount(): void {
    const user = LoginStore.getUser();
    this.loggedIn = LoginStore.hasUser();
    this.currentUserName = user.userName.length > 0 ? user.userName : 'NGA用户';
    this.currentAccountKey = user.uid;
    this.accountCount = UserManager.getUserSize();
  }

  private mainTitle(): string {
    return ['收藏', '板块', '消息', '我的'][this.currentMainTab];
  }

  private matchingBoards(): BoardItem[] {
    const keyword: string = this.boardKeyword.trim().toLowerCase();
    if (keyword.length === 0) {
      return [];
    }
    const result: BoardItem[] = [];
    const seen: Set<string> = new Set<string>();
    for (const category of this.categories) {
      for (const sub of category.sub) {
        for (const board of sub.content) {
          const text: string = board.name + ' ' + (board.nameS !== undefined ? board.nameS : '') +
            ' ' + (board.info !== undefined ? board.info : '');
          const key: string = board.fid.toString() + '_' +
            (board.stid !== undefined ? board.stid : 0).toString();
          if (text.toLowerCase().includes(keyword) && !seen.has(key)) {
            seen.add(key);
            result.push(board);
          }
        }
      }
    }
    return result;
  }

  private toggleFavorite(board: BoardItem): void {
    const stid: number = board.stid !== undefined ? board.stid : 0;
    if (this.isFavorite(board.fid, stid)) {
      this.removeFavorite(board.fid, stid);
    } else {
      this.addFavorite(board);
    }
  }

  @Builder
  MainNavigationTitle() {
    Row() {
      Text(this.mainTitle())
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.mainTextColor())
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  /* ---------- 四个主页面，原生底部页签保留各自状态 ---------- */

  build() {
    Column() {
      Navigation() {
        Tabs({ index: this.currentMainTab }) {
          TabContent() {
            this.FavoritesContent()
          }
          .tabBar(new BottomTabBarStyle($r('app.media.ic_nav_favorite'), '收藏')
            .padding({ bottom: this.floatingBottomBar ? 0 : this.bottomSafeAreaInset })
            .iconStyle({ selectedColor: this.accentTextColor(), unselectedColor: this.subTextColor() })
            .labelStyle({ selectedColor: this.accentTextColor(), unselectedColor: this.subTextColor() }))

          TabContent() {
            this.BoardsContent()
          }
          .tabBar(new BottomTabBarStyle($r('app.media.ic_nav_boards'), '板块')
            .padding({ bottom: this.floatingBottomBar ? 0 : this.bottomSafeAreaInset })
            .iconStyle({ selectedColor: this.accentTextColor(), unselectedColor: this.subTextColor() })
            .labelStyle({ selectedColor: this.accentTextColor(), unselectedColor: this.subTextColor() }))

          TabContent() {
            NotificationContent({
              nightMode: this.nightMode,
              themeIndex: this.themeIndex,
              showTitleBar: false,
              contentBottomInset: this.bottomContentInset(),
              active: this.homeVisible && this.currentMainTab === 2,
              accountKey: this.currentAccountKey
            })
          }
          .tabBar(new BottomTabBarStyle($r('app.media.ic_nav_message'), '消息')
            .padding({ bottom: this.floatingBottomBar ? 0 : this.bottomSafeAreaInset })
            .iconStyle({ selectedColor: this.accentTextColor(), unselectedColor: this.subTextColor() })
            .labelStyle({ selectedColor: this.accentTextColor(), unselectedColor: this.subTextColor() }))

          TabContent() {
            this.MyContent()
          }
          .tabBar(new BottomTabBarStyle($r('app.media.ic_person'), '我的')
            .padding({ bottom: this.floatingBottomBar ? 0 : this.bottomSafeAreaInset })
            .iconStyle({ selectedColor: this.accentTextColor(), unselectedColor: this.subTextColor() })
            .labelStyle({ selectedColor: this.accentTextColor(), unselectedColor: this.subTextColor() }))
        }
        .width('100%')
        .height(LayoutPolicy.matchParent)
        .barPosition(BarPosition.End)
        .barMode(BarMode.Fixed)
        .barHeight(this.floatingBottomBar ? HOME_FLOATING_BAR_HEIGHT : 64 + this.bottomSafeAreaInset)
        .attributeModifier(new HomeBottomBarModifier(this.nightMode, this.bottomSafeAreaInset))
        // 内容已铺满底部，底栏不再扩展自身背景绘制。
        .expandSafeArea([], [])
        .backgroundColor(this.pageBg())
        .scrollable(false)
        .animationDuration(180)
        .onChange((index: number) => {
          this.currentMainTab = index;
          this.loadFavorites();
          this.loadRecentBoards();
          this.refreshAccount();
        })
      }
      .width('100%')
      .height(LayoutPolicy.matchParent)
      .mode(NavigationMode.Stack)
      .hideBackButton(true)
      .titleMode(NavigationTitleMode.Mini)
      .title(this.MainNavigationTitle(), topicTitleOptions(this.nightMode, BarStyle.STANDARD))
      .hideToolBar(true)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
      .backgroundColor(this.pageBg())
    }
    .width('100%')
    .height(LayoutPolicy.matchParent)
    .padding({ top: this.getUIContext().px2vp(this.topSafeAreaPx) })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .backgroundColor(this.pageBg())
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /* ---------- 板块：本地搜索与纵向分类 ---------- */

  @Builder
  BoardsContent() {
    Column() {
      Row({ space: 8 }) {
        Search({ value: this.boardKeyword, placeholder: '搜索板块' })
          .layoutWeight(1)
          .height(40)
          .fontColor(this.mainTextColor())
          .placeholderColor(this.subTextColor())
          .caretStyle({ color: this.accentTextColor() })
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
          .onChange((value: string) => {
            this.boardKeyword = value;
          })
        Button('帖子搜索')
          .fontSize(13)
          .height(40)
          .backgroundColor(this.accentColor())
          .fontColor(Color.White)
          .onClick(() => this.gotoPage('pages/SearchPage'))
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })

      if (this.loadError.length > 0) {
        Column({ space: 12 }) {
          Text(this.loadError).fontColor(this.subTextColor())
          Button('重新加载').fontColor(Color.White).backgroundColor(this.accentColor())
            .onClick(() => this.loadCategoryData())
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Stack() {
          Row() {
            List() {
              ForEach(this.categories, (category: CategoryItem, index: number) => {
                ListItem() {
                  Button({ type: ButtonType.Normal }) {
                    Text(category.name)
                      .fontSize(14)
                      .fontWeight(index === this.currentCategoryIndex ? FontWeight.Medium : FontWeight.Normal)
                      .fontColor(index === this.currentCategoryIndex ? this.accentTextColor() : this.subTextColor())
                      .maxLines(2)
                      .textAlign(TextAlign.Center)
                  }
                  .width('100%')
                  .height(64)
                  .borderRadius(0)
                  .padding({ left: 8, right: 8 })
                  .border({ width: { left: index === this.currentCategoryIndex ? 3 : 0 }, color: this.accentTextColor() })
                  .backgroundColor(index === this.currentCategoryIndex ?
                    themeSecondarySurfaceColor(this.nightMode) : Color.Transparent)
                  .accessibilityText(category.name)
                  .onClick(() => {
                    this.currentCategoryIndex = index;
                    SettingsStore.setInt('home_board_category', index);
                  })
                }
              }, (category: CategoryItem) => category.id)
            }
            .width(92)
            .height('100%')
            .scrollBar(BarState.Off)
            .contentEndOffset(this.bottomContentInset())
            .backgroundColor(this.cardBg())

            Stack({ alignContent: Alignment.TopStart }) {
              ForEach(this.categories, (category: CategoryItem, index: number) => {
                Column() {
                  this.CategoryTabContent(category, index)
                }
                .width('100%')
                .height('100%')
                .visibility(index === this.currentCategoryIndex ? Visibility.Visible : Visibility.None)
              }, (category: CategoryItem) => category.id)
            }
            .layoutWeight(1)
            .height('100%')
          }
          .width('100%')
          .height('100%')
          .alignItems(VerticalAlign.Top)
          .visibility(this.boardKeyword.trim().length === 0 ? Visibility.Visible : Visibility.None)

          Scroll(this.searchScroller) {
            Column() {
              if (this.matchingBoards().length === 0) {
                this.EmptyHint('没有找到相关板块', '试试板块名称或简称')
              } else {
                this.SectionHeader('搜索结果 · ' + this.matchingBoards().length.toString())
                Grid() {
                  ForEach(this.matchingBoards(), (board: BoardItem) => {
                    GridItem() {
                      this.BoardItemCard(board)
                    }
                  }, (board: BoardItem) => board.fid.toString() + '_' +
                    (board.stid !== undefined ? board.stid : 0).toString() + '_' + board.name)
                }
                .columnsTemplate('1fr 1fr')
                .rowsGap(12)
                .columnsGap(12)
                .padding({ left: 12, right: 12, bottom: 12 })
                .width('100%')
              }
            }
            .width('100%')
            .padding({ bottom: this.bottomContentInset() })
          }
          .width('100%')
          .height('100%')
          .align(Alignment.TopStart)
          .scrollBar(BarState.Off)
          .visibility(this.boardKeyword.trim().length > 0 ? Visibility.Visible : Visibility.None)
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  /* ---------- 收藏与最近访问 ---------- */

  @Builder
  FavoritesContent() {
    Scroll(this.favoriteScroller) {
      Column() {
        // 收藏板块区块
        Row({ space: 8 }) {
          Text('收藏板块').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.mainTextColor())
          Text(this.favorites.length.toString()).fontSize(12).fontColor(this.subTextColor())
          Blank()
          if (this.favorites.length > 0) {
            Button(this.managingFavorites ? '完成' : '管理', { type: ButtonType.Capsule })
              .height(44).fontSize(14).fontColor(themeAccentTextColor(this.nightMode))
              .backgroundColor(Color.Transparent)
              .onClick(() => this.toggleFavoriteManagement())
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 4 })

        // 收藏操作栏
        Row() {
          Button('添加板块', { type: ButtonType.Capsule })
            .fontSize(14)
            .backgroundColor(this.accentColor())
            .fontColor(Color.White)
            .height(44)
            .onClick(() => {
              this.addBoardDialogController.open();
            })

          if (this.managingFavorites && this.favorites.length > 0) {
            Button('清空收藏', { type: ButtonType.Capsule })
              .fontSize(14)
              .backgroundColor(this.cardBg())
              .fontColor(themeErrorTextColor(this.nightMode))
              .height(44)
              .margin({ left: 12 })
              .onClick(() => {
                this.clearFavoriteDialogController.open();
              })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 8 })
        .justifyContent(FlexAlign.Start)

        if (this.favorites.length === 0) {
          this.EmptyHint('还没有收藏的板块', '点击“添加板块”，或到“板块”页收藏')
          Button('浏览板块')
            .fontSize(14)
            .height(44)
            .backgroundColor(this.accentColor())
            .fontColor(Color.White)
            .margin({ bottom: 16 })
            .onClick(() => { this.currentMainTab = 1; })
        } else {
          Column({ space: 8 }) {
            ForEach(this.favorites, (board: Board) => {
              this.FavoriteBoardItem(board)
            }, (board: Board) => (board.fid.toString() + '_' + board.stid.toString()))
          }
          .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        }

        // 最近访问区块
        this.SectionHeader('最近访问')
        if (this.recentBoards.length === 0) {
          this.EmptyHint('暂无最近访问的板块', '浏览任意板块后会显示在这里')
        } else {
          Column({ space: 8 }) {
            ForEach(this.recentBoards, (board: Board) => {
              this.RecentBoardItem(board)
            }, (board: Board) => (board.fid.toString() + '_' + board.stid.toString()))
          }
          .width('100%').padding({ left: 16, right: 16, bottom: 8 })
        }

      }
      .width('100%')
      .padding({ bottom: this.bottomContentInset() })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
  }

  /* ---------- 区块标题 ---------- */

  @Builder
  SectionHeader(title: string) {
    Text(title)
      .fontSize(14)
      .fontColor(this.subTextColor())
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: 16, top: 16, bottom: 8 })
  }

  /* ---------- 空状态提示 ---------- */

  @Builder
  EmptyHint(line1: string, line2: string) {
    Column() {
      Text(line1)
        .fontSize(16)
        .fontColor(this.subTextColor())
        .textAlign(TextAlign.Center)
        .margin({ bottom: 8 })

      Text(line2)
        .fontSize(14)
        .fontColor(this.subTextColor())
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 24, bottom: 24 })
    .alignItems(HorizontalAlign.Center)
  }

  /* ---------- 最近访问板块列表项 ---------- */

  @Builder
  RecentBoardItem(board: Board) {
    Row() {
      Image(this.getBoardIconUrl(board))
        .width(40)
        .height(40)
        .objectFit(ImageFit.Contain)
        .alt($r('app.media.default_board_icon'))
        .margin({ right: 12 })

      Text(board.name)
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Image($r('app.media.ic_home_chevron_right'))
        .width(20)
        .height(20)
        .fillColor(this.subTextColor())
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(this.cardBg())
    .borderRadius(20)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onFavoriteBoardClick(board);
    })
  }

  /* ---------- 分类 Tab 内容 ---------- */

  @Builder
  CategoryTabContent(category: CategoryItem, index: number) {
    Scroll(this.categoryScrollers[index]) {
      Column() {
        ForEach(category.sub, (sub: SubCategoryItem) => {
          // 子分类标题
          Text(sub.name)
            .fontSize(14)
            .fontColor(this.subTextColor())
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .padding({ left: 16, top: 16, bottom: 8 })

          // 板块 Grid
          Grid() {
            ForEach(sub.content, (board: BoardItem) => {
              GridItem() {
                this.BoardItemCard(board)
              }
            }, (board: BoardItem) => board.fid.toString() + '_' +
              (board.stid !== undefined ? board.stid : 0).toString() + '_' + board.name)
          }
          .columnsTemplate('1fr 1fr')
          .rowsGap(12)
          .columnsGap(12)
          .padding({ left: 16, right: 16, bottom: 8 })
          .width('100%')
        }, (sub: SubCategoryItem) => sub.name)
      }
      .width('100%')
      .padding({ bottom: this.bottomContentInset() })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
  }

  /* ---------- 板块卡片（带收藏按钮） ---------- */


  @Builder
  BoardItemCard(board: BoardItem) {
    Column() {
      Column() {
        Image(this.getBoardItemIconUrl(board))
          .width(48)
          .height(48)
          .objectFit(ImageFit.Contain)
          .alt($r('app.media.default_board_icon'))
        Text(board.name)
          .fontSize(13)
          .fontColor(this.mainTextColor())
          .maxLines(2)
          .height(36)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
      }
      .width('100%')
      .onClick(() => this.onBoardClick(board))

      Button({ type: ButtonType.Normal }) {
        Image(this.isFavorite(board.fid, board.stid !== undefined ? board.stid : 0) ?
          $r('app.media.ic_board_star_filled') : $r('app.media.ic_board_star_outline'))
          .width(20)
          .height(20)
          .fillColor(this.accentTextColor())
      }
      .width(44)
      .height(32)
      .borderRadius(16)
      .backgroundColor(Color.Transparent)
      .accessibilityText((this.isFavorite(board.fid, board.stid !== undefined ? board.stid : 0) ?
        '取消收藏' : '收藏') + board.name)
      .onClick(() => this.toggleFavorite(board))
    }
    .width('100%')
    .padding(10)
    .backgroundColor(this.cardBg())
    .borderRadius(12)
    .alignItems(HorizontalAlign.Center)
  }

  /* ---------- 收藏板块列表项 ---------- */

  @Builder
  FavoriteBoardItem(board: Board) {
    Row() {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          Image(this.getBoardIconUrl(board)).width(40).height(40).objectFit(ImageFit.Contain)
            .alt($r('app.media.default_board_icon'))
          Text(board.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.mainTextColor())
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (!this.managingFavorites) {
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.subTextColor()])
          }
        }
        .width('100%')
      }
      .layoutWeight(1).height(64).padding(8).backgroundColor(Color.Transparent).borderRadius(16)
      .accessibilityText('打开' + board.name)
      .onClick(() => this.onFavoriteBoardClick(board))

      if (this.managingFavorites) {
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.ic_home_arrow_up')).width(18).height(18)
            .fillColor(themeAccentTextColor(this.nightMode))
        }
        .width(44).height(44).backgroundColor(Color.Transparent)
        .accessibilityText('上移' + board.name)
        .transition(TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut }))
        .enabled(this.favoritePosition(board) > 0)
        .onClick(() => this.moveFavoriteUp(this.favoritePosition(board)))

        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.ic_home_arrow_down')).width(18).height(18)
            .fillColor(themeAccentTextColor(this.nightMode))
        }
        .width(44).height(44).backgroundColor(Color.Transparent)
        .accessibilityText('下移' + board.name)
        .transition(TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut }))
        .enabled(this.favoritePosition(board) >= 0 && this.favoritePosition(board) < this.favorites.length - 1)
        .onClick(() => this.moveFavoriteDown(this.favoritePosition(board)))

        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.ic_home_close')).width(18).height(18)
            .fillColor(themeErrorTextColor(this.nightMode))
        }
        .width(44).height(44).backgroundColor(Color.Transparent)
        .accessibilityText('取消收藏' + board.name)
        .transition(TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut }))
        .onClick(() => this.removeFavorite(board.fid, board.stid))
      }
    }
    .width('100%')
    .padding(8)
    .backgroundColor(this.cardBg())
    .borderRadius(20)
    .alignItems(VerticalAlign.Center)
  }


  /* ---------- 我的：账号、缓存与设置 ---------- */

  @Builder
  MyContent() {
    Scroll(this.myScroller) {
      Column({ space: 12 }) {
        Row({ space: 14 }) {
          Image($r('app.media.ic_person'))
            .width(48)
            .height(48)
            .fillColor(this.accentTextColor())
          Column({ space: 6 }) {
            Text(this.loggedIn ? this.currentUserName : '登录 NGA')
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.mainTextColor())
            Text(this.loggedIn ? '已登录 · ' + this.accountCount.toString() + ' 个账号' : '登录后查看消息与个人资料')
              .fontSize(13)
              .fontColor(this.subTextColor())
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Image($r('app.media.ic_home_chevron_right')).width(20).height(20).fillColor(this.subTextColor())
        }
        .width('100%')
        .padding(20)
        .borderRadius(16)
        .backgroundColor(this.cardBg())
        .onClick(() => this.gotoPage('pages/LoginPage'))

        this.MyMenuItem('账号管理', '切换账号与添加账号', $r('app.media.ic_person'), 'pages/AccountManagePage')
        this.MyMenuItem('缓存话题', '查看已保存的帖子', $r('app.media.ic_home_storage'), 'pages/TopicCachePage')
        this.MyMenuItem('设置', '主题、字号与浏览偏好', $r('app.media.ic_home_settings'), 'pages/SettingsPage')
        this.MyMenuItem('关于', '版本与开源许可', $r('app.media.ic_about'), 'pages/AboutPage')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 + this.bottomContentInset() })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
    .backgroundColor(this.pageBg())
  }

  @Builder
  MyMenuItem(title: string, description: string, icon: Resource, page: string) {
    Row({ space: 12 }) {
      Image(icon).width(24).height(24).fillColor(this.accentTextColor())
      Column({ space: 4 }) {
        Text(title).fontSize(16).fontColor(this.mainTextColor())
        Text(description).fontSize(12).fontColor(this.subTextColor())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Image($r('app.media.ic_home_chevron_right')).width(20).height(20).fillColor(this.subTextColor())
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .backgroundColor(this.cardBg())
    .onClick(() => this.gotoPage(page))
  }
}

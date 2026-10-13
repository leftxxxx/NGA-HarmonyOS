import { topicTitleOptions } from './TopicUiStyle';
import { COLOR_DAY_BG, WINDOW_TOP_SAFE_AREA_PX_KEY } from '../model/AppTheme';
import { BottomSafeAreaObserver } from '../model/BottomSafeAreaObserver';

@Builder
function AppSubPageEmptyContent() {
}

/** Router 子页面共用板块页的原生标题栏，保留调用页面的状态和返回处理。 */
@Component
export struct AppSubPage {
  @StorageLink(WINDOW_TOP_SAFE_AREA_PX_KEY) private topSafeAreaPx: number = 0;
  @Prop pageTitle: ResourceStr = '';
  @Prop nightMode: boolean = false;
  @Prop pageBackground: string = COLOR_DAY_BG;
  @Prop menuItems: NavigationMenuItem[] = [];
  @BuilderParam pageContent: () => void = AppSubPageEmptyContent;
  onNavigateBack: (() => void) | undefined = undefined;
  onBottomInsetChanged: (inset: number) => void = (inset: number): void => {};

  private bottomObserver: BottomSafeAreaObserver = new BottomSafeAreaObserver();

  private subPageStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.observeBottomSafeArea();
  }

  aboutToDisappear(): void {
    this.bottomObserver.stop();
  }

  private observeBottomSafeArea(): void {
    this.bottomObserver.start(this.getUIContext(), (inset: number): void => {
      this.onBottomInsetChanged(inset);
    });
  }

  private titleOptions(): NavigationTitleOptions {
    const options: NavigationTitleOptions = topicTitleOptions(this.nightMode);
    options.barStyle = BarStyle.STANDARD;
    return options;
  }

  @Builder
  SubPageDestination(name: string) {
    NavDestination() {
      Column() {
        this.pageContent()
      }
      .width('100%')
      .height(LayoutPolicy.matchParent)
      .backgroundColor(this.pageBackground)
    }
    // 背景和内容一同延伸，末项和操作按钮由页面独立避让。
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .title(this.pageTitle, this.titleOptions())
    .hideBackButton(false)
    .hideToolBar(true)
    .menus(this.menuItems)
    .backgroundColor(this.pageBackground)
    .onShown((): void => {
      this.observeBottomSafeArea();
      this.bottomObserver.refresh();
    })
    .onBackPressed((): boolean => {
      if (this.onNavigateBack !== undefined) {
        this.onNavigateBack();
      } else {
        this.getUIContext().getRouter().back();
      }
      return true;
    })
  }

  build() {
    Column() {
      Navigation(this.subPageStack) {
      }
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)
      .navDestination(this.SubPageDestination)
      .width('100%')
      .height(LayoutPolicy.matchParent)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
      .backgroundColor(this.pageBackground)
      .onAppear(() => {
        if (this.subPageStack.size() === 0) {
          this.subPageStack.pushPath({ name: 'SubPage' }, { animated: false });
        }
      })
    }
    .width('100%')
    .height(LayoutPolicy.matchParent)
    // 窗口负责全屏转场，内容单独避让顶部，背景仍绘制到系统栏下方。
    .padding({ top: this.getUIContext().px2vp(this.topSafeAreaPx) })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .backgroundColor(this.pageBackground)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

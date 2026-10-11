import { topicTitleOptions } from './TopicUiStyle';
import { COLOR_DAY_BG } from '../model/AppTheme';

@Builder
function AppSubPageEmptyContent() {
}

/** Router 子页面共用板块页的原生标题栏，保留调用页面的状态和返回处理。 */
@Component
export struct AppSubPage {
  @Prop pageTitle: ResourceStr = '';
  @Prop nightMode: boolean = false;
  @Prop pageBackground: string = COLOR_DAY_BG;
  @Prop menuItems: NavigationMenuItem[] = [];
  @BuilderParam pageContent: () => void = AppSubPageEmptyContent;
  onNavigateBack: (() => void) | undefined = undefined;

  private subPageStack: NavPathStack = new NavPathStack();

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
      .height('100%')
      .backgroundColor(this.pageBackground)
    }
    .title(this.pageTitle, this.titleOptions())
    .hideBackButton(false)
    .hideToolBar(true)
    .menus(this.menuItems)
    .backgroundColor(this.pageBackground)
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
    Navigation(this.subPageStack) {
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .navDestination(this.SubPageDestination)
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBackground)
    // 仅延伸背景绘制，内部内容仍使用原生安全区布局。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .onAppear(() => {
      if (this.subPageStack.size() === 0) {
        this.subPageStack.pushPath({ name: 'SubPage' }, { animated: false });
      }
    })
  }
}

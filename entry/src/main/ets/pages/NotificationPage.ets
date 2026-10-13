/* 独立消息路由包装，首页直接复用 NotificationContent。 */
import { common } from '@kit.AbilityKit';
import { NotificationContent } from '../components/NotificationContent';
import { AppSubPage } from '../components/AppSubPage';
import { SettingsStore, SettingKeys, SettingDefaults, NIGHT_MODE_STORAGE_KEY } from '../model/AppSettings';
import { LoginStore } from '../model/LoginStore';
import { COLOR_DAY_BG, COLOR_NIGHT_BG, applyWindowTheme } from '../model/AppTheme';

@Entry
@Component
struct NotificationPage {
  @StorageLink(NIGHT_MODE_STORAGE_KEY) nightMode: boolean = SettingDefaults.NIGHT;
  @State private bottomSafeAreaInset: number = 0;
  @State themeIndex: number = SettingDefaults.THEME;
  @State active: boolean = false;
  @State accountKey: string = '';
  private accountVersion: number = 0;
  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    SettingsStore.init(this.ctx);
    LoginStore.init(this.ctx);
  }

  onPageShow(): void {
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);
    this.accountVersion++;
    this.accountKey = LoginStore.getUser().uid + ':' + this.accountVersion.toString();
    this.active = true;
    applyWindowTheme(this.ctx, this.nightMode);
  }

  onPageHide(): void {
    this.active = false;
  }

  build() {
    Column() {
      AppSubPage({ pageTitle: '消息', nightMode: this.nightMode,
        pageBackground: this.nightMode ? COLOR_NIGHT_BG : COLOR_DAY_BG,
        onBottomInsetChanged: (inset: number): void => { this.bottomSafeAreaInset = inset; } }) {
        NotificationContent({
          nightMode: this.nightMode,
          themeIndex: this.themeIndex,
          showTitleBar: false,
          contentBottomInset: this.bottomSafeAreaInset,
          active: this.active,
          accountKey: this.accountKey
        })
      }
    }
    .width('100%')
    .height(LayoutPolicy.matchParent)
    .backgroundColor(this.nightMode ? COLOR_NIGHT_BG : COLOR_DAY_BG)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

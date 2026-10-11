/*
 * 账号管理页面：展示账号列表，支持切换、删除、添加账号。
 * 对应 Android SettingsUserFragment + UserListAdapter。
 */

import { common } from '@kit.AbilityKit';
import { UserManager, UserAccount } from '../model/UserManager';
import { LoginStore } from '../model/LoginStore';
import { SettingsStore, SettingKeys, SettingDefaults } from '../model/AppSettings';
import { AppSubPage } from '../components/AppSubPage';
import {
  COLOR_ACCENT_BLUE,
  COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB,
  themeAccentTextColor, themeDividerColor, themeSecondarySurfaceColor,
  themeErrorTextColor, themeErrorSurfaceColor
} from '../model/AppTheme';

@Entry
@Component
struct AccountManagePage {
  @State nightMode: boolean = SettingDefaults.NIGHT;
  @State themeIndex: number = SettingDefaults.THEME;
  @State accounts: UserAccount[] = [];
  @State activeIndex: number = 0;

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    LoginStore.init(this.ctx);
    SettingsStore.init(this.ctx);
    this.nightMode = SettingsStore.getBool(SettingKeys.NIGHT, SettingDefaults.NIGHT);
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);
    this.refreshData();
  }

  onPageShow(): void {
    this.nightMode = SettingsStore.getBool(SettingKeys.NIGHT, SettingDefaults.NIGHT);
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);
    this.refreshData();
  }

  private refreshData(): void {
    this.accounts = UserManager.getUserList();
    this.activeIndex = UserManager.getActiveIndex();
  }

  private accentColor(): string {
    return COLOR_ACCENT_BLUE;
  }

  private pageBg(): string {
    return this.nightMode ? COLOR_NIGHT_BG : COLOR_DAY_BG;
  }

  private accentTextColor(): string {
    return themeAccentTextColor(this.nightMode);
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

  build() {
    Column() {
      AppSubPage({ pageTitle: '账号管理', nightMode: this.nightMode, pageBackground: this.pageBg() }) {
        this.PageContent()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  PageContent() {
    Column() {
      if (this.accounts.length === 0) {
        this.EmptyView()
      } else {
        this.AccountList()
      }

      this.AddAccountButton()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  EmptyView() {
    Column() {
      Text('暂无账号，请先登录')
        .fontSize(16)
        .fontColor(this.subTextColor())
        .margin({ bottom: 16 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  AccountList() {
    List() {
      ForEach(this.accounts, (account: UserAccount, index: number) => {
        ListItem() {
          this.AccountItem(account, index)
        }
      }, (account: UserAccount, index: number) => account.uid + '_' + index.toString())
    }
    .width('100%')
    .layoutWeight(1)
    .divider({ strokeWidth: 1, color: themeDividerColor(this.nightMode) })
  }

  @Builder
  AccountItem(account: UserAccount, index: number) {
    Row() {
      // 头像
      if (account.avatarUrl.length > 0) {
        Image(account.avatarUrl)
          .width(40)
          .height(40)
          .borderRadius(20)
          .margin({ right: 12 })
      } else {
        Image($r('app.media.default_board_icon'))
          .width(40)
          .height(40)
          .borderRadius(20)
          .margin({ right: 12 })
      }

      // 用户名 + UID
      Column() {
        Text(account.nickName.length > 0 ? account.nickName : '未知用户')
          .fontSize(16)
          .fontColor(this.mainTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text('UID: ' + account.uid)
          .fontSize(12)
          .fontColor(this.subTextColor())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 当前活跃标记
      if (index === this.activeIndex) {
        Text('当前')
          .fontSize(12)
          .fontColor('#ffffffff')
          .backgroundColor(this.accentColor())
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(4)
          .margin({ right: 8 })
      } else {
        // 切换按钮
        Text('切换')
          .fontSize(12)
          .fontColor(this.accentTextColor())
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(4)
          .margin({ right: 8 })
          .onClick(() => {
            UserManager.setActiveUser(index);
            this.refreshData();
          })
      }

      // 删除按钮
      Text('删除')
        .fontSize(12)
        .fontColor(themeErrorTextColor(this.nightMode))
        .backgroundColor(themeErrorSurfaceColor(this.nightMode))
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(4)
        .onClick(() => {
          UserManager.removeUser(index);
          this.refreshData();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(this.cardBg())
  }

  @Builder
  AddAccountButton() {
    Row() {
      Text('添加账号')
        .fontSize(16)
        .fontColor('#ffffffff')
        .backgroundColor(this.accentColor())
        .padding({ left: 24, right: 24, top: 10, bottom: 10 })
        .borderRadius(4)
        .onClick(() => {
          this.getUIContext().getRouter().pushUrl({
            url: 'pages/LoginPage'
          });
        })
    }
    .width('100%')
    .height(56)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
  }
}

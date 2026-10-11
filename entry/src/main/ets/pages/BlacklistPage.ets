/*
 * 黑名单管理页 — 鸿蒙 7 设计规范版
 * 对应 Android SettingsBlackListFragment：
 * - 展示黑名单用户列表（userId + nickName）
 * - 左滑/右滑删除单项
 * - 标题栏"全部清除"按钮
 * - 空列表时展示占位提示
 * 使用 @CustomDialog 替代手动覆盖层。
 */

import { common } from '@kit.AbilityKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { AppSubPage } from '../components/AppSubPage';
import {
  COLOR_ACCENT_BLUE,
  COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB, COLOR_DAY_ERROR,
  themeDividerColor, themeSecondarySurfaceColor, themeErrorTextColor
} from '../model/AppTheme';
import { BlacklistStore, BlacklistUser } from '../model/BlacklistStore';
import { SettingsStore, SettingKeys, SettingDefaults } from '../model/AppSettings';

/* 清空黑名单确认对话框 */
@CustomDialog
struct ClearBlacklistDialog {
  controller: CustomDialogController;
  nightMode: boolean = false;
  onConfirm: () => void = () => {};

  build() {
    Column() {
      Text('确认清空黑名单？')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT)
        .margin({ bottom: 8 })

      Text('将删除所有黑名单用户，此操作不可撤销。')
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
struct BlacklistPage {
  @State blacklist: BlacklistUser[] = [];
  @State nightMode: boolean = SettingDefaults.NIGHT;
  @State themeIndex: number = SettingDefaults.THEME;

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private clearDialogController: CustomDialogController = new CustomDialogController({
    builder: ClearBlacklistDialog({
      nightMode: this.nightMode,
      onConfirm: () => { this.clearAll(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
  });

  aboutToAppear(): void {
    SettingsStore.init(this.ctx);
    this.nightMode = SettingsStore.getBool(SettingKeys.NIGHT, SettingDefaults.NIGHT);
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);
    BlacklistStore.init(this.ctx);
    this.refreshList();
  }

  private refreshList(): void {
    this.blacklist = BlacklistStore.getList();
  }

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

  private removeAt(index: number): void {
    BlacklistStore.removeAt(index);
    this.refreshList();
  }

  private clearAll(): void {
    BlacklistStore.removeAll();
    this.refreshList();
  }

  private titleMenuItems(): NavigationMenuItem[] {
    if (this.blacklist.length === 0) {
      return [];
    }
    return [{
      value: $r('app.string.blacklist_clear_all'),
      symbolIcon: this.deleteMenuSymbol(),
      action: () => { this.clearDialogController.open(); }
    }];
  }

  private deleteMenuSymbol(): SymbolGlyphModifier {
    const trashSymbol: SymbolGlyphModifier = new SymbolGlyphModifier($r('sys.symbol.trash'));
    trashSymbol.fontColor([themeErrorTextColor(this.nightMode)]);
    return trashSymbol;
  }

  build() {
    Column() {
      AppSubPage({
        pageTitle: $r('app.string.settings_blacklist'),
        nightMode: this.nightMode,
        pageBackground: this.pageBg(),
        menuItems: this.titleMenuItems()
      }) {
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
      if (this.blacklist.length === 0) {
        this.EmptyState()
      } else {
        this.BlacklistList()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  EmptyState() {
    Column() {
      Text($r('app.string.blacklist_empty'))
        .fontSize(16)
        .fontColor(this.subTextColor())
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  BlacklistList() {
    List() {
      ForEach(this.blacklist, (user: BlacklistUser, index: number) => {
        ListItem() {
          this.BlacklistItem(user, index)
        }
        .swipeAction({ end: this.DeleteButton(index) })
      }, (user: BlacklistUser, index: number) => user.userId + '_' + index.toString())
    }
    .width('100%')
    .layoutWeight(1)
    .divider({ strokeWidth: 0.5, color: themeDividerColor(this.nightMode), startMargin: 16, endMargin: 16 })
  }

  @Builder
  BlacklistItem(user: BlacklistUser, index: number) {
    Row() {
      Column() {
        Text(user.nickName)
          .fontSize(16)
          .fontColor(this.mainTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('ID: ' + user.userId)
          .fontSize(12)
          .fontColor(this.subTextColor())
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height(64)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
  }

  @Builder
  DeleteButton(index: number) {
    Row() {
      Text($r('app.string.blacklist_delete'))
        .fontSize(14)
        .fontColor(Color.White)
        .padding({ left: 20, right: 20, top: 12, bottom: 12 })
    }
    .height(64)
    .backgroundColor(COLOR_DAY_ERROR)
    .onClick(() => {
      this.removeAt(index);
    })
  }
}

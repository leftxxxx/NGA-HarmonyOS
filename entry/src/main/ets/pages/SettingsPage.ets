/*
 * 设置页（SettingsPage）— 鸿蒙 7 设计规范版
 * 展示统一白蓝配色，可配置夜间模式、正文字号、加载图片策略、NGA 域名、清除缓存，
 * 以及黑名单 / 关键词屏蔽 / 关于三个导航入口。
 * 使用 @CustomDialog 替代手动覆盖层，图标替代文字符号。
 */

import { common } from '@kit.AbilityKit';
import { AppSubPage } from '../components/AppSubPage';
import {
  COLOR_ACCENT_BLUE,
  COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB, COLOR_DAY_ERROR,
  applyApplicationColorMode, applyWindowTheme, themeAccentTextColor, themeSecondarySurfaceColor
} from '../model/AppTheme';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  SettingsStore, SettingKeys, SettingDefaults, NIGHT_MODE_STORAGE_KEY, NIGHT_POLICY_STORAGE_KEY, NightModePolicy
} from '../model/AppSettings';
import { CacheUtil } from '../model/CacheUtil';
import { LoginStore } from '../model/LoginStore';
import { UserManager } from '../model/UserManager';

interface OptionItem {
  label: ResourceStr;
  value: number;
}

const FONT_OPTIONS: OptionItem[] = [
  { label: $r('app.string.settings_font_small'), value: 0 },
  { label: $r('app.string.settings_font_normal'), value: 1 },
  { label: $r('app.string.settings_font_large'), value: 2 },
  { label: $r('app.string.settings_font_xlarge'), value: 3 }
];

const PIC_OPTIONS: OptionItem[] = [
  { label: $r('app.string.settings_load_pic_always'), value: 0 },
  { label: $r('app.string.settings_load_pic_never'), value: 1 },
  { label: $r('app.string.settings_load_pic_wifi'), value: 2 }
];

const DOMAIN_OPTIONS: OptionItem[] = [
  { label: 'https://bbs.ngacn.cc', value: 0 },
  { label: 'https://bbs.nga.cn', value: 1 },
  { label: 'https://nga.178.com', value: 2 },
  { label: 'https://nga.donews.com', value: 3 },
  { label: 'https://ngabbs.com', value: 4 }
];

const FONT_SIZES: number[] = [14, 18, 22, 26];

const CACHE_SEED_KEY: string = 'cache_seeded';
const CACHE_SEED_FILE: string = 'nga_demo_cache.dat';
const CACHE_SEED_BYTES: number = 64 * 1024;

/* 选项面板对话框 */
@CustomDialog
struct OptionPanelDialog {
  controller: CustomDialogController;
  title: ResourceStr = '';
  options: OptionItem[] = [];
  selectedValue: number = 0;
  @StorageLink(NIGHT_MODE_STORAGE_KEY) nightMode: boolean = false;
  accentColorStr: string = COLOR_ACCENT_BLUE;
  onSelected: (value: number) => void = () => {};

  build() {
    Column() {
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT)
        .margin({ bottom: 16 })

      ForEach(this.options, (item: OptionItem) => {
        Row() {
          Text(item.label)
            .fontSize(16)
            .fontColor(this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT)
            .layoutWeight(1)
          if (this.selectedValue === item.value) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(20)
              .width(20)
              .height(20)
              .fontColor([this.accentColorStr])
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .onClick(() => {
          this.onSelected(item.value);
          this.controller.close();
        })
      }, (item: OptionItem) => item.value.toString())

      Button('取消')
        .fontSize(16)
        .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
        .fontColor(this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB)
        .width('100%')
        .height(44)
        .borderRadius(12)
        .margin({ top: 12 })
        .onClick(() => {
          this.controller.close();
        })
    }
    .width('100%')
    .padding(24)
    .backgroundColor(this.nightMode ? COLOR_NIGHT_CARD : COLOR_DAY_CARD)
    .borderRadius(16)
  }
}

/* 清空缓存确认对话框 */
@CustomDialog
struct ClearCacheDialog {
  controller: CustomDialogController;
  @StorageLink(NIGHT_MODE_STORAGE_KEY) nightMode: boolean = false;
  accentColorStr: string = COLOR_ACCENT_BLUE;
  onConfirm: () => void = () => {};

  build() {
    Column() {
      Text('确认清除缓存？')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT)
        .margin({ bottom: 8 })

      Text('将删除所有缓存数据，此操作不可撤销。')
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

        Button('清除')
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
struct SettingsPage {
  @StorageLink(NIGHT_MODE_STORAGE_KEY) nightMode: boolean = SettingDefaults.NIGHT;
  @StorageLink(NIGHT_POLICY_STORAGE_KEY) private nightModePolicy: number = SettingDefaults.NIGHT_MODE;
  @State private bottomSafeAreaInset: number = 0;
  @State themeIndex: number = SettingDefaults.THEME;
  @State fontIndex: number = SettingDefaults.FONT_SIZE;
  @State picIndex: number = SettingDefaults.LOAD_PIC;
  @State domainIndex: number = SettingDefaults.DOMAIN;
  @State cacheSize: number = 0;
  @State feedbackText: string = '';
  @State loggedIn: boolean = false;
  @State currentUserName: string = '';
  @State accountCount: number = 0;

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  private fontPanelController: CustomDialogController = new CustomDialogController({
    builder: OptionPanelDialog({
      title: $r('app.string.settings_font_size'),
      options: FONT_OPTIONS,
      selectedValue: this.fontIndex,
      accentColorStr: this.accentTextColor(),
      onSelected: (value: number) => { this.selectFont(value); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
  });

  private picPanelController: CustomDialogController = new CustomDialogController({
    builder: OptionPanelDialog({
      title: $r('app.string.settings_load_pic'),
      options: PIC_OPTIONS,
      selectedValue: this.picIndex,
      accentColorStr: this.accentTextColor(),
      onSelected: (value: number) => { this.selectPic(value); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
  });

  private domainPanelController: CustomDialogController = new CustomDialogController({
    builder: OptionPanelDialog({
      title: $r('app.string.settings_domain'),
      options: DOMAIN_OPTIONS,
      selectedValue: this.domainIndex,
      accentColorStr: this.accentTextColor(),
      onSelected: (value: number) => { this.selectDomain(value); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
  });

  private clearCacheController: CustomDialogController = new CustomDialogController({
    builder: ClearCacheDialog({
      accentColorStr: this.accentTextColor(),
      onConfirm: () => { this.confirmClearCache(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
  });

  aboutToAppear(): void {
    SettingsStore.init(this.ctx);
    applyWindowTheme(this.ctx, this.nightMode);
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);
    this.fontIndex = SettingsStore.getInt(SettingKeys.FONT_SIZE, SettingDefaults.FONT_SIZE);
    this.picIndex = SettingsStore.getInt(SettingKeys.LOAD_PIC, SettingDefaults.LOAD_PIC);
    this.domainIndex = SettingsStore.getInt(SettingKeys.DOMAIN, SettingDefaults.DOMAIN);
    LoginStore.init(this.ctx);
    this.refreshLoginState();
    this.ensureCacheSeeded();
    this.refreshCacheSize();
  }

  onPageShow(): void {
    this.refreshLoginState();
    this.refreshCacheSize();
  }

  private nightModePolicyLabel(): string {
    return this.nightModePolicy === NightModePolicy.DARK ? '开' :
      (this.nightModePolicy === NightModePolicy.LIGHT ? '关' : '跟随系统');
  }

  private async chooseNightMode(): Promise<void> {
    try {
      const choice = await this.getUIContext().getPromptAction().showActionMenu({
        title: '夜间模式',
        buttons: [
          { text: '开', color: this.accentTextColor() },
          { text: '关', color: this.accentTextColor() },
          { text: '跟随系统', color: this.accentTextColor() }
        ]
      });
      const policy: NightModePolicy = choice.index === 0 ? NightModePolicy.DARK :
        (choice.index === 1 ? NightModePolicy.LIGHT : NightModePolicy.SYSTEM);
      SettingsStore.setNightModePolicy(policy);
      applyApplicationColorMode(this.ctx);
      applyWindowTheme(this.ctx, SettingsStore.isNightMode());
    } catch (error) {
      // 取消选择保留原策略。
    }
  }

  /* ---------- 状态与工具方法 ---------- */

  private strById(res: Resource): string {
    try {
      return this.ctx.resourceManager.getStringSync(res.id);
    } catch (err) {
      return '';
    }
  }

  private labelOf(options: OptionItem[], index: number): ResourceStr {
    if (index >= 0 && index < options.length) {
      return options[index].label;
    }
    return '';
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

  private refreshCacheSize(): void {
    this.cacheSize = CacheUtil.getDirSize(this.ctx.cacheDir);
  }

  private refreshLoginState(): void {
    this.loggedIn = UserManager.hasValidUser();
    this.accountCount = UserManager.getUserSize();
    if (this.loggedIn) {
      const user = LoginStore.getUser();
      this.currentUserName = user.userName;
    } else {
      this.currentUserName = '';
    }
  }

  private ensureCacheSeeded(): void {
    const seeded: boolean = SettingsStore.getBool(CACHE_SEED_KEY, false);
    if (seeded) {
      return;
    }
    try {
      const path: string = this.ctx.cacheDir + '/' + CACHE_SEED_FILE;
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      const buffer: ArrayBuffer = new ArrayBuffer(CACHE_SEED_BYTES);
      fs.writeSync(file.fd, buffer);
      fs.closeSync(file);
    } catch (err) {
    }
    SettingsStore.setBool(CACHE_SEED_KEY, true);
  }

  private showFeedback(msg: string): void {
    this.feedbackText = msg;
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (err) {
    }
    setTimeout(() => {
      this.feedbackText = '';
    }, 3000);
  }

  /* ---------- 选择逻辑 ---------- */

  private selectFont(value: number): void {
    this.fontIndex = value;
    SettingsStore.setInt(SettingKeys.FONT_SIZE, value);
  }

  private selectPic(value: number): void {
    this.picIndex = value;
    SettingsStore.setInt(SettingKeys.LOAD_PIC, value);
  }

  private selectDomain(value: number): void {
    this.domainIndex = value;
    SettingsStore.setInt(SettingKeys.DOMAIN, value);
  }

  private confirmClearCache(): void {
    if (this.cacheSize > 0) {
      CacheUtil.clearDir(this.ctx.cacheDir);
      this.refreshCacheSize();
      this.showFeedback(this.strById($r('app.string.settings_cache_cleared')));
    } else {
      this.showFeedback(this.strById($r('app.string.settings_no_cache')));
    }
  }

  private gotoPage(url: string): void {
    this.getUIContext().getRouter().pushUrl({ url: url });
  }

  /* ---------- 构建 ---------- */

  build() {
    Column() {
      AppSubPage({
        pageTitle: $r('app.string.settings_title'),
        nightMode: this.nightMode,
        pageBackground: this.pageBg(),
        onBottomInsetChanged: (inset: number): void => { this.bottomSafeAreaInset = inset; }
      }) {
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
      if (this.feedbackText.length > 0) {
        Text(this.feedbackText)
          .fontSize(14)
          .fontColor(this.accentTextColor())
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 8, bottom: 8 })
      }
      Scroll() {
        Column() {
          this.GroupTitle($r('app.string.settings_group_appearance'))
          this.RowTheme()
          this.RowNightMode()

          this.GroupTitle($r('app.string.settings_group_font'))
          this.RowFontSize()
          this.PreviewText()

          this.GroupTitle($r('app.string.settings_group_user'))
          this.RowLogin()
          this.RowBlacklist()
          this.RowKeyword()

          this.GroupTitle($r('app.string.settings_group_browse'))
          this.RowLoadPic()
          this.RowDomain()

          this.GroupTitle($r('app.string.settings_group_other'))
          this.RowClearCache()
          this.RowAbout()

          Column() {}
          .height(24 + this.bottomSafeAreaInset)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  GroupTitle(title: Resource) {
    Text(title)
      .fontSize(13)
      .fontColor(this.subTextColor())
      .width('100%')
      .padding({ left: 16, top: 18, bottom: 6 })
  }

  /* ---------- 设置行 ---------- */

  @Builder
  RowTheme() {
    Row() {
      Text($r('app.string.settings_theme'))
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      Text($r('app.string.settings_theme_blue'))
        .fontSize(14)
        .fontColor(this.accentTextColor())
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  RowNightMode() {
    Row() {
      Text($r('app.string.settings_night_mode'))
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      Text(this.nightModePolicyLabel())
        .fontSize(14)
        .fontColor(this.subTextColor())
        .margin({ right: 10 })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([this.subTextColor()])
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
    .alignItems(VerticalAlign.Center)
    .id('settings-night-mode')
    .accessibilityText('夜间模式，' + this.nightModePolicyLabel() + '，点击更改')
    .onClick((): void => { this.chooseNightMode(); })
  }

  @Builder
  RowFontSize() {
    Row() {
      Text($r('app.string.settings_font_size'))
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      Text(this.labelOf(FONT_OPTIONS, this.fontIndex))
        .fontSize(14)
        .fontColor(this.accentTextColor())
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(20)
        .width(20)
        .height(20)
        .fontColor([this.subTextColor()])
        .margin({ left: 6 })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.fontPanelController.open();
    })
  }

  @Builder
  PreviewText() {
    Column() {
      Text($r('app.string.settings_font_preview'))
        .fontSize(FONT_SIZES[this.fontIndex])
        .fontColor(this.mainTextColor())
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.cardBg())
  }

  @Builder
  RowLogin() {
    Column() {
      Row() {
        if (this.loggedIn) {
          Column() {
            Text(this.currentUserName)
              .fontSize(16)
              .fontColor(this.mainTextColor())
              .fontWeight(FontWeight.Medium)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            if (this.accountCount > 1) {
              Text('已登录' + this.accountCount.toString() + '个账号')
                .fontSize(12)
                .fontColor(this.subTextColor())
                .margin({ top: 4 })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          // 多账号切换按钮
          if (this.accountCount > 1) {
            Button('切换')
              .fontSize(12)
              .backgroundColor(this.accentColor())
              .fontColor(Color.White)
              .height(28)
              .borderRadius(8)
              .margin({ right: 8 })
              .onClick(() => {
                UserManager.toggleUser(true);
                this.refreshLoginState();
              })
          }
        } else {
          Text($r('app.string.menu_login'))
            .fontSize(16)
            .fontColor(this.mainTextColor())
            .layoutWeight(1)
        }
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(20)
          .width(20)
          .height(20)
          .fontColor([this.subTextColor()])
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })
      .backgroundColor(this.cardBg())
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        if (this.loggedIn) {
          this.gotoPage('pages/AccountManagePage');
        } else {
          this.gotoPage('pages/LoginPage');
        }
      })
    }
  }

  @Builder
  RowBlacklist() {
    Row() {
      Text($r('app.string.settings_blacklist'))
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(20)
        .width(20)
        .height(20)
        .fontColor([this.subTextColor()])
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.gotoPage('pages/BlacklistPage');
    })
  }

  @Builder
  RowKeyword() {
    Row() {
      Text($r('app.string.settings_keyword_filter'))
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(20)
        .width(20)
        .height(20)
        .fontColor([this.subTextColor()])
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.gotoPage('pages/KeywordPage');
    })
  }

  @Builder
  RowLoadPic() {
    Row() {
      Text($r('app.string.settings_load_pic'))
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      Text(this.labelOf(PIC_OPTIONS, this.picIndex))
        .fontSize(14)
        .fontColor(this.accentTextColor())
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(20)
        .width(20)
        .height(20)
        .fontColor([this.subTextColor()])
        .margin({ left: 6 })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.picPanelController.open();
    })
  }

  @Builder
  RowDomain() {
    Row() {
      Text($r('app.string.settings_domain'))
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      Text(this.labelOf(DOMAIN_OPTIONS, this.domainIndex))
        .fontSize(12)
        .fontColor(this.accentTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(20)
        .width(20)
        .height(20)
        .fontColor([this.subTextColor()])
        .margin({ left: 6 })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.domainPanelController.open();
    })
  }

  @Builder
  RowClearCache() {
    Row() {
      Text($r('app.string.settings_clear_cache'))
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      Text(CacheUtil.formatSize(this.cacheSize))
        .fontSize(14)
        .fontColor(this.subTextColor())
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(20)
        .width(20)
        .height(20)
        .fontColor([this.subTextColor()])
        .margin({ left: 6 })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.clearCacheController.open();
    })
  }

  @Builder
  RowAbout() {
    Row() {
      Text($r('app.string.settings_about'))
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(20)
        .width(20)
        .height(20)
        .fontColor([this.subTextColor()])
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.gotoPage('pages/AboutPage');
    })
  }
}

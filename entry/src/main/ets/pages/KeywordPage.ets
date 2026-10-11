/*
 * 关键词屏蔽管理页
 * 对应 Android FilterKeywordsFragment：
 * - 展示关键词列表（keyword + enabled 开关）
 * - 输入框添加新关键词（回车确认）
 * - 点击开关切换启用/禁用
 * - 左滑/右滑删除单项
 * - 空列表时展示占位提示
 */

import { common } from '@kit.AbilityKit';
import { AppSubPage } from '../components/AppSubPage';
import {
  COLOR_ACCENT_BLUE,
  COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB, COLOR_DAY_ERROR,
  themeAccentTextColor, themeDividerColor, themeSecondarySurfaceColor
} from '../model/AppTheme';
import { KeywordStore, FilterKeywordItem } from '../model/KeywordStore';
import { SettingsStore, SettingKeys, SettingDefaults } from '../model/AppSettings';


@Entry
@Component
struct KeywordPage {
  @State keywords: FilterKeywordItem[] = [];
  @State nightMode: boolean = SettingDefaults.NIGHT;
  @State themeIndex: number = SettingDefaults.THEME;
  @State inputKeyword: string = '';

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    SettingsStore.init(this.ctx);
    this.nightMode = SettingsStore.getBool(SettingKeys.NIGHT, SettingDefaults.NIGHT);
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);
    KeywordStore.init(this.ctx);
    this.refreshList();
  }

  private refreshList(): void {
    this.keywords = KeywordStore.getList();
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

  private addKeyword(): void {
    if (this.inputKeyword.trim().length === 0) {
      return;
    }
    KeywordStore.add(this.inputKeyword.trim());
    this.inputKeyword = '';
    this.refreshList();
  }

  private toggleKeyword(index: number): void {
    KeywordStore.toggle(index);
    this.refreshList();
  }

  private removeAt(index: number): void {
    KeywordStore.removeAt(index);
    this.refreshList();
  }

  build() {
    Column() {
      AppSubPage({
        pageTitle: $r('app.string.settings_keyword_filter'),
        nightMode: this.nightMode,
        pageBackground: this.pageBg()
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
      this.InputArea()
      if (this.keywords.length === 0) {
        this.EmptyState()
      } else {
        this.KeywordList()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  InputArea() {
    Row() {
      TextInput({ placeholder: $r('app.string.filter_keywords_hint'), text: this.inputKeyword })
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .placeholderColor(this.subTextColor())
        .caretColor(themeAccentTextColor(this.nightMode))
        .layoutWeight(1)
        .height(40)
        .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
        .borderRadius(8)
        .padding({ left: 12, right: 12 })
        .onChange((value: string) => {
          this.inputKeyword = value;
        })
        .onSubmit(() => {
          this.addKeyword();
        })
      Button({ type: ButtonType.Normal }) {
        Text($r('app.string.keyword_add'))
          .fontSize(14)
          .fontColor('#ffffffff')
      }
      .height(40)
      .backgroundColor(this.accentColor())
      .borderRadius(8)
      .margin({ left: 8 })
      .padding({ left: 16, right: 16 })
      .onClick(() => {
        this.addKeyword();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(this.cardBg())
  }

  @Builder
  EmptyState() {
    Column() {
      Text($r('app.string.keyword_empty'))
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
  KeywordList() {
    List() {
      ForEach(this.keywords, (item: FilterKeywordItem, index: number) => {
        ListItem() {
          this.KeywordItem(item, index)
        }
        .swipeAction({ end: this.DeleteButton(index) })
      }, (item: FilterKeywordItem, index: number) => item.keyword + '_' + index.toString())
    }
    .width('100%')
    .layoutWeight(1)
    .divider({ strokeWidth: 0.5, color: themeDividerColor(this.nightMode), startMargin: 16, endMargin: 16 })
  }

  @Builder
  KeywordItem(item: FilterKeywordItem, index: number) {
    Row() {
      Text(item.keyword)
        .fontSize(16)
        .fontColor(item.enabled ? this.mainTextColor() : this.subTextColor())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Toggle({ type: ToggleType.Switch, isOn: item.enabled })
        .selectedColor(this.accentColor())
        .onChange((isOn: boolean) => {
          this.toggleKeyword(index);
        })
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
  }

  @Builder
  DeleteButton(index: number) {
    Row() {
      Text($r('app.string.keyword_delete'))
        .fontSize(14)
        .fontColor('#ffffffff')
        .padding({ left: 20, right: 20, top: 12, bottom: 12 })
    }
    .height(56)
    .backgroundColor(COLOR_DAY_ERROR)
    .onClick(() => {
      this.removeAt(index);
    })
  }
}

/*
 * 缓存话题列表页。
 * 对应 Android TopicCacheFragment。
 * 展示已缓存的话题列表，点击跳转 ArticleListPage（loadCache 模式），长按删除缓存。
 */

import { common } from '@kit.AbilityKit';
import {
  COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB, COLOR_DAY_ERROR,
  themeAccentTextColor, themeDividerColor, themeSecondarySurfaceColor
} from '../model/AppTheme';
import { SettingsStore, SettingKeys, SettingDefaults } from '../model/AppSettings';
import { ArticleCacheStore } from '../model/ArticleCacheStore';
import { ThreadPageInfo } from '../model/ThreadPageInfo';
import { AppSubPage } from '../components/AppSubPage';

@Entry
@Component
struct TopicCachePage {
  @State nightMode: boolean = SettingDefaults.NIGHT;
  @State themeIndex: number = SettingDefaults.THEME;
  @State cacheList: ThreadPageInfo[] = [];
  @State loadError: string = '';
  @State showDeleteDialog: boolean = false;
  @State deleteTargetTid: number = 0;
  @State deleteTargetSubject: string = '';
  @State feedbackMsg: string = '';

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    SettingsStore.init(this.ctx);
    ArticleCacheStore.init(this.ctx);
    this.nightMode = SettingsStore.getBool(SettingKeys.NIGHT, SettingDefaults.NIGHT);
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);
    this.loadCacheList();
  }

  /* ---------- 状态与工具方法 ---------- */

  private accentTextColor(): string {
    return themeAccentTextColor(this.nightMode);
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

  private loadCacheList(): void {
    this.cacheList = ArticleCacheStore.loadCacheTopicList();
    if (this.cacheList.length === 0) {
      this.loadError = '暂无缓存话题';
    } else {
      this.loadError = '';
    }
  }

  private onTopicClick(info: ThreadPageInfo): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ArticleListPage',
      params: { tid: info.tid, title: info.subject, loadCache: true, page: info.page }
    });
  }

  private onTopicLongPress(info: ThreadPageInfo): void {
    this.deleteTargetTid = info.tid;
    this.deleteTargetSubject = info.subject;
    this.showDeleteDialog = true;
  }

  private confirmDelete(): void {
    const success: boolean = ArticleCacheStore.removeCacheTopic(this.deleteTargetTid);
    if (success) {
      this.feedbackMsg = '已删除缓存';
    } else {
      this.feedbackMsg = '删除失败';
    }
    this.showDeleteDialog = false;
    this.loadCacheList();
    setTimeout(() => {
      this.feedbackMsg = '';
    }, 2000);
  }

  /* ---------- 构建 ---------- */

  build() {
    Column() {
      AppSubPage({ pageTitle: '缓存话题', nightMode: this.nightMode, pageBackground: this.pageBg() }) {
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
      // 反馈消息
      if (this.feedbackMsg.length > 0) {
        Row() {
          Text(this.feedbackMsg)
            .fontSize(14)
            .fontColor(this.accentTextColor())
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        }
        .width('100%')
        .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
      }

      if (this.cacheList.length === 0) {
        this.EmptyView()
      } else {
        this.CacheListView()
      }

      // 删除确认弹窗
      if (this.showDeleteDialog) {
        this.DeleteDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  EmptyView() {
    Column() {
      Text('暂无缓存话题')
        .fontSize(16)
        .fontColor(this.subTextColor())
        .margin({ bottom: 8 })

      Text('在帖子详情页点击"缓存"按钮即可缓存话题')
        .fontSize(14)
        .fontColor(this.subTextColor())
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  CacheListView() {
    List() {
      ForEach(this.cacheList, (info: ThreadPageInfo) => {
        ListItem() {
          this.CacheItem(info)
        }
      }, (info: ThreadPageInfo) => info.tid.toString())
    }
    .width('100%')
    .layoutWeight(1)
    .divider({ strokeWidth: 1, color: themeDividerColor(this.nightMode) })
  }

  @Builder
  CacheItem(info: ThreadPageInfo) {
    Column() {
      // 标题行
      Row() {
        Text(info.subject)
          .fontSize(16)
          .fontColor(this.mainTextColor())
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 回复数
        if (info.replies > 0) {
          Text(info.replies.toString() + '回复')
            .fontSize(12)
            .fontColor(this.accentTextColor())
            .margin({ left: 8 })
        }
      }
      .width('100%')

      // 作者信息行
      Row() {
        if (info.author.length > 0) {
          Text(info.author)
            .fontSize(12)
            .fontColor(this.subTextColor())
        }

        if (info.lastPoster.length > 0) {
          Text('最后回复: ' + info.lastPoster)
            .fontSize(12)
            .fontColor(this.subTextColor())
            .margin({ left: 12 })
        }
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(this.cardBg())
    .onClick(() => {
      this.onTopicClick(info);
    })
    .gesture(
      LongPressGesture({ repeat: false, duration: 500 })
        .onAction(() => {
          this.onTopicLongPress(info);
        })
    )
  }

  @Builder
  DeleteDialog() {
    Column() {
      Text('确认删除缓存？')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.mainTextColor())
        .margin({ bottom: 8 })

      Text(this.deleteTargetSubject)
        .fontSize(14)
        .fontColor(this.subTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ bottom: 24 })

      Row() {
        Button('取消')
          .fontSize(16)
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
          .fontColor(this.mainTextColor())
          .layoutWeight(1)
          .margin({ right: 12 })
          .onClick(() => {
            this.showDeleteDialog = false;
          })

        Button('删除')
          .fontSize(16)
          .backgroundColor(COLOR_DAY_ERROR)
          .fontColor('#ffffffff')
          .layoutWeight(1)
          .onClick(() => {
            this.confirmDelete();
          })
      }
      .width('100%')
    }
    .width('80%')
    .padding(24)
    .backgroundColor(this.cardBg())
    .borderRadius(12)
    .shadow({ radius: 20, color: '#99000000', offsetX: 0, offsetY: 8 })
  }
}

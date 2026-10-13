/*
 * 用户主页（资料）页面（UserProfilePage）。
 * 展示用户头像、昵称、UID、发帖数、注册时间、用户组、账号状态、金钱、签名、威望、管理板块。
 * 对应 Android ProfileActivity + JsonProfileLoadTask + ProfileData。
 */

import { common } from '@kit.AbilityKit';
import { AppSubPage } from '../components/AppSubPage';
import {
  COLOR_ACCENT_BLUE,
  COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB,
  themeAccentTextColor, themeErrorTextColor, themeWarningTextColor
} from '../model/AppTheme';
import { SettingsStore, SettingKeys, SettingDefaults, NIGHT_MODE_STORAGE_KEY } from '../model/AppSettings';
import { LoginStore } from '../model/LoginStore';
import { HttpClient } from '../model/HttpClient';
import { UrlBuilder } from '../model/UrlBuilder';
import { NgaJsonParser } from '../model/NgaJsonParser';
import { ProfileData, ReputationItem, AdminForumItem } from '../model/ProfileData';
import { AvatarUtils } from '../model/AvatarUtils';

@Entry
@Component
struct UserProfilePage {
  @StorageLink(NIGHT_MODE_STORAGE_KEY) nightMode: boolean = SettingDefaults.NIGHT;
  @State private bottomSafeAreaInset: number = 0;
  @State themeIndex: number = SettingDefaults.THEME;
  @State uid: number = 0;
  @State isLoading: boolean = false;
  @State loadError: string = '';
  @State profile: ProfileData = new ProfileData();

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    SettingsStore.init(this.ctx);
    LoginStore.init(this.ctx);
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);

    // 从路由参数获取用户 uid
    const params: Record<string, Object> = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (params !== null && params !== undefined) {
      const uidVal: Object | undefined = params['uid'];
      if (typeof uidVal === 'number') {
        this.uid = uidVal;
      }
    }

    this.loadProfile();
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

  /* ---------- 数据加载 ---------- */

  private async loadProfile(): Promise<void> {
    if (this.uid === 0) {
      this.loadError = '无效的用户 ID';
      return;
    }
    this.isLoading = true;
    this.loadError = '';

    const url: string = UrlBuilder.buildUserProfileUrl(this.uid);
    const referer: string = UrlBuilder.buildUserProfileReferer(this.uid);
    const result = await HttpClient.get(url, { 'Referer': referer });

    this.isLoading = false;

    if (result.success) {
      this.profile = NgaJsonParser.parseProfile(result.body);
      this.loadError = '';
    } else {
      this.loadError = '加载失败，请重试';
    }
  }

  /* ---------- 构建 ---------- */

  build() {
    Column() {
      AppSubPage({
        pageTitle: this.profile.username.length > 0 ? this.profile.username : '用户主页',
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
      } else if (this.loadError.length > 0) {
        this.ErrorView()
      } else {
        this.ProfileView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  ErrorView() {
    Column() {
      Text(this.loadError)
        .fontSize(16)
        .fontColor(this.subTextColor())
        .margin({ bottom: 16 })

      Button('重试')
        .fontSize(16)
        .backgroundColor(this.accentColor())
        .fontColor('#ffffffff')
        .onClick(() => {
          this.loadProfile();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  ProfileView() {
    Scroll() {
      Column() {
        this.BasicInfoCard()

        if (this.profile.sign.length > 0) {
          this.SignCard()
        }

        if (this.profile.reputationList.length > 0) {
          this.ReputationCard()
        }

        if (this.profile.adminForumList.length > 0) {
          this.AdminForumCard()
        }
      }
      .width('100%')
      .padding({ bottom: 16 + this.bottomSafeAreaInset })
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  BasicInfoCard() {
    Column() {
      // 头像 + 昵称 + 状态
      Row() {
        // 头像
        if (AvatarUtils.isValidAvatar(this.profile.avatar)) {
          Image(this.profile.avatar)
            .width(72)
            .height(72)
            .borderRadius(36)
            .alt($r('app.media.default_board_icon'))
            .margin({ right: 16 })
        } else {
          Image($r('app.media.default_board_icon'))
            .width(72)
            .height(72)
            .borderRadius(36)
            .margin({ right: 16 })
        }

        // 昵称 + 状态
        Column() {
          Text(this.profile.username)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.mainTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(this.profile.memberGroup)
            .fontSize(14)
            .fontColor(this.accentTextColor())
            .margin({ top: 4 })

          Text(this.profile.getStateText())
            .fontSize(12)
            .fontColor(this.profile.nuked ? themeErrorTextColor(this.nightMode) :
              (this.profile.muted ? themeWarningTextColor(this.nightMode) : this.subTextColor()))
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      // 详细信息行
      this.InfoRow('UID', this.profile.uid.toString())
      this.InfoRow('发帖数', this.profile.postCount.toString())
      this.InfoRow('注册时间', this.profile.registerDate)
      if (this.profile.email.length > 0) {
        this.InfoRow('邮箱', this.profile.email)
      }
      if (this.profile.phone.length > 0) {
        this.InfoRow('手机', this.profile.phone)
      }
      this.InfoRow('金钱', this.profile.money.toString() + '（金' + this.profile.getGold().toString() +
        ' 银' + this.profile.getSilver().toString() + ' 铜' + this.profile.getCopper().toString() + '）')
      if (this.profile.fame.length > 0) {
        this.InfoRow('威望', this.profile.fame)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.cardBg())
    .margin({ top: 8, left: 12, right: 12 })
    .borderRadius(8)
  }

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor(this.subTextColor())
        .width(80)

      Text(value)
        .fontSize(14)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  SignCard() {
    Column() {
      Text('签名')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.subTextColor())
        .width('100%')

      Text(this.profile.sign)
        .fontSize(14)
        .fontColor(this.mainTextColor())
        .width('100%')
        .margin({ top: 8 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.cardBg())
    .margin({ top: 8, left: 12, right: 12 })
    .borderRadius(8)
  }

  @Builder
  ReputationCard() {
    Column() {
      Text('声望')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.subTextColor())
        .width('100%')

      ForEach(this.profile.reputationList, (rep: ReputationItem) => {
        Row() {
          Text(rep.name)
            .fontSize(14)
            .fontColor(this.subTextColor())
            .layoutWeight(1)

          Text(rep.value)
            .fontSize(14)
            .fontColor(this.accentTextColor())
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
      }, (rep: ReputationItem) => rep.name)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.cardBg())
    .margin({ top: 8, left: 12, right: 12 })
    .borderRadius(8)
  }

  @Builder
  AdminForumCard() {
    Column() {
      Text('管理板块')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.subTextColor())
        .width('100%')

      ForEach(this.profile.adminForumList, (forum: AdminForumItem) => {
        Text(forum.name)
          .fontSize(14)
          .fontColor(this.mainTextColor())
          .width('100%')
          .padding({ top: 6, bottom: 6 })
      }, (forum: AdminForumItem) => forum.fid.toString())
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.cardBg())
    .margin({ top: 8, left: 12, right: 12 })
    .borderRadius(8)
  }
}

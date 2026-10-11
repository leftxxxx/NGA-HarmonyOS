/*
 * 关于页（AboutPage）
 * 展示应用基本信息、开源许可、原项目作者与源码出处。
 */


import { common, Want, bundleManager } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { SettingsStore, SettingKeys, SettingDefaults } from '../model/AppSettings';
import { AppSubPage } from '../components/AppSubPage';
import {
  COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB,
  themeAccentTextColor, themeSecondarySurfaceColor
} from '../model/AppTheme';

const APP_NAME: string = 'NGA客户端开源版';
const VERSION_LABEL: string = '版本';
const LICENSE_LABEL: string = 'License';
const LICENSE_SUB: string = 'GNU GPL v2,开放源代码许可';

const DEV_GROUP_TITLE: string = '原项目作者';
const CODE_LABEL: string = '代码';
const CODE_SUB: string = '[@竹井詩織里]/[@cfan8]/[@jjimmys]\n[@Moandor]/[@Elrond]/[@Justwen]';
const ART_LABEL: string = '美工';
const ART_SUB: string = '[@那个惩戒骑]/[@从来不卖萌]';
const GITHUB_LABEL: string = '原项目源码';
const GITHUB_SUB: string = '开源出处与贡献者';

const THANKS_GROUP_TITLE: string = '赞美片总!感谢[@force0119]';
const URL_GITHUB_SOURCE: string = 'https://github.com/Justwen/NGA-CLIENT-VER-OPEN-SOURCE';

const LICENSE_FILE: string = 'OSLICENSE.TXT';
const LICENSE_FALLBACK: string = 'GNU GPL v2\n开放源代码许可';

@Entry
@Component
struct AboutPage {
  @State nightMode: boolean = SettingDefaults.NIGHT;
  @State versionName: string = '3.7.6';
  @State showLicense: boolean = false;
  @State licenseText: string = '';

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    SettingsStore.init(this.ctx);
    this.nightMode = SettingsStore.getBool(SettingKeys.NIGHT, SettingDefaults.NIGHT);
    this.versionName = this.readVersionName();
  }

  /* ---------- 工具方法 ---------- */

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

  private readVersionName(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (err) {
      return '3.7.6';
    }
  }

  private openUrl(url: string): void {
    try {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url
      };
      this.ctx.startAbility(want);
    } catch (err) {
    }
  }

  private onLicenseClick(): void {
    if (this.licenseText.length === 0) {
      this.licenseText = this.readLicenseText();
    }
    this.showLicense = true;
  }

  private readLicenseText(): string {
    try {
      const bytes: Uint8Array = this.ctx.resourceManager.getRawFileContentSync(LICENSE_FILE);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(bytes);
    } catch (err) {
      return LICENSE_FALLBACK;
    }
  }

  /* ---------- 构建 ---------- */

  build() {
    Column() {
      AppSubPage({
        pageTitle: $r('app.string.settings_about'),
        nightMode: this.nightMode,
        pageBackground: this.pageBg(),
        onNavigateBack: () => {
          if (this.showLicense) {
            this.showLicense = false;
          } else {
            this.getUIContext().getRouter().back();
          }
        }
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
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Scroll() {
          Column() {
            this.AppGroup()
            this.DevGroup()
            this.GroupTitle(THANKS_GROUP_TITLE)
            Column()
              .height(24)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBg())

      if (this.showLicense) {
        this.LicensePanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  GroupTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(this.subTextColor())
      .width('100%')
      .padding({ left: 16, top: 18, bottom: 6 })
  }

  /* ---------- 应用信息分组 ---------- */

  @Builder
  AppGroup() {
    Column()
      .height(12)
    this.AppNameRow()
    this.VersionRow()
    this.LicenseRow()
  }

  @Builder
  AppNameRow() {
    Row() {
      Text(APP_NAME)
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
  }

  @Builder
  VersionRow() {
    Row() {
      Text(VERSION_LABEL)
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      Text(this.versionName)
        .fontSize(14)
        .fontColor(this.subTextColor())
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
  }

  @Builder
  LicenseRow() {
    Row() {
      Text(LICENSE_LABEL)
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      Text(LICENSE_SUB)
        .fontSize(12)
        .fontColor(this.subTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
    .onClick(() => {
      this.onLicenseClick();
    })
  }

  /* ---------- 开发团队分组 ---------- */

  @Builder
  DevGroup() {
    this.GroupTitle(DEV_GROUP_TITLE)
    this.CodeRow()
    this.ArtRow()
    this.GithubRow()
  }

  @Builder
  CodeRow() {
    Row() {
      Text(CODE_LABEL)
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      Text(CODE_SUB)
        .fontSize(12)
        .fontColor(this.subTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
  }

  @Builder
  ArtRow() {
    Row() {
      Text(ART_LABEL)
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      Text(ART_SUB)
        .fontSize(12)
        .fontColor(this.subTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
  }

  @Builder
  GithubRow() {
    Row() {
      Text(GITHUB_LABEL)
        .fontSize(16)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
      Text(GITHUB_SUB)
        .fontSize(14)
        .fontColor(this.subTextColor())
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.cardBg())
    .onClick(() => {
      this.openUrl(URL_GITHUB_SOURCE);
    })
  }

  /* ---------- 开源许可内容面板 ---------- */

  @Builder
  LicensePanel() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .onClick(() => {
          this.showLicense = false;
        })
      Column() {
        Stack() {
          Text(LICENSE_LABEL)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.mainTextColor())
          Row() {
            Text($r('app.string.back'))
              .fontSize(16)
              .fontColor(this.accentTextColor())
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .onClick(() => {
                this.showLicense = false;
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.Start)
        }
        .width('100%')
        .height(48)
        .backgroundColor(themeSecondarySurfaceColor(this.nightMode))

        Scroll() {
          Text(this.licenseText)
            .fontSize(13)
            .fontColor(this.mainTextColor())
            .width('100%')
            .padding(12)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('90%')
      .height('85%')
      .backgroundColor(this.cardBg())
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
  }
}

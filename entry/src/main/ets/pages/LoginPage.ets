/*
 * 登录页（LoginPage）
 * 支持 WebView 登录（默认）与账号密码表单登录两种方式。
 * 对应 Android LoginActivity / LoginWebFragment / LoginFragment / LoginDialogFragment。
 *
 * 场景覆盖：
 *   1  未登录首屏（WebView 默认 + 第三方提示 + 切换入口）
 *   2  WebView 加载进度
 *   3  WebView 登录成功并持久化凭据
 *   4  WebView 页面内后退导航
 *   5  切换到账号密码表单登录
 *   6  表单验证码加载与展示
 *   7  表单空字段校验
 *   8  表单验证码对话框提交 / 取消
 *   9  表单登录失败后验证码刷新
 *   10 验证码加载失败
 *   11 Cookie 不完整不保存
 *   12 已登录状态展示当前用户
 *   13 退出登录
 *   14 网络错误与离线
 *   15 登录成功后返回并通知调用方
 *   16 登录入口与设置页集成（入口在 SettingsPage 侧）
 */


import { common } from '@kit.AbilityKit';
import { AppSubPage } from '../components/AppSubPage';
import web_webview from '@ohos.web.webview';
import { LoginStore, UserIdentity } from '../model/LoginStore';
import { LoginService, FormLoginResult, WEB_LOGIN_URL, WEB_COOKIE_DOMAIN } from '../model/LoginService';
import { SettingsStore, SettingKeys, SettingDefaults } from '../model/AppSettings';
import {
  COLOR_ACCENT_BLUE,
  COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB,
  themeAccentTextColor, themeSecondarySurfaceColor,
  themeErrorTextColor, themeErrorSurfaceColor, themeWarningTextColor, themeWarningSurfaceColor
} from '../model/AppTheme';

/* 对话框遮罩 */
const COLOR_OVERLAY: string = '#99000000';

/* 第三方提示自动消失延时（ms） */
const TIP_DURATION: number = 5000;
/* 登录成功后返回延时（ms），留出 Toast 可见时间 */
const LOGIN_SUCCESS_BACK_DELAY: number = 1200;

@Entry
@Component
struct LoginPage {
  @State nightMode: boolean = SettingDefaults.NIGHT;
  @State themeIndex: number = SettingDefaults.THEME;
  /* 登录方式：0 = WebView，1 = 账号密码表单 */
  @State loginMode: number = 0;

  /* WebView 状态 */
  @State webProgress: number = 0;
  @State webLoading: boolean = false;
  @State webError: boolean = false;
  @State showThirdPartyTip: boolean = false;

  /* 表单状态 */
  @State userName: string = '';
  @State password: string = '';
  @State authCodeImg: string = '';
  @State authCodeLoading: boolean = false;
  @State authCodeLoadFail: boolean = false;
  @State showAuthCodeDialog: boolean = false;
  @State dialogAuthCode: string = '';
  @State submitting: boolean = false;

  /* 登录状态 */
  @State loggedIn: boolean = false;
  @State currentUserName: string = '';

  /* 反馈文本（用于页面内提示条） */
  @State feedbackText: string = '';

  /* 返回处理标志（防止异步 Cookie 提取期间重复触发） */
  private isReturning: boolean = false;

  /* WebView 控制器 */
  private controller: web_webview.WebviewController = new web_webview.WebviewController();

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  /* ---------- 生命周期 ---------- */

  aboutToAppear(): void {
    LoginStore.init(this.ctx);
    SettingsStore.init(this.ctx);
    this.nightMode = SettingsStore.getBool(SettingKeys.NIGHT, SettingDefaults.NIGHT);
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);
    this.loggedIn = LoginStore.hasUser();
    if (this.loggedIn) {
      const user: UserIdentity = LoginStore.getUser();
      this.currentUserName = user.userName;
    } else {
      /* 未登录：默认 WebView 方式，显示一次性第三方提示 */
      this.loginMode = 0;
      this.showThirdPartyTip = true;
      setTimeout(() => {
        this.showThirdPartyTip = false;
      }, TIP_DURATION);
    }
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

  private accentTextColor(): string {
    return themeAccentTextColor(this.nightMode);
  }

  /**
   * 系统返回处理。
   * - 验证码对话框显示 → 关闭对话框，不退出页面
   * - WebView 方式且有后退历史 → WebView 后退，不退出页面
   * - WebView 方式且无后退历史 → 提取 Cookie 后返回上一页
   * - 其他 → 正常返回
   */
  onBackPress(): boolean {
    if (this.isReturning) {
      return true;
    }
    if (this.showAuthCodeDialog) {
      this.showAuthCodeDialog = false;
      return true;
    }
    if (this.loginMode === 0 && !this.loggedIn) {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
      if (!this.isReturning) {
        this.handleReturn();
        return true;
      }
    }
    return false;
  }

  /* ---------- 工具方法 ---------- */

  private strById(res: Resource): string {
    try {
      return this.ctx.resourceManager.getStringSync(res.id);
    } catch (err) {
      return '';
    }
  }

  private showToast(msg: string): void {
    this.feedbackText = msg;
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (err) {
    }
    setTimeout(() => {
      this.feedbackText = '';
    }, 3000);
  }

  /* ---------- 返回与 Cookie 提取 ---------- */

  /**
   * 处理返回上一页。
   * WebView 方式下先提取 Cookie 并尝试持久化，完成后返回。
   */
  private handleReturn(): void {
    if (this.isReturning) {
      return;
    }
    if (this.loginMode === 0 && !this.loggedIn) {
      const saved: boolean = this.extractAndSaveCookie();
      if (saved) {
        this.isReturning = true;
        setTimeout(() => {
          this.isReturning = false;
          this.getUIContext().getRouter().back();
        }, LOGIN_SUCCESS_BACK_DELAY);
        return;
      }
    }
    this.isReturning = false;
    this.getUIContext().getRouter().back();
  }

  /**
   * 提取 WebView Cookie 并解析用户身份。
   * 三件套齐全 → 持久化 + 提示"登录成功"，返回 true。
   * 不完整 → 不持久化，不提示（场景十一），返回 false。
   */
  private extractAndSaveCookie(): boolean {
    try {
      const cookie: string = web_webview.WebCookieManager.fetchCookieSync(WEB_COOKIE_DOMAIN);
      const user: UserIdentity = LoginService.parseCookie(cookie);
      if (LoginService.isComplete(user)) {
        LoginStore.saveUser(user.uid, user.cid, user.userName);
        this.loggedIn = true;
        this.currentUserName = user.userName;
        this.showToast(this.strById($r('app.string.login_successfully')));
        return true;
      }
    } catch (err) {
    }
    return false;
  }

  /* ---------- 方式切换 ---------- */

  private switchToForm(): void {
    this.loginMode = 1;
    this.loadAuthCode();
  }

  private switchToWeb(): void {
    this.loginMode = 0;
  }

  /* ---------- 验证码 ---------- */

  /**
   * 加载验证码图片。
   * 成功 → 更新 authCodeImg（base64 data url）。
   * 失败 → 提示"载入验证码失败"（场景十）。
   */
  private async loadAuthCode(): Promise<void> {
    this.authCodeLoading = true;
    this.authCodeLoadFail = false;
    try {
      const dataUrl: string = await LoginService.loadAuthCode();
      this.authCodeImg = dataUrl;
    } catch (err) {
      this.authCodeImg = '';
      this.authCodeLoadFail = true;
      this.showToast(this.strById($r('app.string.login_authcode_load_fail')));
    } finally {
      this.authCodeLoading = false;
    }
  }

  /* ---------- 表单登录 ---------- */

  /**
   * 表单"登录"按钮点击。
   * 用户名或密码为空 → 提示"内容缺少，请检查后再试"（场景七）。
   * 否则弹出验证码对话框（场景八）。
   */
  private onFormLoginClick(): void {
    if (this.userName.length === 0 || this.password.length === 0) {
      this.showToast(this.strById($r('app.string.login_content_missing')));
      return;
    }
    this.dialogAuthCode = '';
    this.showAuthCodeDialog = true;
  }

  /**
   * 验证码对话框"登录"按钮点击 → 提交登录请求。
   * 验证码为空 → 提示"内容缺少，请检查后再试"。
   * 提交中 → 不重复响应（场景八第 6 点）。
   * 成功 → 持久化 + 提示"登录成功" + 返回（场景八第 7 点 / 场景十五）。
   * 失败 → 提示错误 + 刷新验证码（场景九）。
   */
  private async submitFormLogin(): Promise<void> {
    if (this.submitting) {
      return;
    }
    if (this.dialogAuthCode.length === 0) {
      this.showToast(this.strById($r('app.string.login_content_missing')));
      return;
    }
    this.submitting = true;
    try {
      const result: FormLoginResult = await LoginService.formLogin(this.userName, this.password, this.dialogAuthCode);
      if (result.success) {
        LoginStore.saveUser(result.uid, result.cid, result.userName);
        this.loggedIn = true;
        this.currentUserName = result.userName;
        this.showAuthCodeDialog = false;
        this.showToast(this.strById($r('app.string.login_successfully')));
        this.isReturning = true;
        setTimeout(() => {
          this.isReturning = false;
          this.getUIContext().getRouter().back();
        }, LOGIN_SUCCESS_BACK_DELAY);
      } else {
        this.showToast(result.error);
        this.loadAuthCode();
      }
    } catch (err) {
      this.showToast(this.strById($r('app.string.network_error')));
      this.loadAuthCode();
    } finally {
      this.submitting = false;
    }
  }

  /** 验证码对话框"取消"按钮 → 关闭对话框，保留已填内容（场景八·取消） */
  private cancelAuthCodeDialog(): void {
    this.showAuthCodeDialog = false;
  }

  /* ---------- 已登录操作 ---------- */

  /** 退出登录 → 清除本地用户身份，切换为未登录首屏（场景十三） */
  private logout(): void {
    LoginStore.clearUser();
    this.loggedIn = false;
    this.currentUserName = '';
    this.loginMode = 0;
    this.showThirdPartyTip = true;
    setTimeout(() => {
      this.showThirdPartyTip = false;
    }, TIP_DURATION);
  }

  /** 重新登录 → 进入 WebView 登录流程（场景十二第 6 点） */
  private relogin(): void {
    this.loginMode = 0;
    this.showThirdPartyTip = true;
    setTimeout(() => {
      this.showThirdPartyTip = false;
    }, TIP_DURATION);
  }

  /* ---------- 构建 ---------- */

  build() {
    Column() {
      AppSubPage({
        pageTitle: $r('app.string.login'),
        nightMode: this.nightMode,
        pageBackground: this.pageBg(),
        onNavigateBack: () => {
          if (!this.onBackPress()) {
            this.handleReturn();
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
        if (this.feedbackText.length > 0) {
          Text(this.feedbackText)
            .fontSize(14)
            .fontColor(this.loginMode === 1 && this.authCodeLoadFail ?
              themeErrorTextColor(this.nightMode) : this.accentTextColor())
            .backgroundColor(this.loginMode === 1 && this.authCodeLoadFail ?
              themeErrorSurfaceColor(this.nightMode) : themeSecondarySurfaceColor(this.nightMode))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 8, bottom: 8 })
        }
        if (this.loggedIn) {
          this.LoggedInView()
        } else if (this.loginMode === 0) {
          this.WebViewLoginView()
        } else {
          this.FormLoginView()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBg())

      if (this.showAuthCodeDialog) {
        this.AuthCodeDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  /* ---------- 已登录视图（场景十二） ---------- */

  @Builder
  LoggedInView() {
    Column() {
      Column() {
        Text($r('app.string.username'))
          .fontSize(14)
          .fontColor(this.subTextColor())
          .width('100%')
          .margin({ bottom: 8 })

        Text(this.currentUserName)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.mainTextColor())
          .width('100%')
          .margin({ bottom: 24 })
      }
      .width('100%')
      .padding(20)
      .backgroundColor(this.cardBg())
      .borderRadius(8)
      .margin({ top: 16 })

      Column() {
        Text($r('app.string.login_logout'))
          .fontSize(16)
          .fontColor(themeErrorTextColor(this.nightMode))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 14, bottom: 14 })
          .onClick(() => {
            this.logout();
          })
      }
      .width('100%')
      .backgroundColor(this.cardBg())
      .borderRadius(8)
      .margin({ top: 12 })

      Column() {
        Text($r('app.string.login_relogin'))
          .fontSize(16)
          .fontColor(this.accentTextColor())
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 14, bottom: 14 })
          .onClick(() => {
            this.relogin();
          })
      }
      .width('100%')
      .backgroundColor(this.cardBg())
      .borderRadius(8)
      .margin({ top: 12 })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 16, right: 16 })
  }

  /* ---------- WebView 登录视图（场景一~四、十一、十四） ---------- */

  @Builder
  WebViewLoginView() {
    Column() {
      /* 一次性第三方登录提示（场景一第 4 点） */
      if (this.showThirdPartyTip) {
        Text($r('app.string.login_no_third_party'))
          .fontSize(13)
          .fontColor(themeWarningTextColor(this.nightMode))
          .backgroundColor(themeWarningSurfaceColor(this.nightMode))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 6, bottom: 6 })
      }

      /* 加载进度指示（场景二） */
      if (this.webLoading) {
        Progress({ value: this.webProgress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(3)
          .color(this.accentTextColor())
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
      }

      /* WebView 区域 */
      Column() {
        Web({ src: WEB_LOGIN_URL, controller: this.controller })
          .width('100%')
          .height('100%')
          .backgroundColor(this.pageBg())
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .onlineImageAccess(true)
          .onPageBegin(() => {
            this.webLoading = true;
            this.webError = false;
          })
          .onPageEnd(() => {
            this.webLoading = false;
          })
          .onProgressChange((e) => {
            this.webProgress = e.newProgress;
          })
          .onErrorReceive(() => {
            this.webLoading = false;
            this.webError = true;
          })
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(this.pageBg())

      /* 网络错误反馈（场景十四） */
      if (this.webError) {
        Text($r('app.string.login_web_load_fail'))
          .fontSize(14)
          .fontColor(themeErrorTextColor(this.nightMode))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 10, bottom: 10 })
          .backgroundColor(themeErrorSurfaceColor(this.nightMode))
      }

      /* 切换到账号密码表单登录入口（场景一第 5 点 / 场景五） */
      Row() {
        Text($r('app.string.login_form_mode'))
          .fontSize(15)
          .fontColor(this.accentTextColor())
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 14, bottom: 14 })
      }
      .width('100%')
      .backgroundColor(this.cardBg())
      .onClick(() => {
        this.switchToForm();
      })
    }
    .width('100%')
    .height('100%')
  }

  /* ---------- 账号密码表单登录视图（场景五~十） ---------- */

  @Builder
  FormLoginView() {
    Scroll() {
      Column() {
        /* 用户名输入框 */
        Column() {
          Text($r('app.string.login_user_hint'))
            .fontSize(13)
            .fontColor(this.subTextColor())
            .width('100%')
            .margin({ bottom: 6 })
          TextInput({ text: this.userName, placeholder: this.strById($r('app.string.login_user_hint')) })
            .fontSize(16)
            .fontColor(this.mainTextColor())
            .placeholderColor(this.subTextColor())
            .caretColor(this.accentTextColor())
            .width('100%')
            .height(44)
            .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
            .borderRadius(6)
            .onChange((value: string) => {
              this.userName = value;
            })
        }
        .width('100%')
        .margin({ top: 20, bottom: 16 })

        /* 密码输入框 */
        Column() {
          Text($r('app.string.password'))
            .fontSize(13)
            .fontColor(this.subTextColor())
            .width('100%')
            .margin({ bottom: 6 })
          TextInput({ text: this.password, placeholder: this.strById($r('app.string.login_password_hint')) })
            .fontSize(16)
            .fontColor(this.mainTextColor())
            .placeholderColor(this.subTextColor())
            .caretColor(this.accentTextColor())
            .width('100%')
            .height(44)
            .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
            .borderRadius(6)
            .type(InputType.Password)
            .onChange((value: string) => {
              this.password = value;
            })
        }
        .width('100%')
        .margin({ bottom: 16 })

        /* 验证码图片 + 更新验证码（场景六） */
        Row() {
          Column() {
            if (this.authCodeImg.length > 0) {
              Image(this.authCodeImg)
                .width(140)
                .height(50)
                .borderRadius(4)
                .backgroundColor(this.cardBg())
            } else if (this.authCodeLoading) {
              Text($r('app.string.login_authcode_loading'))
                .fontSize(14)
                .fontColor(this.subTextColor())
                .width(140)
                .height(50)
                .textAlign(TextAlign.Center)
            } else {
              Text($r('app.string.login_authcode_empty'))
                .fontSize(14)
                .fontColor(this.subTextColor())
                .width(140)
                .height(50)
                .textAlign(TextAlign.Center)
            }
          }
          .width(140)
          .height(50)
          .backgroundColor(this.cardBg())
          .borderRadius(4)

          Text($r('app.string.login_update_authcode'))
            .fontSize(14)
            .fontColor(this.accentTextColor())
            .margin({ left: 16 })
            .onClick(() => {
              this.loadAuthCode();
            })
        }
        .width('100%')
        .margin({ bottom: 24 })

        /* 登录按钮 */
        Row() {
          Text($r('app.string.login'))
            .fontSize(17)
            .fontColor('#ffffffff')
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height(48)
        .backgroundColor(this.accentColor())
        .opacity(this.submitting ? 0.6 : 1)
        .borderRadius(6)
        .onClick(() => {
          this.onFormLoginClick();
        })

        /* 切换回 WebView 登录入口 */
        Row() {
          Text($r('app.string.login_web_mode'))
            .fontSize(15)
            .fontColor(this.accentTextColor())
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 16 })
        }
        .width('100%')
        .onClick(() => {
          this.switchToWeb();
        })

        Column() {
        }
        .height(24)
      }
      .width('100%')
      .padding({ left: 20, right: 20 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  /* ---------- 验证码对话框（场景八） ---------- */

  @Builder
  AuthCodeDialog() {
    Stack({ alignContent: Alignment.Center }) {
      /* 遮罩层 */
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(COLOR_OVERLAY)
        .onClick(() => {
          this.cancelAuthCodeDialog();
        })

      /* 对话框内容 */
      Column() {
        Text($r('app.string.authcode'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.mainTextColor())
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 16 })

        /* 验证码图片 */
        Row() {
          if (this.authCodeImg.length > 0) {
            Image(this.authCodeImg)
              .width(160)
              .height(60)
              .borderRadius(4)
          } else {
            Text($r('app.string.login_authcode_empty'))
              .fontSize(14)
              .fontColor(this.subTextColor())
              .width(160)
              .height(60)
              .textAlign(TextAlign.Center)
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ bottom: 16 })

        /* 验证码输入框 */
        TextInput({ text: this.dialogAuthCode, placeholder: this.strById($r('app.string.authcode')) })
          .fontSize(16)
          .fontColor(this.mainTextColor())
          .placeholderColor(this.subTextColor())
          .caretColor(this.accentTextColor())
          .width('100%')
          .height(44)
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
          .borderRadius(6)
          .margin({ bottom: 16 })
          .onChange((value: string) => {
            this.dialogAuthCode = value;
          })

        /* 登录 / 取消按钮 */
        Row() {
          Text($r('app.string.cancel'))
            .fontSize(16)
            .fontColor(this.subTextColor())
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 12, bottom: 12 })
            .onClick(() => {
              this.cancelAuthCodeDialog();
            })
          Text($r('app.string.login'))
            .fontSize(16)
            .fontColor(this.accentTextColor())
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .padding({ top: 12, bottom: 12 })
            .onClick(() => {
              this.submitFormLogin();
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(20)
      .backgroundColor(this.cardBg())
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
  }
}

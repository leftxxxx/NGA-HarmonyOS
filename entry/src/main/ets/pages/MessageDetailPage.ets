import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { AppSubPage } from '../components/AppSubPage';
import { ArticleBody } from '../components/ArticleBody';
import {
  COLOR_ACCENT_BLUE, COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB,
  applyWindowTheme, themeAccentTextColor, themeSecondarySurfaceColor
} from '../model/AppTheme';
import { SettingsStore, SettingKeys, SettingDefaults, NIGHT_MODE_STORAGE_KEY } from '../model/AppSettings';
import { LoginStore } from '../model/LoginStore';
import { HttpClient } from '../model/HttpClient';
import { UrlBuilder } from '../model/UrlBuilder';
import { MessageDetailParser } from '../model/MessageDetailParser';
import { MessageReplyParser, NgaMessageReplyResult } from '../model/MessageReplyParser';
import { GbkEncoder } from '../model/GbkEncoder';
import { NgaMessageDetailData, NgaMessagePost } from '../model/MessageDetailInfo';
import { renderArticleContent } from '../model/ArticleHtml';

/** 从第一页阅读短消息原文，后续会话按顺序追加。 */
@Entry
@Component
struct MessageDetailPage {
  @StorageLink(NIGHT_MODE_STORAGE_KEY) nightMode: boolean = SettingDefaults.NIGHT;
  @State private bottomSafeAreaInset: number = 0;
  @State mid: number = 0;
  @State subject: string = '';
  @State postList: NgaMessagePost[] = [];
  @State isLoading: boolean = false;
  @State loadError: string = '';
  @State loadMoreError: string = '';
  @State currentPage: number = 0;
  @State nextPage: number = 0;
  @State replyText: string = '';
  @State isReplying: boolean = false;
  @State isSending: boolean = false;
  @State sendError: string = '';
  @State replyUncertain: boolean = false;
  @State uncertainReviewed: boolean = false;
  @State isRefreshing: boolean = false;
  @State refreshError: string = '';
  @State conversationInvalid: boolean = false;

  private ctx: common.UIAbilityContext | undefined = undefined;
  private mounted: boolean = false;
  private requestVersion: number = 0;
  private sendVersion: number = 0;
  private activeAccountKey: string = '';
  private emoticonSources: Map<string, string> = new Map<string, string>();
  private base64: util.Base64Helper = new util.Base64Helper();
  private messageScroller: Scroller = new Scroller();
  private keyboardAvoidMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET;
  private keyboardModeSet: boolean = false;

  aboutToAppear(): void {
    this.mounted = true;
    this.keyboardAvoidMode = this.getUIContext().getKeyboardAvoidMode();
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.keyboardModeSet = true;
    this.ctx = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (this.ctx === undefined) {
      this.loadError = '页面初始化失败，请返回后重试';
      return;
    }
    SettingsStore.init(this.ctx);
    LoginStore.init(this.ctx);
    this.activeAccountKey = LoginStore.getUser().uid;
    const params: Record<string, Object> | undefined =
      this.getUIContext().getRouter().getParams() as Record<string, Object> | undefined;
    if (params !== undefined && params !== null) {
      const mid: Object | undefined = params['mid'];
      const subject: Object | undefined = params['subject'];
      if (typeof mid === 'number') {
        this.mid = mid;
      }
      if (typeof subject === 'string') {
        this.subject = subject;
      }
    }
    this.loadDetail(1);
  }

  onPageShow(): void {
    if (this.ctx === undefined || !this.mounted) {
      return;
    }
    applyWindowTheme(this.ctx, this.nightMode);
    const accountKey: string = LoginStore.getUser().uid;
    if (accountKey !== this.activeAccountKey || !LoginStore.hasUser()) {
      this.requestVersion++;
      this.sendVersion++;
      this.isLoading = false;
      this.isSending = false;
      this.isRefreshing = false;
      this.isReplying = false;
      this.replyText = '';
      this.sendError = '';
      this.refreshError = '';
      this.replyUncertain = false;
      this.uncertainReviewed = false;
      this.conversationInvalid = true;
      this.postList = [];
      this.subject = '';
      this.currentPage = 0;
      this.nextPage = 0;
      this.loadMoreError = '';
      this.activeAccountKey = accountKey;
      this.loadError = '账号已变化，请返回消息列表重新打开';
    }
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.requestVersion++;
    this.sendVersion++;
    if (this.keyboardModeSet) {
      this.getUIContext().setKeyboardAvoidMode(this.keyboardAvoidMode);
      this.keyboardModeSet = false;
    }
  }

  private isCurrentRequest(version: number, mid: number, accountKey: string): boolean {
    return this.mounted && this.requestVersion === version && this.mid === mid &&
      this.activeAccountKey === accountKey && LoginStore.hasUser() &&
      LoginStore.getUser().uid === accountKey;
  }

  private async loadDetail(page: number, append: boolean = false): Promise<void> {
    if (!this.mounted || this.isLoading || this.isSending || this.isRefreshing || this.conversationInvalid) {
      return;
    }
    if (!Number.isSafeInteger(this.mid) || this.mid <= 0) {
      this.loadError = '短消息编号无效，请返回消息列表重试';
      return;
    }
    if (!LoginStore.hasUser() || LoginStore.getUser().uid !== this.activeAccountKey) {
      this.postList = [];
      this.loadError = '登录状态已变化，请返回消息列表重新打开';
      return;
    }
    if (!Number.isSafeInteger(page) || page < 1 || (append && page <= this.currentPage)) {
      return;
    }
    const version: number = ++this.requestVersion;
    const requestMid: number = this.mid;
    const accountKey: string = this.activeAccountKey;
    this.isLoading = true;
    if (append) {
      this.loadMoreError = '';
    } else {
      this.loadError = '';
    }
    try {
      const result = await HttpClient.get(UrlBuilder.buildMessageReadUrl(requestMid, page));
      if (!this.isCurrentRequest(version, requestMid, accountKey)) {
        return;
      }
      if (!result.success) {
        throw new Error('短消息加载失败，请检查网络后重试');
      }
      const detail: NgaMessageDetailData = MessageDetailParser.parse(result.body, requestMid, page);
      if (!detail.success) {
        throw new Error(detail.errorMessage || '短消息加载失败，请重试');
      }
      if (detail.currentPage !== page) {
        throw new Error('消息页码异常，请重试');
      }
      const merged: NgaMessagePost[] = append ? this.postList.slice() : [];
      const keys: Set<string> = new Set<string>();
      for (const post of merged) {
        keys.add(post.key);
      }
      for (const post of detail.posts) {
        if (!keys.has(post.key)) {
          keys.add(post.key);
          merged.push(post);
        }
      }
      this.postList = merged;
      if (!append && detail.subject.length > 0) {
        this.subject = detail.subject;
      }
      this.currentPage = detail.currentPage;
      // nextPage 兼容实际页号和 1（有下一页）两种协议值。
      this.nextPage = detail.posts.length > 0 && detail.nextPage > 0 ?
        (detail.nextPage > this.currentPage ? detail.nextPage : this.currentPage + 1) : 0;
      this.loadError = '';
      this.loadMoreError = '';
    } catch (error) {
      if (this.isCurrentRequest(version, requestMid, accountKey)) {
        const message: string = (error as Error).message || '短消息加载失败，请重试';
        if (append) {
          this.loadMoreError = message;
        } else {
          this.loadError = message;
        }
      }
    } finally {
      if (this.mounted && this.requestVersion === version) {
        this.isLoading = false;
      }
    }
  }

  private isCurrentSend(version: number, mid: number, accountKey: string): boolean {
    return this.mounted && this.sendVersion === version && this.mid === mid &&
      !this.conversationInvalid && this.activeAccountKey === accountKey && LoginStore.hasUser() &&
      LoginStore.getUser().uid === accountKey;
  }

  private async sendReply(): Promise<void> {
    if (!this.mounted || this.isSending || this.isRefreshing || this.replyUncertain) {
      return;
    }
    if (!Number.isSafeInteger(this.mid) || this.mid <= 0) {
      this.sendError = '短消息编号无效，请返回消息列表重试';
      return;
    }
    if (this.conversationInvalid || !LoginStore.hasUser() ||
      LoginStore.getUser().uid !== this.activeAccountKey) {
      this.sendError = '登录状态已变化，请返回消息列表重新打开';
      return;
    }
    if (this.replyText.trim().length === 0) {
      this.sendError = '请输入回复内容';
      return;
    }
    const content: string = this.replyText;
    try {
      // 在发起请求前检查编码，不能把本地拒绝误报为发送结果未知。
      GbkEncoder.encode(content);
    } catch (error) {
      this.sendError = (error as Error).message || '回复内容无法编码，请修改后重试';
      return;
    }
    const version: number = ++this.sendVersion;
    const requestMid: number = this.mid;
    const accountKey: string = this.activeAccountKey;
    this.isSending = true;
    this.sendError = '';
    this.refreshError = '';
    this.uncertainReviewed = false;
    // 与发送前仍在进行的分页请求隔离，避免旧会话覆盖发送后的刷新。
    this.requestVersion++;
    this.isLoading = false;
    let confirmed: boolean = false;
    try {
      const result = await HttpClient.post(UrlBuilder.buildMessageReplyUrl(), {
        '__lib': 'message', '__act': 'message', 'lite': 'js', 'act': 'reply',
        'mid': requestMid.toString(), 'to': '', 'subject': '', 'content': content
      }, true);
      if (!this.isCurrentSend(version, requestMid, accountKey)) {
        return;
      }
      if (!result.success) {
        this.replyUncertain = true;
        this.sendError = '发送结果未确认，草稿已保留。请先查看最新会话，避免重复发送';
        return;
      }
      const feedback: NgaMessageReplyResult = MessageReplyParser.parse(result.body);
      if (!feedback.success) {
        this.replyUncertain = feedback.uncertain;
        this.sendError = feedback.errorMessage || '短消息回复失败，请稍后重试';
        return;
      }
      confirmed = true;
      this.replyText = '';
      this.isReplying = false;
      this.replyUncertain = false;
      this.isSending = false;
      this.getUIContext().getPromptAction().showToast({ message: '回复已发送' });
      await this.refreshAfterReply();
    } catch (error) {
      if (this.isCurrentSend(version, requestMid, accountKey)) {
        if (confirmed) {
          this.refreshError = '最新会话加载失败，请稍后刷新';
        } else {
          this.replyUncertain = true;
          this.sendError = '发送结果未确认，草稿已保留。请先查看最新会话，避免重复发送';
        }
      }
    } finally {
      if (this.mounted && this.sendVersion === version) {
        this.isSending = false;
      }
    }
  }

  /** 从原文读取到最新回复，全部成功后替换列表；失败时保留已阅读的会话。 */
  private async refreshAfterReply(): Promise<boolean> {
    if (!this.mounted || this.isRefreshing || this.conversationInvalid || !LoginStore.hasUser() ||
      LoginStore.getUser().uid !== this.activeAccountKey) {
      return false;
    }
    const version: number = ++this.requestVersion;
    const requestMid: number = this.mid;
    const accountKey: string = this.activeAccountKey;
    this.isLoading = false;
    this.isRefreshing = true;
    this.refreshError = '';
    const posts: NgaMessagePost[] = [];
    const keys: Set<string> = new Set<string>();
    let page: number = 1;
    let refreshedSubject: string = this.subject;
    try {
      while (page <= 100) {
        const result = await HttpClient.get(UrlBuilder.buildMessageReadUrl(requestMid, page));
        if (!this.isCurrentRequest(version, requestMid, accountKey)) {
          return false;
        }
        if (!result.success) {
          throw new Error('最新会话加载失败，请检查网络后重试');
        }
        const detail: NgaMessageDetailData = MessageDetailParser.parse(result.body, requestMid, page);
        if (!detail.success || detail.currentPage !== page || detail.posts.length === 0) {
          throw new Error(detail.errorMessage || '最新会话加载失败，请重试');
        }
        if (page === 1 && detail.subject.length > 0) {
          refreshedSubject = detail.subject;
        }
        const previousCount: number = posts.length;
        for (const post of detail.posts) {
          if (!keys.has(post.key)) {
            keys.add(post.key);
            posts.push(post);
          }
        }
        if (posts.length === previousCount) {
          throw new Error('会话分页未更新，请稍后刷新');
        }
        if (detail.nextPage <= 0) {
          this.postList = posts;
          this.subject = refreshedSubject;
          this.currentPage = page;
          this.nextPage = 0;
          this.loadError = '';
          this.loadMoreError = '';
          this.uncertainReviewed = this.replyUncertain;
          this.scrollToLatest(version, requestMid, accountKey);
          this.getUIContext().getPromptAction().showToast({ message: '已更新到最新会话' });
          return true;
        }
        page = detail.nextPage > page ? detail.nextPage : page + 1;
      }
      throw new Error('会话较长，请稍后重新打开查看最新回复');
    } catch (error) {
      if (this.isCurrentRequest(version, requestMid, accountKey)) {
        this.refreshError = (error as Error).message || '最新会话加载失败，请重试';
      }
      return false;
    } finally {
      if (this.mounted && this.requestVersion === version) {
        this.isRefreshing = false;
      }
    }
  }

  private startReply(): void {
    if (!this.isSending && !this.isRefreshing && !this.conversationInvalid) {
      this.isReplying = true;
      this.sendError = this.replyUncertain ? this.sendError : '';
    }
  }

  private scrollToLatest(version: number, mid: number, accountKey: string): void {
    setTimeout(() => {
      if (this.isCurrentRequest(version, mid, accountKey)) {
        try {
          this.messageScroller.scrollEdge(Edge.Bottom);
        } catch (error) {
          // 滚动组件尚未布局时仍保留已加载的最新会话。
        }
      }
    }, 100);
  }

  private confirmReplyNotSent(): void {
    if (this.replyUncertain && this.uncertainReviewed && !this.isSending && !this.isRefreshing) {
      this.replyUncertain = false;
      this.uncertainReviewed = false;
      this.sendError = '';
      this.isReplying = true;
    }
  }

  private cancelReply(): void {
    if (!this.isSending) {
      this.isReplying = false;
    }
  }

  private async navigateBack(): Promise<void> {
    if (this.isSending) {
      this.getUIContext().getPromptAction().showToast({ message: '正在发送，请稍候' });
      return;
    }
    if (this.isReplying) {
      this.cancelReply();
      return;
    }
    if (this.replyText.length > 0) {
      try {
        const decision = await this.getUIContext().getPromptAction().showDialog({
          title: '离开当前会话？', message: '尚有未发送的回复，离开后将丢弃草稿。',
          buttons: [
            { text: '继续编辑', color: themeAccentTextColor(this.nightMode) },
            { text: '丢弃并返回', color: this.subTextColor() }
          ]
        });
        if (!this.mounted) {
          return;
        }
        if (decision.index !== 1) {
          this.startReply();
          return;
        }
      } catch (error) {
        return;
      }
    }
    this.getUIContext().getRouter().back();
  }

  onBackPress(): boolean {
    this.navigateBack();
    return true;
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

  private getLocalEmoticonSource(path: string): string {
    const cached: string | undefined = this.emoticonSources.get(path);
    if (cached !== undefined) {
      return cached;
    }
    let source: string = '';
    if (this.ctx !== undefined) {
      try {
        const bytes: Uint8Array = this.ctx.resourceManager.getRawFileContentSync(path);
        const mime: string = path.endsWith('.gif') ? 'image/gif' : 'image/png';
        source = 'data:' + mime + ';base64,' + this.base64.encodeToStringSync(bytes);
      } catch (error) {
        // 缺失资源由已有正文解析器回退，保留文字可读性。
      }
    }
    this.emoticonSources.set(path, source);
    return source;
  }

  private buildHtmlContent(content: string): string {
    const bg: string = '#' + this.cardBg().substring(3);
    const text: string = '#' + this.mainTextColor().substring(3);
    const link: string = '#' + themeAccentTextColor(this.nightMode).substring(3);
    const decoded: string = renderArticleContent(content, 'https://img.nga.cn/attachments/',
      (path: string): string => this.getLocalEmoticonSource(path), HttpClient.getDomain() + '/');
    return '<!DOCTYPE html><html><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width,initial-scale=1.0"><style>' +
      'html{background:' + bg + ';}body{background:' + bg + ';color:' + text +
      ';font-size:16px;line-height:1.75;padding:0;margin:0;overflow-wrap:anywhere;}' +
      'img{max-width:100%;height:auto;}img.article-image{display:block;margin:12px 0;border-radius:12px;}' +
      'img.emoticon{height:1.5em;width:auto;vertical-align:middle;display:inline-block;}' +
      'blockquote{margin:8px 0;padding:8px;border-left:3px solid ' + link + ';}a{color:' + link + ';}' +
      (this.nightMode ? 'img.invertFilter{filter:invert(100%);}' : '') +
      '</style></head><body>' + decoded + '</body></html>';
  }

  private formatTime(timestamp: number): string {
    if (timestamp <= 0) {
      return '';
    }
    const date: Date = new Date(timestamp * 1000);
    return date.getFullYear().toString() + '-' + (date.getMonth() + 1).toString().padStart(2, '0') +
      '-' + date.getDate().toString().padStart(2, '0') + ' ' +
      date.getHours().toString().padStart(2, '0') + ':' + date.getMinutes().toString().padStart(2, '0');
  }

  @Builder
  MessagePostCard(post: NgaMessagePost) {
    Column({ space: 14 }) {
      Row({ space: 8 }) {
        Text(post.index === 1 ? '原文' : '回复 ' + (post.index - 1).toString())
          .fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(themeAccentTextColor(this.nightMode))
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
          .borderRadius(10).padding({ left: 8, right: 8, top: 4, bottom: 4 })
        Text(post.author).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.mainTextColor()).layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      if (post.time > 0) {
        Text(this.formatTime(post.time)).fontSize(12).fontColor(this.subTextColor())
      }
      if (post.subject.length > 0 && post.subject !== this.subject) {
        Text(post.subject).fontSize(18).fontWeight(FontWeight.Medium).lineHeight(28)
          .fontColor(this.mainTextColor()).width('100%')
      }
      if (post.content.length > 0) {
        ArticleBody({ html: this.buildHtmlContent(post.content), bodyBackground: this.cardBg(),
          baseUrl: HttpClient.getDomain() + '/' })
      } else {
        Text('这条消息没有正文').fontSize(14).fontColor(this.subTextColor())
      }
    }
    .width('100%').padding(18).borderRadius(20).backgroundColor(this.cardBg())
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  MessageListView() {
    List({ space: 12, scroller: this.messageScroller }) {
      ListItem() {
        Text(this.subject.length > 0 ? this.subject : '短消息会话')
          .fontSize(24).fontWeight(FontWeight.Bold).lineHeight(34)
          .fontColor(this.mainTextColor()).width('100%')
          .padding({ top: 8, bottom: 6 })
      }
      ForEach(this.postList, (post: NgaMessagePost) => {
        ListItem() {
          this.MessagePostCard(post)
        }
      }, (post: NgaMessagePost): string => post.key)
      ListItem() {
        Column({ space: 12 }) {
          if (this.isLoading || this.isRefreshing) {
            LoadingProgress().width(28).height(28).color(themeAccentTextColor(this.nightMode))
          } else if (this.nextPage > 0) {
            if (this.loadMoreError.length > 0) {
              Text(this.loadMoreError).fontSize(14).fontColor(this.subTextColor())
                .textAlign(TextAlign.Center)
            }
            Button(this.loadMoreError.length > 0 ? '重新加载后续消息' : '加载后续消息',
              { type: ButtonType.Capsule })
              .height(44).fontSize(14).fontColor(themeAccentTextColor(this.nightMode))
              .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
              .enabled(!this.isSending)
              .onClick(() => this.loadDetail(this.nextPage, true))
          } else {
            Text('已显示全部消息').fontSize(13).fontColor(this.subTextColor())
          }
        }
        .width('100%').padding({ top: 8, bottom: 16 })
      }
    }
    .width('100%').layoutWeight(1).padding({ left: 16, right: 16 })
    .contentEndOffset(24).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  ReplyDock() {
    Column({ space: 10 }) {
      if (this.refreshError.length > 0) {
        Text((this.replyText.length === 0 && !this.replyUncertain ? '回复已发送。' : '') + this.refreshError)
          .fontSize(13).fontColor(this.subTextColor()).width('100%')
        Button('刷新最新会话', { type: ButtonType.Capsule })
          .height(40).fontSize(14).fontColor(themeAccentTextColor(this.nightMode))
          .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
          .enabled(!this.isSending && !this.isRefreshing)
          .onClick(() => this.refreshAfterReply())
      }
      if (this.sendError.length > 0) {
        Text(this.sendError).fontSize(13).fontColor(this.subTextColor()).width('100%')
      }
      if (this.replyUncertain) {
        Row({ space: 10 }) {
          Button(this.isRefreshing ? '正在刷新…' : '查看最新会话', { type: ButtonType.Capsule })
            .height(40).fontSize(14).fontColor(themeAccentTextColor(this.nightMode))
            .backgroundColor(themeSecondarySurfaceColor(this.nightMode)).layoutWeight(1)
            .enabled(!this.isSending && !this.isRefreshing)
            .onClick(() => {
              this.cancelReply();
              this.refreshAfterReply();
            })
          if (this.uncertainReviewed) {
            Button('确认未发送，继续编辑', { type: ButtonType.Capsule })
              .height(40).fontSize(13).fontColor(themeAccentTextColor(this.nightMode))
              .backgroundColor(themeSecondarySurfaceColor(this.nightMode)).layoutWeight(1)
              .enabled(!this.isSending && !this.isRefreshing)
              .onClick(() => this.confirmReplyNotSent())
          }
        }
        .width('100%')
      }
      if (this.isReplying) {
        Row() {
          Text('回复当前会话').fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.mainTextColor()).layoutWeight(1)
          Button('收起', { type: ButtonType.Capsule })
            .height(36).fontSize(14).fontColor(this.subTextColor())
            .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
            .enabled(!this.isSending).onClick(() => this.cancelReply())
        }
        .width('100%')
        TextArea({ placeholder: '输入回复内容', text: this.replyText })
          .id('messageReplyInput').width('100%').height(112)
          .fontSize(16).fontColor(this.mainTextColor()).placeholderColor(this.subTextColor())
          .caretColor(themeAccentTextColor(this.nightMode)).backgroundColor(this.cardBg())
          .borderRadius(16).padding(14)
          .enabled(!this.isSending && !this.replyUncertain)
          .onChange((text: string) => {
            if (!this.isSending && !this.replyUncertain) {
              this.replyText = text;
              this.sendError = '';
            }
          })
        Button(this.isSending ? '正在发送…' : '发送回复', { type: ButtonType.Capsule })
          .id('messageReplySend').width('100%').height(44).fontSize(15)
          .fontColor(Color.White).backgroundColor(COLOR_ACCENT_BLUE)
          .enabled(!this.isSending && !this.isRefreshing && !this.replyUncertain)
          .onClick(() => this.sendReply())
      } else if (!this.replyUncertain) {
        Button(this.replyText.length > 0 ? '继续回复 · 草稿已保留' : '回复', { type: ButtonType.Capsule })
          .id('messageReplyOpen').width('100%').height(44).fontSize(15)
          .fontColor(Color.White).backgroundColor(COLOR_ACCENT_BLUE)
          .enabled(!this.isSending && !this.isRefreshing).onClick(() => this.startReply())
      }
    }
    .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 12 + this.bottomSafeAreaInset })
    .backgroundColor(this.pageBg()).alignItems(HorizontalAlign.Start)
  }

  @Builder
  PageContent() {
    Column() {
      if (this.isLoading && this.postList.length === 0) {
        Column() {
          LoadingProgress().width(48).height(48).color(themeAccentTextColor(this.nightMode))
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.loadError.length > 0 || this.postList.length === 0) {
        Column({ space: 16 }) {
          Text(this.loadError.length > 0 ? this.loadError : '暂无消息内容')
            .fontSize(16).fontColor(this.subTextColor()).textAlign(TextAlign.Center)
          if (this.loadError.length > 0 && !this.conversationInvalid) {
            Button('重试', { type: ButtonType.Capsule })
              .height(44).fontSize(16).fontColor(Color.White).backgroundColor(COLOR_ACCENT_BLUE)
              .padding({ left: 28, right: 28 }).onClick(() => this.loadDetail(1))
          }
        }
        .width('100%').layoutWeight(1).padding(24).justifyContent(FlexAlign.Center)
      } else {
        this.MessageListView()
      }
      if (this.postList.length > 0 && !this.conversationInvalid) {
        this.ReplyDock()
      }
    }
    .width('100%').height('100%').backgroundColor(this.pageBg())
  }

  build() {
    Column() {
      AppSubPage({ pageTitle: '短消息', nightMode: this.nightMode, pageBackground: this.pageBg(),
        onBottomInsetChanged: (inset: number): void => { this.bottomSafeAreaInset = inset; },
        onNavigateBack: () => { this.navigateBack(); } }) {
        this.PageContent()
      }
    }
    .width('100%')
    .height(LayoutPolicy.matchParent)
    .backgroundColor(this.pageBg())
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

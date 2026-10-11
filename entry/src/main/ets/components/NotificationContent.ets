/*
 * 可嵌入首页底栏的通知/消息内容，NotificationPage 保留独立路由包装。
 * 展示被喷提醒（回复通知）和短消息两个 Tab。
 * 对应 Android RecentNotificationFragment + MessageListFragment。
 *
 * 通知查询：GET nuke.php?__lib=noti&__output=8&__act=get_all
 * 短消息列表：GET nuke.php?__lib=message&__act=message&act=list&lite=js&page={page}
 * 响应格式：window.script_muti_get_var_store={...JSON...}
 */

import { common } from '@kit.AbilityKit';
import {
  COLOR_ACCENT_BLUE,
  COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB, COLOR_DAY_ERROR, themeAccentTextColor
} from '../model/AppTheme';
import { SettingDefaults } from '../model/AppSettings';
import { LoginStore } from '../model/LoginStore';
import { HttpClient } from '../model/HttpClient';
import { UrlBuilder } from '../model/UrlBuilder';
import { NgaJsonParser } from '../model/NgaJsonParser';
import { ReplyNotification, MessageNotification, NotificationData } from '../model/NotificationInfo';
import { topicSecondarySurfaceColor } from './TopicUiStyle';

class NotificationLoadResult {
  success: boolean = false;
  error: string = '';
  data: NotificationData = new NotificationData();
}

class MessageLoadResult {
  success: boolean = false;
  error: string = '';
  messages: MessageNotification[] = [];
  nextPage: number = 0;
  hasPagination: boolean = false;
}

@Component
export struct NotificationContent {
  @Prop nightMode: boolean = SettingDefaults.NIGHT;
  @Prop themeIndex: number = SettingDefaults.THEME;
  @Prop showTitleBar: boolean = true;
  @Prop contentBottomInset: number = 0;
  @Prop @Watch('onActiveChanged') active: boolean = true;
  @Prop @Watch('onAccountChanged') accountKey: string = '';
  @State loggedIn: boolean = false;
  @State currentTab: number = 0; // 0=被喷提醒, 1=短消息
  @State replyList: ReplyNotification[] = [];
  @State messageList: MessageNotification[] = [];
  @State unread: number = 0;
  @State isLoading: boolean = false;
  @State loadError: string = '';
  @State msgPage: number = 1;
  @State msgHasMore: boolean = true;

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private mounted: boolean = false;
  private requestVersion: number = 0;
  private nextMessagePage: number = 2;
  private messagesLoaded: boolean = false;

  aboutToAppear(): void {
    LoginStore.init(this.ctx);
    this.mounted = true;
    this.loggedIn = LoginStore.hasUser();
    if (this.active) {
      this.refreshCurrentTab();
    }
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.requestVersion++;
  }

  private onActiveChanged(): void {
    if (!this.mounted) {
      return;
    }
    if (this.active) {
      this.refreshCurrentTab();
    } else {
      this.requestVersion++;
      this.isLoading = false;
    }
  }

  private onAccountChanged(): void {
    this.requestVersion++;
    this.isLoading = false;
    this.replyList = [];
    this.messageList = [];
    this.unread = 0;
    this.loadError = '';
    this.msgPage = 1;
    this.nextMessagePage = 2;
    this.msgHasMore = true;
    this.messagesLoaded = false;
    if (this.mounted) {
      this.loggedIn = LoginStore.hasUser();
      if (this.active) {
        this.refreshCurrentTab();
      }
    }
  }

  private refreshCurrentTab(): void {
    this.loggedIn = LoginStore.hasUser();
    if (!this.mounted || !this.active || !this.loggedIn) {
      return;
    }
    if (this.currentTab === 0) {
      this.loadNotifications();
    } else {
      this.loadMessages(1);
    }
  }

  private acceptsResult(version: number, account: string): boolean {
    return this.mounted && this.active && version === this.requestVersion && account === this.accountKey;
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

  private async loadNotifications(): Promise<void> {
    if (!this.active || !this.loggedIn) {
      return;
    }
    const version: number = ++this.requestVersion;
    const account: string = this.accountKey;
    this.isLoading = true;
    this.loadError = '';
    try {
      const response = await HttpClient.get(UrlBuilder.buildNotificationUrl());
      if (!this.acceptsResult(version, account)) {
        return;
      }
      const parsed: NotificationLoadResult = this.parseNotificationResult(response.body);
      if (response.success && parsed.success) {
        this.replyList = parsed.data.replyList;
        this.unread = parsed.data.unread;
      } else {
        this.loadError = (response.body.length > 0 ? parsed.error : response.error) ||
          response.error || parsed.error || '加载失败，请重试';
      }
    } catch (err) {
      if (this.acceptsResult(version, account)) {
        this.loadError = '回复提醒加载失败，请检查网络后重试';
      }
    } finally {
      if (this.acceptsResult(version, account)) {
        this.isLoading = false;
      }
    }
  }

  private async loadMessages(page: number): Promise<void> {
    if (!this.active || !this.loggedIn) {
      return;
    }
    const version: number = ++this.requestVersion;
    const account: string = this.accountKey;
    this.isLoading = true;
    this.loadError = '';
    try {
      const response = await HttpClient.get(UrlBuilder.buildMessageListUrl(page));
      if (!this.acceptsResult(version, account)) {
        return;
      }
      const parsed: MessageLoadResult = this.parseMessageResult(response.body);
      if (response.success && parsed.success) {
        this.messageList = page === 1 ? parsed.messages : this.messageList.concat(parsed.messages);
        this.msgPage = page;
        this.nextMessagePage = parsed.hasPagination && parsed.nextPage > page ? parsed.nextPage : page + 1;
        this.msgHasMore = parsed.hasPagination ? parsed.nextPage > 0 : parsed.messages.length > 0;
        this.messagesLoaded = true;
      } else {
        this.loadError = (response.body.length > 0 ? parsed.error : response.error) ||
          response.error || parsed.error || '加载失败，请重试';
      }
    } catch (err) {
      if (this.acceptsResult(version, account)) {
        this.loadError = '短消息加载失败，请检查网络后重试';
      }
    } finally {
      if (this.acceptsResult(version, account)) {
        this.isLoading = false;
      }
    }
  }

  /** 服务端错误和结构错误必须可见，不能被解析成“暂无消息”。 */
  private responseInner(body: string): Record<string, Object> {
    const root: Record<string, Object> = NgaJsonParser.parseResponseObject(body);
    // PHP 的索引容器可序列化成对象或数组，空容器 [] 也是有效消息响应。
    const data: Record<string, Object> | undefined = this.asFields(root['data']);
    const error: Object | undefined = root['error'] ?? (data !== undefined ? data['error'] : undefined);
    const message: Object | undefined = (data !== undefined ? data['__MESSAGE'] : undefined) ?? root['__MESSAGE'];
    const errorText: string = this.serverMessage(error, '0');
    if (errorText.length > 0 || message !== undefined) {
      throw new Error(this.serverMessage(message, '1') || errorText || '服务器返回了接口错误');
    }
    const innerValue: Object | undefined = data !== undefined ? data['0'] : undefined;
    if (typeof innerValue === 'string') {
      // get_all 没有提醒时可返回状态文字，不能把它误报为损坏的列表。
      const statusText: string = innerValue.replace(/<[^>]*>/g, '').trim();
      console.info('[NGA.Messages] statusLength=' + statusText.length.toString() +
        ' rawLength=' + innerValue.length.toString());
      if (innerValue.trim().length === 0 ||
        /^(?:暂无|尚无|没有)(?:任何)?(?:新的?|未读)?(?:回复)?(?:提醒|通知|消息)[。！!]?$/i.test(statusText)) {
        console.info('[NGA.Messages] emptyStatus=true');
        return {};
      }
      throw new Error(statusText || '服务器响应缺少有效的消息数据');
    }
    const inner: Record<string, Object> | undefined = this.asFields(innerValue);
    // 仅记录容器类型和字段数量，帮助诊断协议；不记录消息或账号内容。
    console.info('[NGA.Messages] dataArray=' + Array.isArray(root['data']).toString() +
      ' innerType=' + (Array.isArray(innerValue) ? 'array' : typeof innerValue) +
      ' fields=' + (inner !== undefined ? Object.keys(inner).length.toString() : '0'));
    if (inner === undefined) {
      throw new Error('服务器响应缺少有效的消息数据');
    }
    return inner;
  }

  private serverMessage(value: Object | undefined, preferredKey: string): string {
    if (typeof value === 'string') {
      return value === '0' ? '' : value.replace(/<[^>]*>/g, '').trim();
    }
    if (typeof value === 'number') {
      return value === 0 ? '' : '接口错误（' + value.toString() + '）';
    }
    const fields: Record<string, Object> | undefined = this.asFields(value);
    if (fields !== undefined) {
      for (const key of [preferredKey, 'message', 'msg', '0', '1']) {
        const text: string = this.readString(fields[key]).replace(/<[^>]*>/g, '').trim();
        if (text.length > 0 && text !== '0') {
          return text;
        }
      }
      return '服务器返回了接口错误';
    }
    return value === true ? '服务器返回了接口错误' : '';
  }

  private asRecord(value: Object | undefined): Record<string, Object> | undefined {
    if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
      return undefined;
    }
    return value as Record<string, Object>;
  }

  private asFields(value: Object | undefined): Record<string, Object> | undefined {
    if (value === undefined || value === null || typeof value !== 'object') {
      return undefined;
    }
    return value as Record<string, Object>;
  }

  private readString(value: Object | undefined): string {
    return typeof value === 'string' ? value : '';
  }

  private readNumber(value: Object | undefined): number {
    if (typeof value === 'number') {
      return Number.isFinite(value) ? value : 0;
    }
    if (typeof value === 'string' && /^-?\d+$/.test(value.trim())) {
      const numberValue: number = Number(value);
      return Number.isFinite(numberValue) ? numberValue : 0;
    }
    return 0;
  }

  private indexedRows(value: Object | undefined): Object[] {
    if (value === undefined || value === null || value === '') {
      return [];
    }
    if (Array.isArray(value)) {
      return value as Object[];
    }
    const record: Record<string, Object> | undefined = this.asRecord(value);
    if (record === undefined) {
      throw new Error('服务器返回的消息列表格式异常');
    }
    const keys: string[] = Object.keys(record).filter((key: string): boolean => /^\d+$/.test(key));
    keys.sort((left: string, right: string): number => Number(left) - Number(right));
    const rows: Object[] = [];
    for (const key of keys) {
      rows.push(record[key]);
    }
    return rows;
  }

  /** data.0.0 是回复提醒列表，data.0.1 是短消息提醒，并非短消息线程列表。 */
  private parseNotificationResult(body: string): NotificationLoadResult {
    const result: NotificationLoadResult = new NotificationLoadResult();
    try {
      const inner: Record<string, Object> = this.responseInner(body);
      result.data.unread = this.readNumber(inner['unread']);
      const rows: Object[] = this.indexedRows(inner['0']);
      for (const item of rows) {
        const fields: Record<string, Object> | undefined = this.asFields(item);
        if (fields === undefined) {
          continue;
        }
        const reply: ReplyNotification = new ReplyNotification();
        reply.type = this.readNumber(fields['0']);
        reply.userId = this.readNumber(fields['1']);
        reply.userName = this.readString(fields['2']);
        reply.title = this.readString(fields['5']);
        reply.tid = this.readNumber(fields['6']);
        reply.pid = this.readNumber(fields['7'] ?? fields['8']);
        reply.timeStamp = this.readNumber(fields['9']);
        if (reply.tid > 0) {
          result.data.replyList.push(reply);
        }
      }
      if (rows.length > 0 && result.data.replyList.length === 0) {
        result.error = '服务器返回的回复提醒格式异常';
      } else {
        result.success = true;
      }
    } catch (error) {
      result.error = error instanceof SyntaxError ? '服务器响应解析失败，请重试' : (error as Error).message;
    }
    return result;
  }

  /** data.0 的数字键是短消息线程，nextPage 指示是否可以继续分页。 */
  private parseMessageResult(body: string): MessageLoadResult {
    const result: MessageLoadResult = new MessageLoadResult();
    try {
      const inner: Record<string, Object> = this.responseInner(body);
      const rows: Object[] = this.indexedRows(inner);
      result.hasPagination = inner['nextPage'] !== undefined;
      result.nextPage = this.readNumber(inner['nextPage']);
      for (const item of rows) {
        const fields: Record<string, Object> | undefined = this.asRecord(item);
        if (fields === undefined) {
          continue;
        }
        const message: MessageNotification = new MessageNotification();
        message.mid = this.readNumber(fields['mid']);
        message.subject = this.readString(fields['subject']);
        message.fromUserName = this.readString(fields['from_username']);
        message.lastFromUserName = this.readString(fields['last_from_username']);
        message.time = this.readNumber(fields['time']);
        message.lastModify = this.readNumber(fields['last_modify']);
        message.posts = this.readNumber(fields['posts']);
        if (message.mid > 0) {
          result.messages.push(message);
        }
      }
      if (rows.length > 0 && result.messages.length === 0) {
        result.error = '服务器返回的短消息列表格式异常';
      } else {
        result.success = true;
      }
    } catch (error) {
      result.error = error instanceof SyntaxError ? '服务器响应解析失败，请重试' : (error as Error).message;
    }
    return result;
  }

  private onReplyClick(reply: ReplyNotification): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ArticleListPage',
      params: { tid: reply.tid, title: reply.title }
    });
  }

  private onMessageClick(message: MessageNotification): void {
    if (!Number.isSafeInteger(message.mid) || message.mid <= 0) {
      this.getUIContext().getPromptAction().showToast({ message: '这条短消息暂时无法打开，请刷新列表后重试' });
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/MessageDetailPage',
      params: { mid: message.mid, subject: message.subject }
    });
  }

  /* ---------- 构建 ---------- */

  build() {
    Column() {
      if (this.showTitleBar) {
        this.TitleBar()
      }

      if (!this.loggedIn) {
        this.LoginView()
      } else {
        this.TabBar()

        if (this.isLoading && (this.currentTab === 0 ? this.replyList.length === 0 : this.messageList.length === 0)) {
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
        } else if (this.currentTab === 0) {
          if (this.replyList.length === 0) {
            this.EmptyView('暂无回复提醒')
          } else {
            this.ReplyListView()
          }
        } else {
          if (this.messageList.length === 0) {
            this.EmptyView('暂无短消息')
          } else {
            this.MessageListView()
          }
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  TitleBar() {
    Row() {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(24)
        .width(24)
        .height(24)
        .fontColor([this.mainTextColor()])
        .margin({ left: 16 })
        .onClick(() => {
          this.getUIContext().getRouter().back();
        })

      Text('消息')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.mainTextColor())
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .margin({ left: 12 })

      if (this.unread > 0) {
        Text(this.unread.toString())
          .fontSize(12)
          .fontColor(Color.White)
          .backgroundColor(COLOR_DAY_ERROR)
          .borderRadius(10)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ right: 16 })
      } else {
        Row()
          .width(40)
      }
    }
    .width('100%')
    .height(56)
    .backgroundColor(this.cardBg())
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  TabBar() {
    Row({ space: 8 }) {
      Row({ space: 4 }) {
        Button({ type: ButtonType.Capsule }) {
          Row({ space: 6 }) {
            Text('回复提醒').fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.currentTab === 0 ? this.accentTextColor() : this.subTextColor())
            if (this.unread > 0) {
              Text(this.unread > 99 ? '99+' : this.unread.toString()).fontSize(10).fontColor(Color.White)
                .padding({ left: 5, right: 5, top: 2, bottom: 2 }).borderRadius(10)
                .backgroundColor(this.accentColor())
            }
          }
        }
        .height(44).layoutWeight(1)
        .backgroundColor(this.currentTab === 0 ? this.cardBg() : Color.Transparent)
        .animation({ duration: 160, curve: Curve.EaseOut })
        .onClick(() => {
          if (this.currentTab !== 0) {
            this.currentTab = 0;
            this.refreshCurrentTab();
          }
        })

        Button('短消息', { type: ButtonType.Capsule })
          .height(44).layoutWeight(1).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.currentTab === 1 ? this.accentTextColor() : this.subTextColor())
          .backgroundColor(this.currentTab === 1 ? this.cardBg() : Color.Transparent)
          .animation({ duration: 160, curve: Curve.EaseOut })
          .onClick(() => {
            if (this.currentTab !== 1 || !this.messagesLoaded) {
              this.currentTab = 1;
              this.refreshCurrentTab();
            }
          })
      }
      .layoutWeight(1).padding(4).borderRadius(28)
      .backgroundColor(topicSecondarySurfaceColor(this.nightMode))

      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(20).fontColor([this.accentTextColor()])
      }
      .width(44).height(44).backgroundColor(this.cardBg())
      .accessibilityText('刷新消息').enabled(this.active && !this.isLoading)
      .onClick(() => this.refreshCurrentTab())
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 16, right: 16, top: 8, bottom: 16 })
    .backgroundColor(this.pageBg())
  }

  @Builder
  ErrorView() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.message')).fontSize(36).fontColor([this.subTextColor()])
      Text('消息暂时无法加载').fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.mainTextColor())
      Text(this.loadError)
        .fontSize(14)
        .fontColor(this.subTextColor())
        .textAlign(TextAlign.Center)

      Button('重试', { type: ButtonType.Capsule })
        .fontSize(16)
        .backgroundColor(this.accentColor())
        .fontColor('#ffffffff')
        .height(44)
        .padding({ left: 28, right: 28 })
        .enabled(this.active && !this.isLoading)
        .onClick(() => {
          this.refreshCurrentTab();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 24, right: 24, bottom: Math.max(24, this.contentBottomInset) })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  LoginView() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.message')).fontSize(40).fontColor([this.accentTextColor()])
      Text('消息中心').fontSize(20).fontWeight(FontWeight.Medium).fontColor(this.mainTextColor())
      Text('登录后查看回复提醒和短消息')
        .fontSize(16)
        .fontColor(this.subTextColor())
        .margin({ bottom: 16 })

      Button('登录', { type: ButtonType.Capsule })
        .fontSize(16)
        .backgroundColor(this.accentColor())
        .fontColor(Color.White)
        .height(44)
        .padding({ left: 32, right: 32 })
        .onClick(() => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/LoginPage' });
        })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 24, right: 24, bottom: Math.max(24, this.contentBottomInset) })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  EmptyView(msg: string) {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.message')).fontSize(36).fontColor([this.subTextColor()])
      Text(msg)
        .fontSize(16)
        .fontColor(this.subTextColor())
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 24, right: 24, bottom: Math.max(24, this.contentBottomInset) })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  ReplyListView() {
    List({ space: 8 }) {
      ForEach(this.replyList, (reply: ReplyNotification) => {
        ListItem() {
          this.ReplyItem(reply)
        }
      }, (reply: ReplyNotification) => (reply.tid.toString() + '_' + reply.pid.toString()))
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 16, right: 16 })
    .contentEndOffset(this.contentBottomInset + 24)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  ReplyItem(reply: ReplyNotification) {
    Column({ space: 10 }) {
      Row() {
        Text(reply.userName)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.accentTextColor())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.formatTime(reply.timeStamp))
          .fontSize(11)
          .fontColor(this.subTextColor())
      }
      .width('100%')

      Text(reply.title)
        .fontSize(16)
        .lineHeight(24)
        .fontColor(this.mainTextColor())
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.cardBg())
    .borderRadius(20)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onReplyClick(reply);
    })
  }

  @Builder
  MessageListView() {
    List({ space: 8 }) {
      ForEach(this.messageList, (msg: MessageNotification) => {
        ListItem() {
          this.MessageItem(msg)
        }
      }, (msg: MessageNotification) => msg.mid.toString())

      if (this.isLoading) {
        ListItem() {
          Row() {
            LoadingProgress()
              .width(24)
              .height(24)
              .color(this.accentTextColor())
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding(12)
        }
      } else if (!this.msgHasMore && this.messageList.length > 0) {
        ListItem() {
          Text('没有更多了')
            .fontSize(14)
            .fontColor(this.subTextColor())
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(16)
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 16, right: 16 })
    .contentEndOffset(this.contentBottomInset + 24)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onReachEnd(() => {
      if (this.active && this.currentTab === 1 && this.msgHasMore && !this.isLoading) {
        this.loadMessages(this.nextMessagePage);
      }
    })
  }

  @Builder
  MessageItem(msg: MessageNotification) {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Text(msg.subject)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .lineHeight(24)
          .fontColor(this.mainTextColor())
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([this.subTextColor()])
      }
      .width('100%')

      Row() {
        Text('来自 ' + msg.fromUserName)
          .fontSize(12)
          .fontColor(this.accentTextColor())
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.formatTime(msg.time))
          .fontSize(12)
          .fontColor(this.subTextColor())
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.cardBg())
    .borderRadius(20)
    .alignItems(HorizontalAlign.Start)
    .accessibilityText('查看短消息原文：' + msg.subject)
    .onClick(() => this.onMessageClick(msg))
  }

  private formatTime(timestamp: number): string {
    if (timestamp === 0) {
      return '';
    }
    // NGA 时间戳是 Unix 时间戳（秒）
    const date: Date = new Date(timestamp * 1000);
    const year: number = date.getFullYear();
    const month: number = date.getMonth() + 1;
    const day: number = date.getDate();
    const hour: number = date.getHours();
    const minute: number = date.getMinutes();
    return year.toString() + '-' + this.padZero(month) + '-' + this.padZero(day) + ' ' +
      this.padZero(hour) + ':' + this.padZero(minute);
  }

  private padZero(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }
}

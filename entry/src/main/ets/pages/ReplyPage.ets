/*
 * 回复/发帖页面（ReplyPage）。
 * 支持回复帖子和发新帖两种模式。
 * 对应 Android PostActivity + TopicPostFragment + TopicPostPresenter + TopicPostModel。
 *
 * 流程：
 * 1. 空 body POST 获取板块发帖上下文（文字提交无需附件 auth）
 * 2. 提交内容：POST post.php，body: step=2&post_content={GBK编码}&action={reply|new}&tid={tid}&fid={fid}
 * 3. 兼容安卓 HTML 反馈和 JSON __MESSAGE，仅明确发贴完毕后清空草稿
 */

import { common } from '@kit.AbilityKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { AppSubPage } from '../components/AppSubPage';
import { PostEmoticonPicker } from '../components/PostEmoticonPicker';
import { PostContentPreview } from '../components/PostContentPreview';
import {
  COLOR_ACCENT_BLUE,
  COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD,
  COLOR_DAY_TEXT, COLOR_NIGHT_TEXT, COLOR_DAY_SUB, COLOR_NIGHT_SUB,
  applyWindowTheme, themeAccentTextColor, themeErrorTextColor, themeSecondarySurfaceColor
} from '../model/AppTheme';
import { SettingsStore, SettingKeys, SettingDefaults } from '../model/AppSettings';
import { LoginStore } from '../model/LoginStore';
import { HttpClient } from '../model/HttpClient';
import { UrlBuilder } from '../model/UrlBuilder';
import { GbkEncoder } from '../model/GbkEncoder';
import { NgaTopicPostInput, TopicPostProtocol } from '../model/TopicPostProtocol';
import { NgaTopicPostPreparation, NgaTopicPostResult, TopicPostParser } from '../model/TopicPostParser';
import { NgaTopicPostDraft, TopicPostStore } from '../model/TopicPostStore';
import { PostEditorText, NgaPostEditorInsertion } from '../model/PostEditorText';
import { getEmoticonRawfilePath } from '../model/EmoticonUtils';
import { NgaTopicAttachment, NgaTopicAttachmentResult, TopicAttachmentProtocol } from '../model/TopicAttachmentProtocol';
import { TopicAttachmentUploader } from '../model/TopicAttachmentUploader';

@Entry
@Component
struct ReplyPage {
  @State nightMode: boolean = SettingDefaults.NIGHT;
  @State themeIndex: number = SettingDefaults.THEME;
  @State action: string = 'reply'; // reply | new | modify
  @State tid: number = 0;
  @State fid: number = 0;
  @State pid: number = 0;
  @State title: string = '';
  @State postContent: string = '';
  @State postSubject: string = ''; // 仅发新帖时使用
  @State anonymous: boolean = false;
  @State isSubmitting: boolean = false;
  @State submitResult: string = '';
  @State submitSuccess: boolean = false;
  @State stid: number = 0;
  @State submitUncertain: boolean = false;
  @State uncertainReviewed: boolean = false;
  @State contextInvalid: boolean = false;
  @State publishedTid: number = 0;
  @State showEmoticonSheet: boolean = false;
  @State showContentPreview: boolean = false;
  @State isAddingImages: boolean = false;
  @State mediaMessage: string = '';
  @State uploadedAttachments: NgaTopicAttachment[] = [];
  @State imagePreviews: Record<string, string> = {};

  private mounted: boolean = false;
  private sendVersion: number = 0;
  private activeAccountKey: string = '';
  private boardReviewPending: boolean = false;
  private publishedFid: number = 0;
  private keyboardAvoidMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET;
  private keyboardModeSet: boolean = false;
  private mediaVersion: number = 0;
  private selectionStart: number = 0;
  private selectionEnd: number = 0;
  private textController: TextAreaController = new TextAreaController();

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    this.mounted = true;
    this.keyboardAvoidMode = this.getUIContext().getKeyboardAvoidMode();
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.keyboardModeSet = true;
    SettingsStore.init(this.ctx);
    LoginStore.init(this.ctx);
    this.activeAccountKey = LoginStore.getUser().uid;
    this.nightMode = SettingsStore.getBool(SettingKeys.NIGHT, SettingDefaults.NIGHT);
    this.themeIndex = SettingsStore.getInt(SettingKeys.THEME, SettingDefaults.THEME);

    // 从路由参数获取帖子信息
    const params: Record<string, Object> = this.getUIContext().getRouter().getParams() as Record<string, Object>;
    if (params !== null && params !== undefined) {
      const actionVal: Object | undefined = params['action'];
      if (typeof actionVal === 'string') {
        this.action = actionVal;
      }
      const tidVal: Object | undefined = params['tid'];
      if (typeof tidVal === 'number') {
        this.tid = tidVal;
      }
      const fidVal: Object | undefined = params['fid'];
      if (typeof fidVal === 'number') {
        this.fid = fidVal;
      }
      const stidVal: Object | undefined = params['stid'];
      if (typeof stidVal === 'number') { this.stid = stidVal; }
      const pidVal: Object | undefined = params['pid'];
      if (typeof pidVal === 'number') {
        this.pid = pidVal;
      }
      const titleVal: Object | undefined = params['title'];
      if (typeof titleVal === 'string') {
        this.title = titleVal;
      }
    }
    const draft: NgaTopicPostDraft = TopicPostStore.load(this.activeAccountKey,
      this.action, this.fid, this.stid, this.tid, this.pid);
    this.postSubject = draft.subject;
    this.postContent = draft.content;
    this.uploadedAttachments = draft.attachments;
    this.selectionStart = this.postContent.length;
    this.selectionEnd = this.selectionStart;
    this.anonymous = draft.anonymous;
    this.submitUncertain = draft.uncertain;
    if (draft.uncertain) {
      this.submitResult = '上次发布结果未确认，草稿已保留。请先查看板块，避免重复发布';
    }
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

  private pageTitle(): string {
    if (this.action === 'new') {
      return '发表话题';
    }
    if (this.action === 'modify') {
      return '修改帖子';
    }
    return '回复帖子';
  }

  /* ---------- 提交逻辑 ---------- */

  onPageShow(): void {
    if (!this.mounted) { return; }
    this.nightMode = SettingsStore.getBool(SettingKeys.NIGHT, SettingDefaults.NIGHT);
    applyWindowTheme(this.ctx, this.nightMode);
    if (LoginStore.getUser().uid !== this.activeAccountKey || !LoginStore.hasUser()) {
      this.sendVersion++;
      this.mediaVersion++;
      this.isSubmitting = false;
      this.isAddingImages = false;
      this.showEmoticonSheet = false;
      this.contextInvalid = true;
      this.postSubject = '';
      this.postContent = '';
      this.uploadedAttachments = [];
      this.imagePreviews = {};
      this.anonymous = false;
      this.submitResult = '登录状态已变化，请返回板块重新打开发帖页面';
      return;
    }
    if (this.boardReviewPending) {
      this.boardReviewPending = false;
      this.uncertainReviewed = true;
    }
  }

  aboutToDisappear(): void {
    this.saveDraft();
    this.imagePreviews = {};
    this.mounted = false;
    this.sendVersion++;
    this.mediaVersion++;
    if (this.keyboardModeSet) {
      this.getUIContext().setKeyboardAvoidMode(this.keyboardAvoidMode);
      this.keyboardModeSet = false;
    }
  }

  private saveDraft(): void {
    if (this.submitSuccess || this.contextInvalid || this.activeAccountKey.length === 0) { return; }
    const draft: NgaTopicPostDraft = new NgaTopicPostDraft();
    draft.subject = this.postSubject;
    draft.content = this.postContent;
    draft.anonymous = this.anonymous;
    draft.uncertain = this.submitUncertain;
    draft.attachments = this.uploadedAttachments;
    TopicPostStore.save(this.activeAccountKey, this.action, this.fid, this.stid, this.tid, this.pid, draft);
  }

  private postInput(): NgaTopicPostInput {
    const input: NgaTopicPostInput = new NgaTopicPostInput();
    input.action = this.action;
    input.fid = this.fid;
    input.stid = this.stid;
    input.tid = this.tid;
    input.pid = this.pid;
    input.subject = this.postSubject;
    input.content = this.postContent;
    input.anonymous = this.anonymous;
    input.attachments = this.uploadedAttachments;
    return input;
  }

  private canEdit(): boolean {
    return this.mounted && !this.isSubmitting && !this.isAddingImages && !this.contextInvalid &&
      !this.submitUncertain && !this.submitSuccess;
  }

  private insertContent(markup: string): void {
    if (!this.mounted || this.isSubmitting || this.contextInvalid || this.submitUncertain || this.submitSuccess) { return; }
    const inserted: NgaPostEditorInsertion = PostEditorText.insert(this.postContent,
      this.selectionStart, this.selectionEnd, markup);
    this.postContent = inserted.content;
    this.selectionStart = inserted.caret;
    this.selectionEnd = inserted.caret;
    this.saveDraft();
  }

  private insertEmoticon(code: string): void {
    if (!this.canEdit()) { return; }
    const parts: RegExpMatchArray | null = code.match(/^\[s:([a-z0-9]+):([^\]\r\n]+)\]$/i);
    if (parts === null || getEmoticonRawfilePath(parts[1], parts[2]).length === 0) { return; }
    this.insertContent(code);
  }

  private openEmoticons(): void {
    if (!this.canEdit()) { return; }
    this.showEmoticonSheet = true;
    this.textController.stopEditing();
  }

  private restoreEditorCaret(): void {
    if (!this.canEdit() || this.showEmoticonSheet) { return; }
    setTimeout(() => {
      if (this.canEdit() && !this.showEmoticonSheet) { this.textController.caretPosition(this.selectionEnd); }
    }, 0);
  }

  private isCurrentMedia(version: number, accountKey: string): boolean {
    return this.mounted && this.mediaVersion === version && !this.contextInvalid && !this.submitSuccess &&
      this.activeAccountKey === accountKey && LoginStore.hasUser() && LoginStore.getUser().uid === accountKey;
  }

  /** 当前编辑页面的有限缩略图缓存，不进入草稿、上传回执或发帖字段。 */
  private rememberImagePreview(attachment: NgaTopicAttachment, source: string): void {
    if (!TopicAttachmentProtocol.isValidAttachment(attachment) || typeof source !== 'string' ||
      source.length > 256 * 1024 || source.endsWith(',') ||
      !/^data:image\/(?:png|jpe?g);base64,(?:[a-z0-9+/]{4})*(?:[a-z0-9+/]{2}==|[a-z0-9+/]{3}=)?$/i.test(source)) { return; }
    const url: string = 'https://img.nga.cn/attachments/' + attachment.url;
    const updated: Record<string, string> = {};
    const keys: string[] = Object.keys(this.imagePreviews).filter((key: string): boolean => key !== url).slice(-11);
    for (const key of keys) { updated[key] = this.imagePreviews[key]; }
    updated[url] = source;
    this.imagePreviews = updated;
  }

  private async addImages(): Promise<void> {
    if (!this.canEdit()) { return; }
    if (!LoginStore.hasUser() || LoginStore.getUser().uid !== this.activeAccountKey) {
      this.mediaMessage = '请先登录，再选择图片';
      return;
    }
    const version: number = ++this.mediaVersion;
    const accountKey: string = this.activeAccountKey;
    this.saveDraft();
    this.isAddingImages = true;
    this.mediaMessage = '';
    this.textController.stopEditing();
    let insertedCount: number = 0;
    const errors: string[] = [];
    try {
      const options: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 6;
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const selected: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      if (!this.isCurrentMedia(version, accountKey)) { return; }
      const uris: string[] = selected.photoUris.slice(0, 6);
      for (let index: number = 0; index < uris.length; index++) {
        this.mediaMessage = '正在上传图片 ' + (index + 1).toString() + ' / ' + uris.length.toString();
        const result: NgaTopicAttachmentResult = await TopicAttachmentUploader.upload(uris[index], this.postInput(),
          (): boolean => this.isCurrentMedia(version, accountKey));
        if (!this.isCurrentMedia(version, accountKey)) { return; }
        if (!result.success) {
          errors.push(result.errorMessage || '图片上传失败');
          continue;
        }
        this.uploadedAttachments = this.uploadedAttachments.concat([result.attachment]);
        this.insertContent(TopicAttachmentProtocol.buildMarkup(result.attachment) + '\n');
        this.rememberImagePreview(result.attachment, result.previewSource);
        insertedCount++;
      }
      this.mediaMessage = errors.length > 0 ?
        (insertedCount > 0 ? '已插入 ' + insertedCount.toString() + ' 张图片；' : '') + errors[0] :
        (insertedCount > 0 ? '已插入 ' + insertedCount.toString() + ' 张图片' : '');
    } catch (error) {
      if (this.isCurrentMedia(version, accountKey)) {
        this.mediaMessage = '图片选择或上传未完成，请重试';
      }
    } finally {
      if (this.mounted && this.mediaVersion === version) {
        this.isAddingImages = false;
        this.saveDraft();
        this.restoreEditorCaret();
      }
    }
  }

  private isCurrentSend(version: number, accountKey: string): boolean {
    return this.mounted && this.sendVersion === version && !this.contextInvalid &&
      this.activeAccountKey === accountKey && LoginStore.hasUser() && LoginStore.getUser().uid === accountKey;
  }

  private async submitPost(): Promise<void> {
    if (!this.mounted || this.isSubmitting || this.isAddingImages || this.submitSuccess || this.submitUncertain) { return; }
    if (this.contextInvalid || !LoginStore.hasUser() || LoginStore.getUser().uid !== this.activeAccountKey) {
      this.submitResult = '请先登录，再返回板块打开发帖页面';
      return;
    }
    const input: NgaTopicPostInput = this.postInput();
    const validation: string = TopicPostProtocol.validate(input);
    if (validation.length > 0) { this.submitResult = validation; return; }
    try {
      GbkEncoder.encode(input.content);
      if (input.subject.length > 0) { GbkEncoder.encode(input.subject); }
    } catch (error) {
      this.submitResult = (error as Error).message || '内容含有暂不支持的字符，请修改后重试';
      return;
    }
    const version: number = ++this.sendVersion;
    const accountKey: string = this.activeAccountKey;
    this.isSubmitting = true;
    this.submitResult = '';
    this.saveDraft();
    let submitted: boolean = false;
    try {
      // 安卓以空 body POST 获取发帖上下文，附件 auth 不属于文字提交字段。
      const prepare = await HttpClient.post(TopicPostProtocol.buildPrepareUrl(input), {}, true);
      if (!this.isCurrentSend(version, accountKey)) { return; }
      if (!prepare.success) {
        this.submitResult = '发帖信息加载失败，请检查网络后重试';
        return;
      }
      const preparation: NgaTopicPostPreparation = TopicPostParser.parsePreparation(prepare.body, input.fid, input.stid);
      if (!preparation.success) {
        this.submitResult = preparation.errorMessage || '无法进入发帖，请稍后重试';
        return;
      }
      if (input.fid === 0 && preparation.fid !== 0) { input.fid = preparation.fid; }
      submitted = true;
      this.submitUncertain = true;
      this.saveDraft();
      const response = await HttpClient.post(UrlBuilder.buildPostSubmitUrl(), TopicPostProtocol.buildFields(input), true);
      if (!this.isCurrentSend(version, accountKey)) { return; }
      if (!response.success) { this.reportUncertain(); return; }
      const feedback: NgaTopicPostResult = TopicPostParser.parseSubmit(response.body);
      if (!feedback.success) {
        this.submitUncertain = feedback.uncertain;
        this.submitResult = feedback.errorMessage || '发布失败，草稿已保留';
        return;
      }
      TopicPostStore.remove(accountKey, this.action, this.fid, this.stid, this.tid, this.pid);
      if (this.action === 'new') { TopicPostStore.markPublished(accountKey, this.fid, this.stid); }
      this.publishedTid = feedback.tid;
      this.publishedFid = input.fid;
      this.submitUncertain = false;
      this.submitSuccess = true;
      this.postSubject = '';
      this.postContent = '';
      this.uploadedAttachments = [];
      this.imagePreviews = {};
      this.submitResult = this.action === 'new' ? '话题发布成功' : '发送成功';
    } catch (error) {
      if (this.isCurrentSend(version, accountKey)) {
        if (submitted) { this.reportUncertain(); }
        else { this.submitResult = '发帖信息加载失败，请检查网络后重试'; }
      }
    } finally {
      if (this.mounted && this.sendVersion === version) {
        this.isSubmitting = false;
        this.saveDraft();
      }
    }
  }

  private reportUncertain(): void {
    this.submitUncertain = true;
    this.uncertainReviewed = false;
    this.submitResult = '发布结果未确认，草稿已保留。请先查看是否已出现该内容，避免重复发布';
  }

  private async viewCurrentBoard(): Promise<void> {
    if (this.isSubmitting || this.isAddingImages || this.contextInvalid) { return; }
    this.saveDraft();
    try {
      this.boardReviewPending = true;
      if (this.action === 'new') {
        await this.getUIContext().getRouter().pushUrl({
          url: 'pages/TopicListPage', params: { fid: this.fid, stid: this.stid, title: this.title }
        });
      } else {
        await this.getUIContext().getRouter().pushUrl({
          url: 'pages/ArticleListPage', params: { fid: this.fid, tid: this.tid, title: this.title }
        });
      }
    } catch (error) {
      this.boardReviewPending = false;
      this.getUIContext().getPromptAction().showToast({ message: '页面打开失败，请重试' });
    }
  }

  private async confirmRetry(): Promise<void> {
    if (!this.submitUncertain || !this.uncertainReviewed || this.isSubmitting || this.contextInvalid) { return; }
    const accountKey: string = this.activeAccountKey;
    try {
      const decision = await this.getUIContext().getPromptAction().showDialog({
        title: '确认重新发布？', message: '请确认刚才的内容没有发布成功。重新发布可能产生重复内容。',
        buttons: [
          { text: '继续保留草稿', color: this.subTextColor() },
          { text: '确认未发布', color: this.accentTextColor() }
        ]
      });
      if (decision.index === 1 && this.isCurrentSend(this.sendVersion, accountKey)) {
        this.submitUncertain = false;
        this.uncertainReviewed = false;
        this.submitResult = '';
        this.saveDraft();
      }
    } catch (error) { return; }
  }

  private async navigateBack(): Promise<void> {
    if (this.isSubmitting || this.isAddingImages) {
      this.getUIContext().getPromptAction().showToast({ message: this.isAddingImages ? '正在处理图片，请稍候' : '正在发布，请稍候' });
      return;
    }
    if (!this.submitSuccess && !this.contextInvalid && (this.postSubject.length > 0 || this.postContent.length > 0)) {
      try {
        const decision = await this.getUIContext().getPromptAction().showDialog({
          title: '保存草稿并返回？', message: '本次使用期间，再次进入相同板块可继续编辑。',
          buttons: [
            { text: '继续编辑', color: this.accentTextColor() },
            { text: '保存并返回', color: this.subTextColor() }
          ]
        });
        if (!this.mounted || decision.index !== 1 || this.isSubmitting) { return; }
        this.saveDraft();
      } catch (error) { return; }
    }
    this.getUIContext().getRouter().back();
  }

  onBackPress(): boolean {
    this.navigateBack();
    return true;
  }

  private async viewPublishedTopic(): Promise<void> {
    if (!this.submitSuccess || this.publishedTid <= 0) { return; }
    try {
      await this.getUIContext().getRouter().replaceUrl({
        url: 'pages/ArticleListPage', params: { tid: this.publishedTid, fid: this.publishedFid }
      });
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: '话题打开失败，可返回板块查看' });
    }
  }

  /* ---------- 构建 ---------- */

  build() {
    Column() {
      AppSubPage({ pageTitle: this.pageTitle(), nightMode: this.nightMode, pageBackground: this.pageBg(),
        onNavigateBack: () => this.navigateBack() }) {
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

      if (this.submitSuccess) {
        this.SuccessView()
      } else {
        this.EditView()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pageBg())
  }

  @Builder
  EditView() {
    Scroll() {
      Column({ space: 16 }) {
        if (this.action === 'new' && this.title.length > 0) {
          Column({ space: 6 }) {
            Text('发布到').fontSize(12).fontColor(this.subTextColor())
            Text(this.title).fontSize(17).fontWeight(FontWeight.Medium)
              .fontColor(this.mainTextColor()).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%').alignItems(HorizontalAlign.Start).padding(16)
          .borderRadius(20).backgroundColor(themeSecondarySurfaceColor(this.nightMode))
        }
        if (this.action === 'new') {
          Column({ space: 8 }) {
            Text('话题标题').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.mainTextColor())
            TextInput({ placeholder: '用一句话说明你的话题', text: this.postSubject })
              .fontSize(17).fontColor(this.mainTextColor()).placeholderColor(this.subTextColor())
              .caretColor(this.accentTextColor()).width('100%').height(52)
              .backgroundColor(this.cardBg()).borderRadius(16).padding({ left: 14, right: 14 })
              .enabled(this.canEdit())
              .onChange((text: string) => { this.postSubject = text; this.saveDraft(); })
          }
          .width('100%').alignItems(HorizontalAlign.Start)
        }
        if (this.action === 'reply' && this.title.length > 0) {
          Text('回复：' + this.title).fontSize(14).fontColor(this.subTextColor()).width('100%')
        }
        Column({ space: 8 }) {
          Text('正文').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.mainTextColor())
          TextArea({ placeholder: '分享你的想法…', text: this.postContent, controller: this.textController })
            .fontSize(16).fontColor(this.mainTextColor()).placeholderColor(this.subTextColor())
            .caretColor(this.accentTextColor()).width('100%').height(260)
            .backgroundColor(this.cardBg()).borderRadius(20).padding(16)
            .id('post-content-input')
            .enabled(this.canEdit())
            .onChange((text: string) => { this.postContent = text; this.saveDraft(); })
            .onTextSelectionChange((start: number, end: number) => {
              if (!this.showEmoticonSheet && !this.isAddingImages) {
                this.selectionStart = start;
                this.selectionEnd = end;
              }
            })
          this.EditorMediaActions()
          if (this.mediaMessage.length > 0) {
            Row({ space: 8 }) {
              if (this.isAddingImages) {
                LoadingProgress().width(18).height(18).color(this.accentTextColor())
              }
              Text(this.mediaMessage).fontSize(13).fontColor(this.subTextColor()).layoutWeight(1)
            }
            .width('100%').padding({ left: 4, right: 4 })
          }
          if (this.showContentPreview && this.postContent.length > 0) {
            Column({ space: 10 }) {
              Text('正文预览').fontSize(13).fontColor(this.subTextColor())
              PostContentPreview({ content: this.postContent, nightMode: this.nightMode, imagePreviews: this.imagePreviews })
            }
            .width('100%').alignItems(HorizontalAlign.Start).padding(16)
            .backgroundColor(this.cardBg()).borderRadius(20)
          }
        }
        .width('100%').alignItems(HorizontalAlign.Start)
        Row({ space: 8 }) {
          Checkbox().select(this.anonymous).selectedColor(this.accentColor())
            .unselectedColor(this.subTextColor()).width(22).height(22)
            .enabled(this.canEdit())
            .onChange((checked: boolean) => { this.anonymous = checked; this.saveDraft(); })
          Text('匿名发布').fontSize(14).fontColor(this.mainTextColor())
          Text('需板块支持').fontSize(12).fontColor(this.subTextColor())
        }
        .width('100%').padding({ top: 4, bottom: 4 })
        if (this.submitResult.length > 0) {
          Text(this.submitResult).fontSize(14).fontColor(themeErrorTextColor(this.nightMode))
            .width('100%').padding(14).borderRadius(16)
            .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
        }
        if (this.submitUncertain) {
          Button(this.action === 'new' ? '查看当前板块' : '查看话题', { type: ButtonType.Capsule })
            .fontSize(16).width('100%').height(48).fontColor(this.accentTextColor())
            .backgroundColor(themeSecondarySurfaceColor(this.nightMode)).enabled(!this.isSubmitting)
            .onClick(() => this.viewCurrentBoard())
          if (this.uncertainReviewed) {
            Button('已核对，确认未发布', { type: ButtonType.Capsule })
              .fontSize(15).width('100%').height(48).fontColor(this.accentTextColor())
              .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
              .onClick(() => this.confirmRetry())
          }
        }
        Button(this.isSubmitting ? '发布中…' : (this.action === 'new' ? '发布话题' : '发送'),
          { type: ButtonType.Capsule })
          .fontSize(17).fontWeight(FontWeight.Medium).width('100%').height(50)
          .backgroundColor(this.accentColor()).fontColor(Color.White)
          .enabled(this.canEdit())
          .onClick(() => this.submitPost())
      }
      .width('100%').padding({ left: 16, right: 16, top: 16, bottom: 24 })
    }
    .width('100%').layoutWeight(1).align(Alignment.TopStart).scrollBar(BarState.Off)
  }

  @Builder
  EditorMediaActions() {
    Row({ space: 8 }) {
      Button('表情', { type: ButtonType.Capsule })
        .height(44).fontSize(14).fontColor(this.accentTextColor())
        .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
        .id('post-emoticon-button').accessibilityText('插入表情').enabled(this.canEdit())
        .onClick(() => this.openEmoticons())
        .bindSheet($$this.showEmoticonSheet, this.EmoticonSheet, {
          height: SheetSize.MEDIUM, title: { title: '插入表情' },
          backgroundColor: this.cardBg(), dragBar: true, showClose: true,
          onDisappear: () => this.restoreEditorCaret()
        })
      Button(this.isAddingImages ? '上传中…' : '图片', { type: ButtonType.Capsule })
        .height(44).fontSize(14).fontColor(this.accentTextColor())
        .backgroundColor(themeSecondarySurfaceColor(this.nightMode))
        .id('post-image-button').accessibilityText('选择并插入图片').enabled(this.canEdit())
        .onClick(() => this.addImages())
      Blank()
      Button(this.showContentPreview ? '收起预览' : '预览', { type: ButtonType.Capsule })
        .height(44).fontSize(14).fontColor(this.accentTextColor()).backgroundColor(Color.Transparent)
        .id('post-preview-button').enabled(this.postContent.length > 0 && !this.contextInvalid)
        .onClick(() => { this.showContentPreview = !this.showContentPreview; })
    }
    .width('100%')
  }

  @Builder
  EmoticonSheet() {
    PostEmoticonPicker({ nightMode: this.nightMode, onSelect: (code: string): void => this.insertEmoticon(code) })
  }

  @Builder
  SuccessView() {
    Column() {
      Text(this.submitResult)
        .fontSize(18)
        .fontColor(this.accentTextColor())
        .margin({ bottom: 24 })

      if (this.action === 'new' && this.publishedTid > 0) {
        Button('查看话题', { type: ButtonType.Capsule })
          .fontSize(16).backgroundColor(this.accentColor()).fontColor(Color.White)
          .width('60%').height(48).margin({ bottom: 12 })
          .onClick(() => this.viewPublishedTopic())
      }
      Button(this.action === 'new' ? '返回板块' : '返回话题', { type: ButtonType.Capsule })
        .fontSize(16)
        .backgroundColor(this.accentColor())
        .fontColor('#ffffffff')
        .width('60%')
        .height(44)
        .onClick(() => {
          this.navigateBack();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}

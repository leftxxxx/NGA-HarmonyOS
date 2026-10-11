import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ArticleBody } from './ArticleBody';
import { themeAccentTextColor, COLOR_DAY_CARD, COLOR_NIGHT_CARD, COLOR_DAY_TEXT, COLOR_NIGHT_TEXT } from '../model/AppTheme';
import { renderArticleContent } from '../model/ArticleHtml';
import { HttpClient } from '../model/HttpClient';

/** 复用话题正文的白名单渲染，预览表情及上传图片，不执行正文脚本。 */
@Component
export struct PostContentPreview {
  @Prop content: string = '';
  @Prop nightMode: boolean = false;
  @Prop imagePreviews: Record<string, string> = {};
  private sources: Map<string, string> = new Map<string, string>();
  private base64: util.Base64Helper = new util.Base64Helper();

  private surfaceColor(): string {
    return this.nightMode ? COLOR_NIGHT_CARD : COLOR_DAY_CARD;
  }

  private localSource(path: string): string {
    const cached: string | undefined = this.sources.get(path);
    if (cached !== undefined) { return cached; }
    let source: string = '';
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(path);
      source = 'data:image/' + (path.endsWith('.gif') ? 'gif' : 'png') + ';base64,' +
        this.base64.encodeToStringSync(bytes);
    } catch (error) { return ''; }
    this.sources.set(path, source);
    return source;
  }

  private htmlContent(): string {
    const surface: string = '#' + this.surfaceColor().substring(3);
    const foreground: string = '#' + (this.nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT).substring(3);
    const accent: string = '#' + themeAccentTextColor(this.nightMode).substring(3);
    const body: string = renderArticleContent(this.content, 'https://img.nga.cn/attachments/',
      (path: string): string => this.localSource(path), HttpClient.getDomain() + '/',
      (url: string): string => this.imagePreviews[url] ?? '');
    return '<!DOCTYPE html><html><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width,initial-scale=1.0"><style>' +
      'html,body{background:' + surface + ';color:' + foreground + ';font-size:16px;line-height:1.7;' +
      'margin:0;padding:0;overflow-wrap:anywhere;}img{max-width:100%;height:auto;}' +
      'img.article-image{display:block;margin:12px 0;border-radius:12px;}' +
      'img.emoticon{height:1.5em;width:auto;vertical-align:middle;display:inline-block;}' +
      'blockquote{margin:8px 0;padding:8px;border-left:3px solid ' + accent + ';}a{color:' + accent + ';}' +
      (this.nightMode ? 'img.invertFilter{filter:invert(100%);}' : '') +
      '</style></head><body>' + body + '</body></html>';
  }

  build() {
    ArticleBody({ html: this.htmlContent(), bodyBackground: this.surfaceColor(), baseUrl: HttpClient.getDomain() + '/' })
  }
}

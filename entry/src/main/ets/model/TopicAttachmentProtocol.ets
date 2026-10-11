import { NgaJsonParser } from './NgaJsonParser';
import { TopicPostParser, NgaTopicPostPreparation } from './TopicPostParser';
import { TopicAttachmentLiteral } from './TopicAttachmentLiteral';

/** NGA 附件回执；只保存发帖所需的信息，不保存上传鉴权或本地图片地址。 */
export class NgaTopicAttachment {
  url: string = '';
  attachments: string = '';
  attachmentsCheck: string = '';
}

export class NgaTopicAttachmentResult {
  success: boolean = false;
  errorMessage: string = '';
  failureStage: string = '';
  /** 当前编辑会话的临时预览，不属于附件回执、草稿或提交字段。 */
  previewSource: string = '';
  attachment: NgaTopicAttachment = new NgaTopicAttachment();
}

export class NgaTopicAttachmentPreparation {
  success: boolean = false;
  errorMessage: string = '';
  auth: string = '';
  fid: number = 0;
}

/** 对照安卓 TopicPostModel/PostParam 的附件协议；回包只作为数据解析。 */
export class TopicAttachmentProtocol {
  static readonly ENDPOINT: string = 'https://img8.nga.cn/attach.php?';
  // 客户端读取上限用于控制内存；论坛实际额度由服务器鉴权和 error_code=9 决定。
  static readonly MAX_FILE_BYTES: number = 10 * 1024 * 1024;
  static readonly COMPRESS_TARGET_BYTES: number = 1024 * 1024;

  static parsePreparation(body: string, requestedFid: number,
    requestedStid: number): NgaTopicAttachmentPreparation {
    const result: NgaTopicAttachmentPreparation = new NgaTopicAttachmentPreparation();
    const context: NgaTopicPostPreparation = TopicPostParser.parsePreparation(body, requestedFid, requestedStid);
    if (!context.success) {
      result.errorMessage = context.errorMessage;
      return result;
    }
    try {
      const root: Record<string, Object> = NgaJsonParser.parseResponseObject(body);
      const data: Record<string, Object> | undefined = TopicAttachmentProtocol.asFields(root['data']);
      const auth: Object | undefined = data !== undefined ? data['auth'] : undefined;
      if (typeof auth !== 'string' || auth.trim().length === 0 || auth.length > 4096 ||
        new RegExp('[\\x00-\\x1f\\x7f]').test(auth)) {
        result.errorMessage = '服务器未返回图片上传授权，请稍后重试';
        return result;
      }
      result.fid = context.fid;
      result.auth = auth;
      result.success = true;
    } catch (error) {
      result.errorMessage = '图片上传授权解析失败，请重试';
    }
    return result;
  }

  static parseUpload(body: string): NgaTopicAttachmentResult {
    const result: NgaTopicAttachmentResult = new NgaTopicAttachmentResult();
    try {
      const root: Record<string, Object> = TopicAttachmentLiteral.parseResponse(body);
      const data: Record<string, Object> | undefined = TopicAttachmentProtocol.asFields(root['data']);
      const rejection: string = TopicAttachmentProtocol.readError(root, data);
      if (rejection.length > 0) {
        result.failureStage = 'server';
        result.errorMessage = rejection;
        return result;
      }
      if (data === undefined || !TopicAttachmentProtocol.isToken(data['attachments']) ||
        !TopicAttachmentProtocol.isToken(data['attachments_check'])) {
        result.failureStage = 'receipt';
        result.errorMessage = '服务器未确认图片上传，正文已保留，请重试';
        return result;
      }
      const url: string = typeof data['url'] === 'string' ? data['url'] as string : '';
      const attachment: NgaTopicAttachment = new NgaTopicAttachment();
      attachment.url = url.replace(new RegExp('^\\./'), '');
      attachment.attachments = data['attachments'] as string;
      attachment.attachmentsCheck = data['attachments_check'] as string;
      if (!TopicAttachmentProtocol.isValidAttachment(attachment)) {
        result.failureStage = 'receipt';
        result.errorMessage = '服务器返回的图片信息无效，请重试';
        return result;
      }
      result.attachment = attachment;
      result.success = true;
    } catch (error) {
      result.failureStage = 'json';
      result.errorMessage = '服务器返回了无法识别的图片上传结果，请稍后重试';
    }
    return result;
  }

  /** 只描述包装、字段类型和白名单键名；值、地址、鉴权和回执永不进入日志。 */
  static describeUpload(body: string): string {
    const source: string = body.trim();
    const shape: string = source.length === 0 ? 'empty' : source.startsWith('{') ? 'json-object' :
      source.startsWith('[') ? 'json-array' : source.startsWith('<') ? 'html' :
      new RegExp('^(?:/\\*\\$js\\$\\*/\\s*)*window\\.script_muti_get_var_store\\s*=').test(source) ?
        'nga-assignment' : new RegExp('^[a-zA-Z_$][a-zA-Z0-9_$.]*\\s*=').test(source) ?
        'assignment' : source.startsWith('/*') ? 'comment' : 'other';
    const wrapper: string = source.startsWith('<') && new RegExp('<script\\b', 'i').test(source) ?
      'html-script' : shape === 'nga-assignment' ? 'nga-js' : shape === 'assignment' ?
        'other-js' : shape === 'comment' ? 'comment' : 'raw';
    let summary: string = 'shape=' + shape + ' wrapper=' + wrapper;
    try {
      const root: Record<string, Object> = TopicAttachmentLiteral.parseResponse(body);
      const data: Record<string, Object> | undefined = TopicAttachmentProtocol.asFields(root['data']);
      summary += ' json=true root=object rootKeys=' + TopicAttachmentProtocol.safeKeys(root) +
        ' data=' + TopicAttachmentProtocol.payloadKind(root['data']) +
        ' dataKeys=' + (data !== undefined ? TopicAttachmentProtocol.safeKeys(data) : 'none');
      const rootCode: number = TopicAttachmentProtocol.numericErrorCode(root['error_code']);
      const dataCode: number = data !== undefined ? TopicAttachmentProtocol.numericErrorCode(data['error_code']) : 0;
      summary += ' errorCode=' + (rootCode !== 0 ? rootCode : dataCode).toString();
    } catch (error) {
      summary += ' json=false root=unparsed rootKeys=none data=unparsed dataKeys=none errorCode=0';
    }
    return summary;
  }

  private static safeKeys(fields: Record<string, Object>): string {
    const allowed: string[] = ['data', 'url', 'attachments', 'attachments_check', 'error_code', 'error', 'error_txt', 'encode',
      '__ERROR', '__MESSAGE', 'message', 'msg', '0', '1', '2', '3', '4', '5'];
    const known: string[] = [];
    let omitted: number = 0;
    for (const key of Object.keys(fields)) {
      if (allowed.includes(key)) {
        known.push(key);
      } else {
        omitted++;
      }
    }
    known.sort();
    return (known.length > 0 ? known.join(',') : 'none') + '+other:' + omitted.toString();
  }

  private static payloadKind(payload: Object | undefined): string {
    if (payload === undefined) { return 'missing'; }
    if (payload === null) { return 'null'; }
    if (Array.isArray(payload)) { return 'array'; }
    if (typeof payload === 'string') { return 'string'; }
    if (typeof payload === 'number') { return 'number'; }
    if (typeof payload === 'boolean') { return 'boolean'; }
    return 'object';
  }

  private static numericErrorCode(payload: Object | undefined): number {
    if (typeof payload !== 'number' && (typeof payload !== 'string' || !new RegExp('^-?[0-9]{1,8}$').test(payload))) {
      return 0;
    }
    const parsed: number = Number(payload);
    return Number.isSafeInteger(parsed) && Math.abs(parsed) <= 99999999 ? parsed : 0;
  }

  static isValidAttachment(attachment: NgaTopicAttachment): boolean {
    return attachment.url.length <= 1024 &&
      new RegExp('^mon_[0-9]{6}/[0-9]{2}/[a-zA-Z0-9_-][a-zA-Z0-9_.-]*\\.(?:jpe?g|png|gif|webp)$', 'i')
        .test(attachment.url) && !attachment.url.includes('..') &&
      TopicAttachmentProtocol.isToken(attachment.attachments) &&
      TopicAttachmentProtocol.isToken(attachment.attachmentsCheck);
  }

  static buildMarkup(attachment: NgaTopicAttachment): string {
    return TopicAttachmentProtocol.isValidAttachment(attachment) ? '[img]./' + attachment.url + '[/img]' : '';
  }

  /** 手动调整图片大小或标签大小写后，仍按实际图片路径关联上传回执。 */
  static isReferenced(content: string, attachment: NgaTopicAttachment): boolean {
    if (!TopicAttachmentProtocol.isValidAttachment(attachment)) { return false; }
    const body: string = content.replace(/\[code(?:=[^\]]*)?\][\s\S]*?\[\/code\]/gi, '');
    const images: RegExp = /\[img(?:\d{1,3}|=[^\]]*)?\]([^\[\]\r\n]+)\[\/img\]/gi;
    let match: RegExpExecArray | null = images.exec(body);
    while (match !== null) {
      const path: string = match[1].trim().replace(/^\.\//, '');
      if (path === attachment.url || path === 'https://img.nga.cn/attachments/' + attachment.url ||
        path === 'https://img8.nga.cn/attachments/' + attachment.url) { return true; }
      match = images.exec(body);
    }
    return false;
  }

  /** 根据文件签名识别图片，不能仅凭文件名把其他文件作为图片上传。 */
  static detectImageType(content: ArrayBuffer): string {
    const bytes: Uint8Array = new Uint8Array(content);
    if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e &&
      bytes[3] === 0x47 && bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a) {
      return 'image/png';
    }
    if (bytes.length >= 6 && TopicAttachmentProtocol.ascii(bytes, 0, 6).match(new RegExp('^GIF8[79]a$')) !== null) {
      return 'image/gif';
    }
    if (bytes.length >= 12 && TopicAttachmentProtocol.ascii(bytes, 0, 4) === 'RIFF' &&
      TopicAttachmentProtocol.ascii(bytes, 8, 4) === 'WEBP') {
      return 'image/webp';
    }
    if (bytes.length >= 12 && TopicAttachmentProtocol.ascii(bytes, 4, 4) === 'ftyp') {
      const brand: string = TopicAttachmentProtocol.ascii(bytes, 8, 4);
      if (['heic', 'heix', 'hevc', 'hevx', 'mif1', 'msf1'].includes(brand)) {
        return 'image/heif';
      }
      if (brand === 'avif' || brand === 'avis') {
        return 'image/avif';
      }
    }
    if (bytes.length >= 2 && bytes[0] === 0x42 && bytes[1] === 0x4d) {
      return 'image/bmp';
    }
    return '';
  }

  private static ascii(bytes: Uint8Array, start: number, length: number): string {
    let text: string = '';
    for (let index: number = start; index < start + length; index++) {
      text += String.fromCharCode(bytes[index]);
    }
    return text;
  }

  private static asFields(payload: Object | undefined): Record<string, Object> | undefined {
    return payload !== undefined && payload !== null && typeof payload === 'object' && !Array.isArray(payload) ?
      payload as Record<string, Object> : undefined;
  }

  private static isToken(payload: Object | undefined): boolean {
    return typeof payload === 'string' && payload.trim().length > 0 && payload.length <= 8192 &&
      !new RegExp('[\\x00-\\x1f\\x7f]').test(payload);
  }

  private static readError(root: Record<string, Object>, data: Record<string, Object> | undefined): string {
    const records: Record<string, Object>[] = data === undefined ? [root] : [root, data];
    for (const fields of records) {
      const message: Record<string, Object> | undefined = TopicAttachmentProtocol.asFields(fields['__MESSAGE']);
      if (message !== undefined) {
        const status: Object | undefined = message['0'];
        const code: number = Number(message['3']);
        if ((status !== undefined && status !== null && status !== false && status !== 0 && status !== '0' &&
          status !== '') || (Number.isSafeInteger(code) && code >= 400 && code <= 599)) {
          const detail: Object | undefined = message['1'];
          return typeof detail === 'string' && detail.trim().length > 0 ?
            detail.replace(new RegExp('<[^>]*>', 'g'), '').trim().substring(0, 160) : '服务器拒绝了图片上传，请重试';
        }
      }
      for (const key of ['error_code', 'error', '__ERROR', 'error_txt']) {
        const payload: Object | undefined = fields[key];
        if (payload === undefined || payload === null || payload === false || payload === 0 || payload === '0' ||
          payload === '') {
          continue;
        }
        if (key === 'error_code' && (payload === 9 || payload === '9')) {
          return '图片超过论坛允许的大小，请选择更小的图片';
        }
        const errorText: Object | undefined = fields['error_txt'];
        const errorMessage: Object | undefined = fields['error'];
        let feedback: string = typeof errorText === 'string' && errorText.trim().length > 0 ? errorText :
          typeof errorMessage === 'string' && errorMessage.trim().length > 0 ? errorMessage :
          typeof payload === 'string' ? payload : '';
        const errorFields: Record<string, Object> | undefined = TopicAttachmentProtocol.asFields(payload);
        if (errorFields !== undefined) {
          for (const label of ['1', 'message', 'msg', '0']) {
            if (typeof errorFields[label] === 'string') {
              feedback = errorFields[label] as string;
              break;
            }
          }
        }
        const plain: string = feedback.replace(new RegExp('<[^>]*>', 'g'), '').trim().substring(0, 160);
        return plain.length > 0 && plain !== '0' ? plain : '服务器拒绝了图片上传，请重试';
      }
    }
    return '';
  }
}

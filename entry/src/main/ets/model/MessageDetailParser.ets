import { NgaJsonParser } from './NgaJsonParser';
import { NgaMessageDetailData, NgaMessagePost } from './MessageDetailInfo';

/** 兼容当前 allmsgs 和旧数字键协议，userInfo 按 from 关联作者。 */
export class MessageDetailParser {
  static parse(body: string, mid: number, page: number = 1): NgaMessageDetailData {
    const result: NgaMessageDetailData = new NgaMessageDetailData();
    result.mid = mid;
    result.currentPage = Number.isSafeInteger(page) && page > 0 ? page : 1;
    if (!Number.isSafeInteger(mid) || mid <= 0) {
      result.errorMessage = '短消息编号无效，请返回消息列表重试';
      return result;
    }
    try {
      const root: Record<string, Object> = NgaJsonParser.parseResponseObject(body);
      const data: Record<string, Object> | undefined = MessageDetailParser.asFields(root['data']);
      const error: Object | undefined = root['error'] ?? (data !== undefined ? data['error'] : undefined);
      const message: Object | undefined = (data !== undefined ? data['__MESSAGE'] : undefined) ?? root['__MESSAGE'];
      const errorText: string = MessageDetailParser.serverMessage(error, '0');
      if (errorText.length > 0 || message !== undefined) {
        throw new Error(MessageDetailParser.serverMessage(message, '1') || errorText || '服务器返回了接口错误');
      }
      const innerValue: Object | undefined = data !== undefined ? data['0'] : undefined;
      if (typeof innerValue === 'string') {
        throw new Error(innerValue.replace(/<[^>]*>/g, '').trim() || '服务器响应缺少短消息内容');
      }
      const inner: Record<string, Object> | undefined = MessageDetailParser.asFields(innerValue);
      if (inner === undefined) {
        throw new Error('服务器响应缺少短消息内容');
      }
      const currentPage: number = MessageDetailParser.readNumber(inner['currentPage']);
      if (currentPage > 0) {
        result.currentPage = currentPage;
      }
      const rowsPerPage: number = MessageDetailParser.readNumber(inner['rowsPerPage']);
      if (rowsPerPage > 0) {
        result.rowsPerPage = rowsPerPage;
      }
      const nextPage: number = MessageDetailParser.readNumber(inner['nextPage']);
      // Android 仅用 nextPage>0 判断还有下一页；部分响应返回 1 而非实际页号。
      result.nextPage = nextPage > 0 ? nextPage : 0;
      const users: Record<string, Object> | undefined = MessageDetailParser.asFields(inner['userInfo']);
      const rows: Record<string, Object> = MessageDetailParser.messageRows(inner);
      const keys: string[] = Object.keys(rows).filter((key: string): boolean => /^\d+$/.test(key));
      keys.sort((left: string, right: string): number => Number(left) - Number(right));
      if (keys.length === 0 && result.currentPage === 1 && MessageDetailParser.readNumber(inner['length']) > 0) {
        throw new Error('服务器返回的短消息内容格式异常');
      }
      for (const key of keys) {
        const fields: Record<string, Object> | undefined = MessageDetailParser.asFields(rows[key]);
        if (fields === undefined || (fields['content'] === undefined && fields['subject'] === undefined)) {
          throw new Error('服务器返回的短消息内容格式异常');
        }
        if (!MessageDetailParser.isTextValue(fields['content']) ||
          !MessageDetailParser.isTextValue(fields['subject'])) {
          throw new Error('服务器返回的短消息内容格式异常');
        }
        const post: NgaMessagePost = new NgaMessagePost();
        const postId: string = MessageDetailParser.readText(fields['id']).trim();
        post.key = /^\d+$/.test(postId) ? mid.toString() + ':' + postId :
          mid.toString() + ':' + result.currentPage.toString() + ':' + key;
        post.index = (result.currentPage - 1) * result.rowsPerPage + Number(key) + 1;
        post.subject = MessageDetailParser.readText(fields['subject']);
        // 旧协议的部分系统消息仅有 subject，Android 也将其用作正文。
        post.content = fields['content'] === undefined || fields['content'] === null ?
          post.subject : MessageDetailParser.readText(fields['content']);
        const from: string = MessageDetailParser.readText(fields['from']);
        post.authorId = MessageDetailParser.readNumber(fields['from']);
        const user: Record<string, Object> | undefined = users !== undefined ?
          MessageDetailParser.asFields(users[from]) : undefined;
        post.author = (user !== undefined ? MessageDetailParser.readText(user['username']) : '') ||
          MessageDetailParser.readText(fields['from_username']) || from || '系统消息';
        post.avatar = user !== undefined ? MessageDetailParser.readText(user['avatar']) : '';
        post.time = MessageDetailParser.readNumber(fields['time']);
        result.posts.push(post);
      }
      result.subject = MessageDetailParser.readText(inner['subject']) ||
        (result.posts.length > 0 ? result.posts[0].subject : '');
      result.success = true;
    } catch (error) {
      result.posts = [];
      result.errorMessage = error instanceof SyntaxError ? '服务器响应解析失败，请重试' :
        ((error as Error).message || '短消息加载失败，请重试');
    }
    return result;
  }

  /** 新协议将正文放入 allmsgs；未知的非空容器不能当成“暂无内容”。 */
  private static messageRows(inner: Record<string, Object>): Record<string, Object> {
    if (inner['allmsgs'] !== undefined) {
      const rows: Record<string, Object> | undefined = MessageDetailParser.asFields(inner['allmsgs']);
      if (rows === undefined || Object.keys(rows).some((key: string): boolean => !/^\d+$/.test(key))) {
        throw new Error('服务器返回的短消息内容格式异常');
      }
      return rows;
    }
    const metadataKeys: string[] = ['currentPage', 'nextPage', 'rowsPerPage', 'userInfo', 'subject',
      'allUsers', 'starterUid', 'subjectBit', 'length'];
    const keys: string[] = Object.keys(inner);
    if (keys.some((key: string): boolean => !/^\d+$/.test(key) && !metadataKeys.includes(key))) {
      throw new Error('服务器返回的短消息内容格式异常');
    }
    return inner;
  }

  /** PHP 索引容器可能序列化成数组，容器字段读取也需支持数组形式。 */
  private static asFields(value: Object | undefined): Record<string, Object> | undefined {
    if (value === undefined || value === null || typeof value !== 'object') {
      return undefined;
    }
    return value as Record<string, Object>;
  }

  private static readText(value: Object | undefined): string {
    if (typeof value === 'string') {
      return value;
    }
    return typeof value === 'number' && Number.isFinite(value) ? value.toString() : '';
  }

  private static isTextValue(value: Object | undefined): boolean {
    return value === undefined || value === null || typeof value === 'string' ||
      (typeof value === 'number' && Number.isFinite(value));
  }

  private static readNumber(value: Object | undefined): number {
    if (typeof value === 'number') {
      return Number.isSafeInteger(value) ? value : 0;
    }
    if (typeof value === 'string' && /^-?\d+$/.test(value.trim())) {
      const numberValue: number = Number(value);
      return Number.isSafeInteger(numberValue) ? numberValue : 0;
    }
    return 0;
  }

  private static serverMessage(value: Object | undefined, preferredKey: string): string {
    if (typeof value === 'string') {
      return value === '0' ? '' : value.replace(/<[^>]*>/g, '').trim();
    }
    if (typeof value === 'number') {
      return value === 0 ? '' : '接口错误（' + value.toString() + '）';
    }
    const fields: Record<string, Object> | undefined = MessageDetailParser.asFields(value);
    if (fields !== undefined) {
      for (const key of [preferredKey, 'message', 'msg', '0', '1']) {
        const text: string = typeof fields[key] === 'string' ?
          (fields[key] as string).replace(/<[^>]*>/g, '').trim() : '';
        if (text.length > 0 && text !== '0') {
          return text;
        }
      }
      return '服务器返回了接口错误';
    }
    return value === true ? '服务器返回了接口错误' : '';
  }
}

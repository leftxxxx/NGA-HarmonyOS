import { NgaJsonParser } from './NgaJsonParser';

export class NgaMessageReplyResult {
  success: boolean = false;
  errorMessage: string = '';
  uncertain: boolean = false;
}

/** 短消息发送必须收到明确的操作反馈，HTTP 200 或未知响应不能代表发送成功。 */
export class MessageReplyParser {
  static parse(body: string): NgaMessageReplyResult {
    const result: NgaMessageReplyResult = new NgaMessageReplyResult();
    try {
      const root: Record<string, Object> = NgaJsonParser.parseResponseObject(body);
      const data: Record<string, Object> | undefined = MessageReplyParser.asFields(root['data']);
      const errors: (Object | undefined)[] = [root['error'], root['__ERROR'],
        data !== undefined ? data['error'] : undefined, data !== undefined ? data['__ERROR'] : undefined];
      for (const error of errors) {
        if (!MessageReplyParser.isEmptyStatus(error)) {
          const feedback: string = MessageReplyParser.serverText(error, '0');
          result.errorMessage = MessageReplyParser.isSuccessText(feedback) ?
            '服务器拒绝了短消息回复' : (feedback || '服务器拒绝了短消息回复');
          return result;
        }
      }

      const messages: (Object | undefined)[] = [root['__MESSAGE'],
        data !== undefined ? data['__MESSAGE'] : undefined];
      let messageSuccess: boolean = false;
      let messageUncertain: boolean = false;
      for (const message of messages) {
        if (message === undefined || message === null) {
          continue;
        }
        const fields: Record<string, Object> | undefined = MessageReplyParser.asFields(message);
        const status: Object | undefined = fields !== undefined ? fields['0'] : undefined;
        const httpStatus: Object | undefined = fields !== undefined ? fields['3'] : undefined;
        const feedback: string = MessageReplyParser.serverText(message, '1');
        if ((fields !== undefined && !MessageReplyParser.isEmptyStatus(status)) ||
          MessageReplyParser.isHttpErrorStatus(httpStatus) || MessageReplyParser.isFailureText(feedback)) {
          result.errorMessage = MessageReplyParser.isSuccessText(feedback) ?
            '服务器拒绝了短消息回复' : (feedback || '服务器拒绝了短消息回复');
          return result;
        }
        if (MessageReplyParser.isSuccessText(feedback)) {
          messageSuccess = true;
        } else if (fields === undefined ||
          (status === undefined && feedback.length === 0)) {
          // 未知类型或空的 __MESSAGE 不能与另一处成功文字拼成确认成功。
          messageUncertain = true;
        }
      }

      const feedback: string = data !== undefined && typeof data['0'] === 'string' ?
        MessageReplyParser.plainText(data['0'] as string) : '';
      if (MessageReplyParser.isFailureText(feedback)) {
        result.errorMessage = feedback;
        return result;
      }
      if (!messageUncertain && (messageSuccess || MessageReplyParser.isSuccessText(feedback))) {
        result.success = true;
        return result;
      }
    } catch (error) {
      // 超时后的回包、空响应或协议变化均不能证明发送失败，避免提示直接重复发送。
    }
    result.uncertain = true;
    result.errorMessage = '发送结果未确认，请查看会话后再决定是否重试';
    return result;
  }

  private static asFields(payload: Object | undefined): Record<string, Object> | undefined {
    return payload !== undefined && payload !== null && typeof payload === 'object' ?
      payload as Record<string, Object> : undefined;
  }

  private static isEmptyStatus(payload: Object | undefined): boolean {
    return payload === undefined || payload === null || payload === false || payload === 0 ||
      (typeof payload === 'string' && (payload.trim().length === 0 || payload.trim() === '0'));
  }

  private static plainText(text: string): string {
    return text.replace(new RegExp('<[^>]*>', 'g'), '').trim();
  }

  private static isSuccessText(text: string): boolean {
    // 仅识别独立的已知反馈，不能把“未操作成功”或“操作成功率低”等文字当成成功。
    return new RegExp('^(?:发送完毕|操作成功)(?=$|[\\s.。!！…])').test(text) &&
      !new RegExp('(?:发送|操作|回复)(?:失败|未成功|未完成|未完毕)|(?:未|不|没有|尚未|未能)(?:发送完毕|操作成功)').test(text);
  }

  private static isFailureText(text: string): boolean {
    const feedback: string = text.replace(new RegExp('^-?\\d+\\s*[:：]\\s*'), '');
    // 只把明确拒绝反馈当作失败；其它文字仍保留为未确认，避免诱导重复发送。
    return new RegExp('^(?:(?:发送|操作|回复)(?:失败|未成功|未完成|未完毕)|' +
      '未登录|请先登录|登录已(?:失效|过期)|没有(?:回复|发送|操作)?权限|无(?:回复|发送|操作)?权限|' +
      '(?:消息|会话|该会话)已关闭|该会话(?:无法|不能)回复|发送过于频繁)').test(feedback);
  }

  private static isHttpErrorStatus(payload: Object | undefined): boolean {
    if (typeof payload === 'number') {
      return Number.isInteger(payload) && payload >= 400 && payload <= 599;
    }
    return typeof payload === 'string' && new RegExp('^[45]\\d{2}$').test(payload.trim());
  }

  private static serverText(payload: Object | undefined, preferredKey: string): string {
    if (typeof payload === 'string') {
      return payload === '0' ? '' : MessageReplyParser.plainText(payload);
    }
    if (typeof payload === 'number') {
      return payload === 0 ? '' : '接口错误（' + payload.toString() + '）';
    }
    const fields: Record<string, Object> | undefined = MessageReplyParser.asFields(payload);
    if (fields !== undefined) {
      for (const key of [preferredKey, 'message', 'msg', '1', '0']) {
        const item: Object | undefined = fields[key];
        if (typeof item === 'string') {
          const text: string = MessageReplyParser.plainText(item);
          if (text.length > 0 && text !== '0') {
            return text;
          }
        }
      }
      const code: Object | undefined = fields['0'];
      if (typeof code === 'number' && code !== 0) {
        return '接口错误（' + code.toString() + '）';
      }
    }
    return '';
  }
}

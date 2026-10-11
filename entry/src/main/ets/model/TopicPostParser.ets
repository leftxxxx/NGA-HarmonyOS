import { NgaJsonParser } from './NgaJsonParser';

export class NgaTopicPostPreparation {
  success: boolean = false;
  errorMessage: string = '';
  fid: number = 0;
  stid: number = 0;
}

export class NgaTopicPostResult {
  success: boolean = false;
  uncertain: boolean = false;
  errorMessage: string = '';
  tid: number = 0;
}

/** 只读取已知 NGA 返回结构，不执行回包中的脚本，也不将 HTTP 200 当成发帖成功。 */
export class TopicPostParser {
  static parsePreparation(body: string, requestedFid: number, requestedStid: number): NgaTopicPostPreparation {
    const result: NgaTopicPostPreparation = new NgaTopicPostPreparation();
    result.fid = requestedFid;
    result.stid = requestedStid;
    if (!Number.isSafeInteger(requestedFid) || !Number.isSafeInteger(requestedStid) || requestedStid < 0) {
      result.errorMessage = '发帖板块编号无效，请返回板块重试';
      return result;
    }
    try {
      const root: Record<string, Object> = NgaJsonParser.parseResponseObject(body);
      const data: Record<string, Object> | undefined = TopicPostParser.asFields(root['data']);
      const rejection: string = TopicPostParser.explicitError(root, data);
      if (rejection.length > 0) {
        result.errorMessage = rejection;
        return result;
      }
      if (data === undefined) {
        result.errorMessage = '服务器未返回有效的发帖信息，请重试';
        return result;
      }
      // auth 仅供安卓附件上传使用；文字发帖可凭已匹配的标准板块上下文继续。
      const hasAttachmentAuth: boolean = typeof data['auth'] === 'string' &&
        (data['auth'] as string).trim().length > 0;
      let hasBoardContext: boolean = false;
      const forum: Record<string, Object> | undefined = TopicPostParser.asFields(data['__F']);
      const contexts: Record<string, Object>[] = [data];
      if (forum !== undefined) {
        contexts.push(forum);
      }
      for (const context of contexts) {
        const reportedFid: Object | undefined = context['fid'];
        if (reportedFid !== undefined && reportedFid !== null) {
          const nextFid: number | undefined = TopicPostParser.readInteger(reportedFid);
          if (nextFid === undefined || (nextFid !== 0 && result.fid !== 0 && nextFid !== result.fid)) {
            result.errorMessage = '服务器返回的板块信息不一致，请返回板块重新发帖';
            return result;
          }
          if (nextFid !== 0) {
            result.fid = nextFid;
            hasBoardContext = true;
          }
        }
        const reportedStid: Object | undefined = context['stid'];
        if (reportedStid !== undefined && reportedStid !== null) {
          const nextStid: number | undefined = TopicPostParser.readInteger(reportedStid);
          if (nextStid === undefined || nextStid < 0 || nextStid !== requestedStid) {
            result.errorMessage = '服务器返回的子板块信息不一致，请返回板块重新发帖';
            return result;
          }
          if (nextStid > 0) {
            hasBoardContext = true;
          }
        }
      }
      if (!hasAttachmentAuth && !hasBoardContext) {
        result.errorMessage = '服务器未返回有效的发帖信息，请重试';
        return result;
      }
      result.success = true;
    } catch (error) {
      result.errorMessage = '发帖信息加载失败，请检查网络后重试';
    }
    return result;
  }

  static parseSubmit(body: string): NgaTopicPostResult {
    const result: NgaTopicPostResult = new NgaTopicPostResult();
    try {
      const root: Record<string, Object> = NgaJsonParser.parseResponseObject(body);
      const data: Record<string, Object> | undefined = TopicPostParser.asFields(root['data']);
      const rejection: string = TopicPostParser.explicitError(root, data);
      if (rejection.length > 0) {
        result.errorMessage = rejection;
        return result;
      }
      let acknowledged: boolean = false;
      let ambiguousMessage: boolean = false;
      const fragments: string[] = [];
      for (const payload of [root['__MESSAGE'], data !== undefined ? data['__MESSAGE'] : undefined]) {
        if (payload === undefined || payload === null) {
          continue;
        }
        const fields: Record<string, Object> | undefined = TopicPostParser.asFields(payload);
        const fragment: string = TopicPostParser.serverFragment(payload, '1');
        if (TopicPostParser.isSuccessText(TopicPostParser.plainText(fragment))) {
          acknowledged = true;
          fragments.push(fragment);
        } else if (fields === undefined || fragment.length === 0) {
          ambiguousMessage = true;
        }
      }
      if (data !== undefined && typeof data['0'] === 'string') {
        const fragment: string = data['0'] as string;
        const feedback: string = TopicPostParser.plainText(fragment);
        if (TopicPostParser.isFailureText(feedback)) {
          result.errorMessage = feedback;
          return result;
        }
        if (TopicPostParser.isSuccessText(feedback)) {
          acknowledged = true;
          fragments.push(fragment);
        }
      }
      if (acknowledged && !ambiguousMessage) {
        result.success = true;
        result.tid = TopicPostParser.readSuccessTopicId(fragments);
        return result;
      }
    } catch (error) {
      // 安卓文字发帖没有 lite=js，提交回包采用 HTML；只识别固定反馈行。
      const source: string = body.trim().startsWith('<') ? TopicPostParser.feedbackHtml(body) : '';
      const pattern: RegExp = new RegExp('<span\\s+style=([\'\"])color:\\s*#aaa;?\\1>' +
        '\\s*(?:&gt;|>)\\s*</span>([\\s\\S]*?)<br\\s*/?>', 'gi');
      let match: RegExpExecArray | null = pattern.exec(source);
      const fragments: string[] = [];
      while (match !== null) {
        const feedback: string = TopicPostParser.plainText(match[2]);
        if (TopicPostParser.isFailureText(feedback)) {
          result.errorMessage = feedback;
          return result;
        }
        if (TopicPostParser.isSuccessText(feedback)) {
          fragments.push(match[2]);
        }
        match = pattern.exec(source);
      }
      if (fragments.length > 0) {
        result.success = true;
        result.tid = TopicPostParser.readSuccessTopicId(fragments);
        return result;
      }
    }
    result.uncertain = true;
    result.errorMessage = '发帖结果未确认，草稿已保留。请先查看板块，避免重复发布';
    return result;
  }

  private static asFields(payload: Object | undefined): Record<string, Object> | undefined {
    return payload !== undefined && payload !== null && typeof payload === 'object' ?
      payload as Record<string, Object> : undefined;
  }

  private static readInteger(payload: Object | undefined): number | undefined {
    if (typeof payload === 'number') {
      return Number.isSafeInteger(payload) ? payload : undefined;
    }
    if (typeof payload !== 'string' || !new RegExp('^-?\\d+$').test(payload.trim())) {
      return undefined;
    }
    const number: number = Number(payload.trim());
    return Number.isSafeInteger(number) ? number : undefined;
  }

  private static emptyStatus(payload: Object | undefined): boolean {
    return payload === undefined || payload === null || payload === false || payload === 0 ||
      (typeof payload === 'string' && (payload.trim().length === 0 || payload.trim() === '0'));
  }

  private static explicitError(root: Record<string, Object>, data: Record<string, Object> | undefined): string {
    const records: Record<string, Object>[] = [root];
    if (data !== undefined) {
      records.push(data);
    }
    for (const record of records) {
      for (const key of ['error', '__ERROR', 'error_code']) {
        const payload: Object | undefined = record[key];
        if (!TopicPostParser.emptyStatus(payload)) {
          const feedback: string = TopicPostParser.plainText(TopicPostParser.serverFragment(payload, '0'));
          return feedback.length > 0 && !TopicPostParser.isSuccessText(feedback) ? feedback : '服务器拒绝了发帖请求';
        }
      }
      const indexedFeedback: Object | undefined = record['0'];
      if (typeof indexedFeedback === 'string' &&
        TopicPostParser.isFailureText(TopicPostParser.plainText(indexedFeedback))) {
        return TopicPostParser.plainText(indexedFeedback);
      }
      const message: Object | undefined = record['__MESSAGE'];
      if (message === undefined || message === null) {
        continue;
      }
      const fields: Record<string, Object> | undefined = TopicPostParser.asFields(message);
      const feedback: string = TopicPostParser.plainText(TopicPostParser.serverFragment(message, '1'));
      const status: number | undefined = fields !== undefined ? TopicPostParser.readInteger(fields['3']) : undefined;
      if ((fields !== undefined && !TopicPostParser.emptyStatus(fields['0'])) ||
        (status !== undefined && status >= 400 && status <= 599) || TopicPostParser.isFailureText(feedback)) {
        return feedback.length > 0 && !TopicPostParser.isSuccessText(feedback) ? feedback : '服务器拒绝了发帖请求';
      }
    }
    return '';
  }

  private static serverFragment(payload: Object | undefined, preferredKey: string): string {
    if (typeof payload === 'string') {
      return payload === '0' ? '' : payload;
    }
    if (typeof payload === 'number') {
      return payload === 0 ? '' : '接口错误（' + payload.toString() + '）';
    }
    const fields: Record<string, Object> | undefined = TopicPostParser.asFields(payload);
    if (fields !== undefined) {
      for (const key of [preferredKey, 'message', 'msg', '1', '0']) {
        const text: Object | undefined = fields[key];
        if (typeof text === 'string' && text.trim().length > 0 && text.trim() !== '0') {
          return text;
        }
      }
    }
    return '';
  }

  private static plainText(fragment: string): string {
    return TopicPostParser.feedbackHtml(fragment).replace(new RegExp('<[^>]*>', 'g'), '')
      .replace(new RegExp('&nbsp;|&#160;', 'gi'), ' ').replace(new RegExp('&amp;', 'gi'), '&')
      .replace(new RegExp('&gt;', 'gi'), '>').replace(new RegExp('&lt;', 'gi'), '<').trim();
  }

  private static feedbackHtml(fragment: string): string {
    return fragment.replace(new RegExp('<!--[\\s\\S]*?-->', 'g'), '')
      .replace(new RegExp('<(script|style|textarea|pre|code|blockquote)\\b[^>]*>[\\s\\S]*?</\\1\\s*>', 'gi'), '');
  }

  private static isSuccessText(feedback: string): boolean {
    return new RegExp('^发[贴帖]完毕(?=$|[\\s.。!！…])').test(feedback) &&
      !new RegExp('(?:发[贴帖]|发送|发布)(?:失败|未成功|未完成|未完毕)|' +
        '(?:未|不|没有|尚未|未能)发[贴帖]完毕').test(feedback);
  }

  private static isFailureText(feedback: string): boolean {
    const text: string = feedback.replace(new RegExp('^-?\\d+\\s*[:：]\\s*'), '');
    return new RegExp('^(?:(?:发[贴帖]|发送|发布|操作)(?:失败|未成功|未完成|未完毕)|' +
      '未登录|请先登录|登录已(?:失效|过期)|没有(?:发[贴帖]|发布|操作)?权限|' +
      '无(?:发[贴帖]|发布|操作)?权限|(?:该)?(?:板块|版面|话题)(?:已关闭|已锁定|不能发[贴帖]|禁止发[贴帖])|' +
      '发[贴帖]过于频繁|标题(?:不能为空|过短)|内容(?:不能为空|过短))').test(text) ||
      new RegExp('^发[贴帖]完毕[\\s.。!！…]*(?:发[贴帖]|发布|操作)失败').test(text);
  }

  /** 仅从已确认成功的反馈中读取 NGA read.php 链接；不会执行任意 URL 或脚本。 */
  private static readSuccessTopicId(fragments: string[]): number {
    let resolvedTid: number = 0;
    for (const fragment of fragments) {
      const pattern: RegExp = new RegExp('\\bhref\\s*=\\s*([\'\"])([^\'\"<>]+)\\1', 'gi');
      let match: RegExpExecArray | null = pattern.exec(TopicPostParser.feedbackHtml(fragment));
      while (match !== null) {
        const target: string = match[2].replace(new RegExp('&amp;', 'gi'), '&');
        const path: RegExpMatchArray | null = target.match(new RegExp('^(?:https?://(?:bbs\\.nga\\.cn|' +
          'bbs\\.ngacn\\.cc|nga\\.178\\.com|nga\\.donews\\.com|ngabbs\\.com))?' +
          '(?:/|\\./)?read\\.php\\?([^#]+)(?:#[^\\s]*)?$', 'i'));
        if (path !== null) {
          const parameters: string[] = path[1].split('&');
          let linkTid: number = 0;
          let duplicateTid: boolean = false;
          for (const parameter of parameters) {
            if (parameter.startsWith('tid=')) {
              const parsed: number | undefined = TopicPostParser.readInteger(parameter.substring(4));
              if (parsed === undefined || parsed <= 0 || linkTid !== 0) {
                duplicateTid = true;
              } else {
                linkTid = parsed;
              }
            }
          }
          if (!duplicateTid && linkTid > 0) {
            if (resolvedTid !== 0 && resolvedTid !== linkTid) {
              return 0;
            }
            resolvedTid = linkTid;
          }
        }
        match = pattern.exec(TopicPostParser.feedbackHtml(fragment));
      }
    }
    return resolvedTid;
  }
}



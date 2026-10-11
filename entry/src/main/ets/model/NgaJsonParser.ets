/*
 * NGA JSON 响应解析器。
 * 解析 NGA API 返回的精简 JSON 格式数据，处理带 __ 前缀的特殊字段。
 * 对应 Android TopicListInfo / ThreadData 的 JSON 解析逻辑。
 */

import { ThreadPageInfo } from './ThreadPageInfo';
import { ThreadRowInfo } from './ThreadRowInfo';
import { TopicListInfo } from './TopicListInfo';
import { ThreadData } from './ThreadData';
import { Board } from './Board';
import { ProfileData, ReputationItem, AdminForumItem } from './ProfileData';
import { AvatarUtils } from './AvatarUtils';

/**
 * NGA JSON 解析器。
 * - parseTopicList: 解析话题列表 JSON
 * - parseThreadData: 解析帖子详情 JSON
 * - parseProfile: 解析用户主页 JSON
 */
export class NgaJsonParser {
  /**
   * 解析话题列表 JSON。
   * NGA lite=js / __output=8 的话题位于 data.__T，通常是数字键对象。
   * 同时兼容旧版根节点字段和数组，保留接口错误以区别于有效空列表。
   */
  static parseTopicList(jsonStr: string): TopicListInfo {
    const result: TopicListInfo = new TopicListInfo();
    if (jsonStr.trim().length === 0) {
      result.error = '服务器返回了空响应';
      return result;
    }
    try {
      const root: Record<string, Object> | undefined =
        NgaJsonParser.asRecord(JSON.parse(NgaJsonParser.cleanJsonWrapper(jsonStr)) as Object);
      if (root === undefined) {
        result.error = '服务器响应格式异常';
        return result;
      }
      const data: Record<string, Object> = NgaJsonParser.asRecord(root['data']) ?? root;
      const apiError: string = NgaJsonParser.getApiError(root, data, '__T');
      if (apiError.length > 0) {
        result.error = apiError;
        return result;
      }
      const topicRows: Object[] | undefined = NgaJsonParser.getIndexedRows(data['__T']);
      if (topicRows === undefined) {
        result.error = '服务器响应缺少有效的话题数据';
        return result;
      }

      // 解析板块名称
      const fRecord: Record<string, Object> | undefined = NgaJsonParser.asRecord(data['__F']);
      if (fRecord !== undefined) {
        const fName: Object | undefined = fRecord['name'];
        if (typeof fName === 'string') {
          result.name = fName;
        }
      }

      for (const item of topicRows) {
        const itemRecord: Record<string, Object> | undefined = NgaJsonParser.asRecord(item);
        if (itemRecord === undefined) {
          continue;
        }
        const thread: ThreadPageInfo = new ThreadPageInfo();
        thread.tid = NgaJsonParser.readNumber(itemRecord['tid']);
        const subject: Object | undefined = itemRecord['subject'];
        if (thread.tid <= 0 || typeof subject !== 'string') {
          continue;
        }
        thread.subject = subject;
        thread.author = NgaJsonParser.readString(itemRecord['author']);
        thread.authorId = NgaJsonParser.readNumber(itemRecord['authorid']);
        thread.replies = NgaJsonParser.readNumber(itemRecord['replies']);
        thread.lastPoster = NgaJsonParser.readString(itemRecord['lastposter']);
        thread.postDate = NgaJsonParser.readNumber(itemRecord['postdate']);
        result.threadPageList.push(thread);
      }
      if (topicRows.length > 0 && result.threadPageList.length === 0) {
        result.error = '服务器返回的话题数据格式异常';
        return result;
      }

      // 兼容旧版 __SUB 数组；正式接口使用 __F.sub_forums 数字键对象。
      const subArray: Object[] | undefined = NgaJsonParser.getIndexedRows(data['__SUB']);
      if (subArray !== undefined) {
        for (const sub of subArray) {
          const subRecord: Record<string, Object> | undefined = NgaJsonParser.asRecord(sub);
          if (subRecord === undefined) {
            continue;
          }
          const board: Board = new Board();
          board.fid = NgaJsonParser.readNumber(subRecord['fid']);
          board.stid = NgaJsonParser.readNumber(subRecord['stid']);
          board.name = NgaJsonParser.readString(subRecord['name']);
          result.subBoardList.push(board);
        }
      } else if (fRecord !== undefined) {
        NgaJsonParser.parseSubForums(fRecord['sub_forums'], result);
      }
      result.success = true;
    } catch (err) {
      result.error = '服务器响应解析失败，请重试';
    }
    return result;
  }

  /** 只去除已知 JS 包装，不执行服务器返回的 JavaScript。 */
  private static cleanJsonWrapper(body: string): string {
    let value: string = NgaJsonParser.trimJsonErrorPadding(body.trim());
    const prefix: string = 'window.script_muti_get_var_store=';
    const marker: string = '/*$js$*/';
    for (let index: number = 0; index < 4; index++) {
      if (value.startsWith(prefix)) {
        value = value.substring(prefix.length).trim();
      } else if (value.startsWith(marker)) {
        value = value.substring(marker.length).trim();
      } else {
        break;
      }
    }
    for (let index: number = 0; index < 4; index++) {
      if (value.endsWith(';')) {
        value = value.substring(0, value.length - 1).trim();
      } else if (value.endsWith(marker)) {
        value = value.substring(0, value.length - marker.length).trim();
      } else {
        break;
      }
    }
    return NgaJsonParser.escapeJsonControlCharacters(NgaJsonParser.normalizeJsonTextNumbers(value));
  }

  /** 仅裁剪完整 JSON 之后的 NGA 填充注释，字符串中的同名文字须保留。 */
  private static trimJsonErrorPadding(value: string): string {
    let insideString: boolean = false;
    let escaped: boolean = false;
    let depth: number = 0;
    let documentEnded: boolean = false;
    for (let index: number = 0; index < value.length; index++) {
      const character: string = value.charAt(index);
      if (insideString) {
        if (escaped) {
          escaped = false;
        } else if (character === '\\') {
          escaped = true;
        } else if (character === '"') {
          insideString = false;
        }
      } else if (character === '"') {
        insideString = true;
      } else if (character === '{' || character === '[') {
        depth++;
      } else if (character === '}' || character === ']') {
        depth--;
        documentEnded = depth === 0;
      } else if (documentEnded && depth === 0 && value.startsWith('/*error fill content', index)) {
        const commentEnd: number = value.indexOf('*/', index + '/*error fill content'.length);
        // 未闭合填充注释的余下文本都属于注释；已闭合时保留后缀供 JSON.parse 校验。
        return commentEnd < 0 ? value.substring(0, index).trim() :
          value.substring(0, index) + value.substring(commentEnd + 2);
      }
    }
    return value;
  }

  /** NGA 可能以 +数字 返回 subject/content；只处理字符串外的这两种字段。 */
  private static normalizeJsonTextNumbers(value: string): string {
    let result: string = '';
    let insideString: boolean = false;
    let escaped: boolean = false;
    for (let index: number = 0; index < value.length; index++) {
      const character: string = value.charAt(index);
      if (!insideString && (value.startsWith('"subject"', index) || value.startsWith('"content"', index))) {
        const key: string = value.substring(index, index + 9);
        const match: RegExpMatchArray | null = value.substring(index + key.length).match(/^(\s*:\s*)\+(\d+)(?=\s*[,}])/);
        if (match !== null) {
          result += key + match[1] + '"+' + match[2] + '"';
          index += key.length + match[0].length - 1;
          continue;
        }
      }
      result += character;
      if (insideString && escaped) {
        escaped = false;
      } else if (insideString && character === '\\') {
        escaped = true;
      } else if (character === '"') {
        insideString = !insideString;
      }
    }
    return result;
  }

  /** 提供共享、安全的响应解析入口，供通知等接口复用同一套 NGA 清洗规则。 */
  static parseResponseObject(body: string): Record<string, Object> {
    if (body.trim().length === 0) {
      throw new Error('服务器返回了空响应');
    }
    const root: Record<string, Object> | undefined =
      NgaJsonParser.asRecord(JSON.parse(NgaJsonParser.cleanJsonWrapper(body)) as Object);
    if (root === undefined) {
      throw new Error('服务器响应格式异常');
    }
    return root;
  }

  /** 将 NGA 字符串内的 JS 十六进制转义与原始控制字符规范为等价 JSON。 */
  private static escapeJsonControlCharacters(value: string): string {
    let result: string = '';
    let insideString: boolean = false;
    let escaped: boolean = false;
    for (let index: number = 0; index < value.length; index++) {
      const character: string = value.charAt(index);
      if (insideString && escaped) {
        result += character;
        escaped = false;
      } else if (insideString && character === '\\') {
        const hex: string = value.substring(index + 2, index + 4);
        if (value.charAt(index + 1) === 'x' && /^[0-9a-fA-F]{2}$/.test(hex)) {
          // lite=js 的 jdata 等字段可能含 \xHH；保留含义，不执行返回脚本。
          result += '\\u00' + hex;
          index += 3;
        } else {
          result += character;
          escaped = true;
        }
      } else if (character === '"') {
        result += character;
        insideString = !insideString;
      } else if (insideString && value.charCodeAt(index) < 32) {
        result += '\\u' + value.charCodeAt(index).toString(16).padStart(4, '0');
      } else {
        result += character;
      }
    }
    return result;
  }

  /** EOF 解析错误与未闭合对象必须同时成立；不修补响应，也不把其他格式错误当成缺尾。 */
  private static isIncompleteJsonResponse(value: string, message: string): boolean {
    const document: string = value.trimEnd();
    if (!document.startsWith('{')) {
      return false;
    }
    if (!/^(?:Unexpected end\b|Unterminated string\b)/i.test(message)) {
      const offset: RegExpMatchArray | null = message.match(/\bposition\s+(\d+)/i);
      if (!/^Expected\b/i.test(message) || offset === null || Number(offset[1]) < document.length) {
        return false;
      }
    }
    let insideString: boolean = false;
    let escaped: boolean = false;
    const brackets: string[] = [];
    for (let index: number = 0; index < document.length; index++) {
      const character: string = document.charAt(index);
      if (insideString) {
        if (escaped) {
          escaped = false;
        } else if (character === '\\') {
          escaped = true;
        } else if (character === '"') {
          insideString = false;
        }
      } else if (character === '"') {
        insideString = true;
      } else if (character === '{' || character === '[') {
        brackets.push(character);
      } else if (character === '}' || character === ']') {
        const opening: string | undefined = brackets.pop();
        if (opening !== (character === '}' ? '{' : '[')) {
          return false;
        }
      }
    }
    return insideString || brackets.length > 0;
  }

  private static asRecord(value: Object | undefined): Record<string, Object> | undefined {
    if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
      return undefined;
    }
    return value as Record<string, Object>;
  }

  private static readString(value: Object | undefined): string {
    return typeof value === 'string' ? value : '';
  }

  private static readText(value: Object | undefined): string {
    return typeof value === 'number' ? value.toString() : NgaJsonParser.readString(value);
  }

  private static readNumber(value: Object | undefined): number {
    if (typeof value === 'number') {
      return Number.isFinite(value) ? value : 0;
    }
    if (typeof value === 'string' && /^-?\d+$/.test(value.trim())) {
      const numberValue: number = Number(value);
      return Number.isFinite(numberValue) ? numberValue : 0;
    }
    return 0;
  }

  /** 楼层身份只接受明确的非负整数；缺失时不能退化成楼主的 0。 */
  private static readPostIdentifier(value: Object | undefined): number {
    if (typeof value === 'number') {
      return Number.isSafeInteger(value) && value >= 0 ? value : -1;
    }
    if (typeof value === 'string' && /^\d+$/.test(value.trim())) {
      const identifier: number = Number(value);
      return Number.isSafeInteger(identifier) ? identifier : -1;
    }
    return -1;
  }

  /** 数字键按数值排序，兼容稀疏键和真正的数组。 */
  private static getIndexedRows(value: Object | undefined): Object[] | undefined {
    if (Array.isArray(value)) {
      return value as Object[];
    }
    const record: Record<string, Object> | undefined = NgaJsonParser.asRecord(value);
    if (record === undefined) {
      return undefined;
    }
    const allKeys: string[] = Object.keys(record);
    const keys: string[] = allKeys.filter((key: string): boolean => /^\d+$/.test(key));
    if (allKeys.length > 0 && keys.length === 0) {
      return undefined;
    }
    keys.sort((left: string, right: string): number => Number(left) - Number(right));
    const rows: Object[] = [];
    for (const key of keys) {
      rows.push(record[key]);
    }
    return rows;
  }

  private static messageText(value: Object | undefined, firstKey: string): string {
    if (typeof value === 'string') {
      return value === '0' ? '' : value.replace(/<[^>]*>/g, '').trim();
    }
    if (typeof value === 'number') {
      return value === 0 ? '' : '接口错误（' + value.toString() + '）';
    }
    const record: Record<string, Object> | undefined = NgaJsonParser.asRecord(value);
    if (record !== undefined || Array.isArray(value)) {
      const fields: Record<string, Object> = value as Record<string, Object>;
      for (const key of [firstKey, 'message', 'msg', '1', '0']) {
        const text: string = NgaJsonParser.readString(fields[key]).replace(/<[^>]*>/g, '').trim();
        if (text.length > 0 && text !== '0') {
          return text;
        }
      }
      const errorCode: Object | undefined = fields[firstKey];
      if (typeof errorCode === 'number' && errorCode !== 0) {
        return '接口错误（' + errorCode.toString() + '）';
      }
      return '服务器返回了接口错误';
    }
    return value === true ? '服务器返回了接口错误' : '';
  }

  private static getApiError(root: Record<string, Object>, data: Record<string, Object>, rowsKey: string): string {
    const error: Object | undefined = root['error'] ?? data['error'];
    const message: Object | undefined = data['__MESSAGE'] ?? root['__MESSAGE'];
    const messageRecord: Record<string, Object> | undefined = NgaJsonParser.asRecord(message);
    const errorText: string = NgaJsonParser.messageText(error, '0');
    if (errorText.length > 0 ||
      (message !== undefined && (data[rowsKey] === undefined ||
        (messageRecord !== undefined && NgaJsonParser.readNumber(messageRecord['0']) !== 0)))) {
      return NgaJsonParser.messageText(message, '1') || errorText;
    }
    return '';
  }

  /** 楼层操作反馈沿用 NGA 的 JSON 包装清洗和错误解析，不能用 HTTP 成功代替操作成功。 */
  static parsePostActionResult(body: string): string {
    try {
      const root: Record<string, Object> | undefined =
        NgaJsonParser.asRecord(JSON.parse(NgaJsonParser.cleanJsonWrapper(body)) as Object);
      if (root === undefined) {
        return '';
      }
      const data: Record<string, Object> = NgaJsonParser.asRecord(root['data']) ?? root;
      const errorText: string = NgaJsonParser.getApiError(root, data, '0');
      return errorText || NgaJsonParser.readString(data['0']).replace(/<[^>]*>/g, '').trim();
    } catch (err) {
      return '';
    }
  }

  private static parseSubForums(value: Object | undefined, result: TopicListInfo): void {
    try {
      const decoded: Object | undefined = typeof value === 'string' && value.trim().length > 0 ?
        JSON.parse(value) as Object : value;
      const subForums: Record<string, Object> | undefined = NgaJsonParser.asRecord(decoded);
      if (subForums === undefined) {
        return;
      }
      for (const key of Object.keys(subForums)) {
        const fields: Record<string, Object> | undefined = NgaJsonParser.asRecord(subForums[key]);
        if (fields === undefined) {
          continue;
        }
        const board: Board = new Board();
        const id: number = NgaJsonParser.readNumber(fields['0']);
        if (key.startsWith('t')) {
          board.stid = id;
        } else {
          board.fid = id;
        }
        board.name = NgaJsonParser.readString(fields['1']);
        if (id !== 0 && board.name.length > 0) {
          result.subBoardList.push(board);
        }
      }
    } catch (err) {
      // 可选子板块数据异常不影响已解析的话题列表。
    }
  }

  /**
   * 解析帖子详情 JSON。
   * 正式接口 data.__R 是数字键对象，data.__T 是单个话题元信息。
   * 作者与头像可能只有 authorid，需关联 data.__U；兼容旧版根节点和数组。
   */
  static parseThreadData(jsonStr: string): ThreadData {
    const result: ThreadData = new ThreadData();
    if (jsonStr.trim().length === 0) {
      result.error = '服务器返回了空响应';
      return result;
    }
    let preparedJson: string = '';
    let parsed: boolean = false;
    try {
      preparedJson = NgaJsonParser.cleanJsonWrapper(jsonStr);
      const decoded: Object = JSON.parse(preparedJson) as Object;
      parsed = true;
      const root: Record<string, Object> | undefined = NgaJsonParser.asRecord(decoded);
      if (root === undefined) {
        result.error = '服务器响应格式异常';
        return result;
      }
      const data: Record<string, Object> = NgaJsonParser.asRecord(root['data']) ?? root;
      const apiError: string = NgaJsonParser.getApiError(root, data, '__R');
      if (apiError.length > 0) {
        result.error = apiError;
        return result;
      }
      const replyRows: Object[] | undefined = NgaJsonParser.getIndexedRows(data['__R']);
      if (replyRows === undefined) {
        result.error = '服务器响应缺少有效的帖子内容';
        return result;
      }
      result.__ROWS = NgaJsonParser.readNumber(data['__ROWS']);
      const globals: Record<string, Object> | undefined =
        NgaJsonParser.asRecord(data['__GLOBAL']) ?? NgaJsonParser.asRecord(root['__GLOBAL']);
      if (globals !== undefined) {
        result.attachmentBase = NgaJsonParser.readString(globals['_ATTACH_BASE_VIEW']) ||
          NgaJsonParser.readString(globals['_ATTACH_BASE']) || result.attachmentBase;
      }
      const fRecord: Record<string, Object> | undefined = NgaJsonParser.asRecord(data['__F']);
      if (fRecord !== undefined) {
        for (const key of Object.keys(fRecord)) {
          const value: Object | undefined = fRecord[key];
          if (typeof value === 'string' || typeof value === 'number') {
            result.__F[key] = NgaJsonParser.readText(value);
          }
        }
      }

      const tRecord: Record<string, Object> | undefined = NgaJsonParser.asRecord(data['__T']);
      if (tRecord !== undefined) {
        result.threadInfo.tid = NgaJsonParser.readNumber(tRecord['tid']);
        result.threadInfo.subject = NgaJsonParser.readText(tRecord['subject']);
        result.threadInfo.author = NgaJsonParser.readString(tRecord['author']);
        result.threadInfo.authorId = NgaJsonParser.readNumber(tRecord['authorid']);
        result.threadInfo.replies = NgaJsonParser.readNumber(tRecord['replies']);
        result.threadInfo.lastPoster = NgaJsonParser.readString(tRecord['lastposter']);
        result.threadInfo.postDate = NgaJsonParser.readNumber(tRecord['postdate']);
        if (result.__F['fid'] === undefined && NgaJsonParser.readNumber(tRecord['fid']) !== 0) {
          result.__F['fid'] = NgaJsonParser.readText(tRecord['fid']);
        }
      }
      const users: Record<string, Object> | undefined = NgaJsonParser.asRecord(data['__U']);
      for (const item of replyRows) {
        const fields: Record<string, Object> | undefined = NgaJsonParser.asRecord(item);
        if (fields === undefined) {
          continue;
        }
        const content: Object | undefined = fields['content'];
        const subject: Object | undefined = fields['subject'];
        if (typeof content !== 'string' && typeof content !== 'number' &&
          typeof subject !== 'string' && typeof subject !== 'number') {
          continue;
        }
        const row: ThreadRowInfo = new ThreadRowInfo();
        row.tid = NgaJsonParser.readNumber(fields['tid']) || result.threadInfo.tid;
        row.authorId = NgaJsonParser.readNumber(fields['authorid']);
        row.content = NgaJsonParser.readText(content ?? subject);
        row.subject = NgaJsonParser.readText(subject);
        row.author = NgaJsonParser.readString(fields['author']);
        row.lou = NgaJsonParser.readPostIdentifier(fields['lou']);
        row.pid = NgaJsonParser.readPostIdentifier(fields['pid']);
        row.postdate = NgaJsonParser.readText(fields['postdate']);
        let avatar: string = NgaJsonParser.readString(fields['js_escap_avatar']) ||
          NgaJsonParser.readString(fields['avatar']);
        const user: Record<string, Object> | undefined = users !== undefined ?
          NgaJsonParser.asRecord(users[row.authorId.toString()]) : undefined;
        if (user !== undefined) {
          if (row.author.length === 0) {
            row.author = NgaJsonParser.readString(user['username']);
          }
          if (avatar.length === 0) {
            avatar = NgaJsonParser.readString(user['avatar']);
          }
        }
        row.avatar = AvatarUtils.parseAvatarUrl(avatar);
        result.rowList.push(row);
      }
      if (replyRows.length > 0 && result.rowList.length === 0) {
        result.error = '服务器返回的帖子内容格式异常';
        return result;
      }
      result.success = true;
    } catch (err) {
      result.responseIncomplete = !parsed &&
        NgaJsonParser.isIncompleteJsonResponse(preparedJson, (err as Error).message);
      result.error = result.responseIncomplete ? '服务器响应不完整，请重试' : '服务器响应解析失败，请重试';
    }
    return result;
  }

  /**
   * 解析用户主页（资料）JSON。
   * NGA 用户主页响应是 JS 变量字符串，需先清洗前缀和特殊标记。
   * 格式：window.script_muti_get_var_store={...data:{"0":{用户资料}}...}
   * 对应 Android JsonProfileLoadTask.parseJsonPage + buildBasicInfo。
   */
  static parseProfile(body: string): ProfileData {
    const result: ProfileData = new ProfileData();
    if (body.length === 0) {
      return result;
    }
    let jsonStr: string = body;
    // 去掉 window.script_muti_get_var_store= 前缀
    const prefix: string = 'window.script_muti_get_var_store=';
    if (jsonStr.startsWith(prefix)) {
      jsonStr = jsonStr.substring(prefix.length);
    }
    // 去掉 /*$js$*/ 注释
    jsonStr = jsonStr.replace(/\/\*\$\js\$\*\//g, '');
    try {
      const root: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
      const dataObj: Object | undefined = root['data'];
      if (dataObj === undefined) {
        return result;
      }
      const dataRecord: Record<string, Object> = dataObj as Record<string, Object>;
      const innerObj: Object | undefined = dataRecord['0'];
      if (innerObj === undefined) {
        return result;
      }
      const inner: Record<string, Object> = innerObj as Record<string, Object>;

      // 基本信息
      const uid: Object | undefined = inner['uid'];
      if (typeof uid === 'number') {
        result.uid = uid;
      }
      const username: Object | undefined = inner['username'];
      if (typeof username === 'string') {
        result.username = username;
      }
      const posts: Object | undefined = inner['posts'];
      if (typeof posts === 'number') {
        result.postCount = posts;
      }
      const group: Object | undefined = inner['group'];
      if (typeof group === 'string') {
        result.memberGroup = group;
      }
      const money: Object | undefined = inner['money'];
      if (typeof money === 'number') {
        result.money = money;
      }
      const fame: Object | undefined = inner['fame'];
      if (typeof fame === 'string') {
        result.fame = fame;
      }
      const email: Object | undefined = inner['email'];
      if (typeof email === 'string') {
        result.email = email;
      }
      const phone: Object | undefined = inner['phone'];
      if (typeof phone === 'string') {
        result.phone = phone;
      }
      const sign: Object | undefined = inner['sign'];
      if (typeof sign === 'string') {
        result.sign = sign;
      }
      const avatar: Object | undefined = inner['avatar'];
      if (typeof avatar === 'string') {
        result.avatar = AvatarUtils.parseAvatarUrl(avatar);
      }

      // 注册时间（regdate 可能是数字时间戳或字符串）
      const regdate: Object | undefined = inner['regdate'];
      if (typeof regdate === 'number') {
        result.registerDate = NgaJsonParser.timeStampToDate(regdate);
      } else if (typeof regdate === 'string') {
        result.registerDate = regdate;
      }

      // 账号状态：verified = -1 表示 NUKED，< -1 表示 MUTED
      const verified: Object | undefined = inner['verified'];
      if (typeof verified === 'number') {
        result.verified = verified;
        if (verified === -1) {
          result.nuked = true;
        } else if (verified < -1) {
          result.muted = true;
        }
      }
      // 禁言时间（buffs.0 或 muteTime）
      const buffs: Object | undefined = inner['buffs'];
      if (buffs !== undefined) {
        const buffsRecord: Record<string, Object> = buffs as Record<string, Object>;
        const muteVal: Object | undefined = buffsRecord['0'];
        if (typeof muteVal === 'string') {
          result.mutedTime = muteVal;
          result.muted = true;
        }
      }

      // 声望列表（reputation 数组：{"0":名称, "1":数值}）
      const reputation: Object | undefined = inner['reputation'];
      if (reputation !== undefined) {
        const repArray: Object[] = reputation as Object[];
        for (const item of repArray) {
          const repRecord: Record<string, Object> = item as Record<string, Object>;
          const rep: ReputationItem = new ReputationItem();
          const nameVal: Object | undefined = repRecord['0'];
          if (typeof nameVal === 'string') {
            rep.name = nameVal;
          }
          const valueVal: Object | undefined = repRecord['1'];
          if (typeof valueVal === 'string') {
            rep.value = valueVal;
          } else if (typeof valueVal === 'number') {
            rep.value = valueVal.toString();
          }
          result.reputationList.push(rep);
        }
      }

      // 管理板块列表
      const adminForums: Object | undefined = inner['adminForums'];
      if (adminForums !== undefined) {
        const adminArray: Object[] = adminForums as Object[];
        for (const item of adminArray) {
          const adminRecord: Record<string, Object> = item as Record<string, Object>;
          const admin: AdminForumItem = new AdminForumItem();
          const fidVal: Object | undefined = adminRecord['fid'];
          if (typeof fidVal === 'number') {
            admin.fid = fidVal;
          }
          const nameVal: Object | undefined = adminRecord['name'];
          if (typeof nameVal === 'string') {
            admin.name = nameVal;
          }
          result.adminForumList.push(admin);
        }
      }
    } catch (err) {
      // JSON 解析失败，返回空数据结构
    }
    return result;
  }

  /**
   * 时间戳转日期字符串（yyyy-MM-dd）。
   * 对应 Android timeStamp2Date1。
   */
  private static timeStampToDate(timestamp: number): string {
    if (timestamp === 0) {
      return '未知';
    }
    const date: Date = new Date(timestamp * 1000);
    const year: number = date.getFullYear();
    const month: number = date.getMonth() + 1;
    const day: number = date.getDate();
    const pad: (n: number) => string = (n: number): string => (n < 10 ? '0' + n.toString() : n.toString());
    return year.toString() + '-' + pad(month) + '-' + pad(day);
  }
}

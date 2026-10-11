/*
 * 头像 URL 解析工具。
 * 对应 Android FunctionUtils.parseAvatarUrl。
 *
 * NGA 服务器下发的 js_escap_avatar 字段是 JSON 转义字符串，形如：
 * { "t":1,"l":2,"0":{ "0":"http://pic2.178.com/.../xxx.jpg","cX":0.47,"cY":0.78},"1":{ "0":"http://..."}}
 * 或者直接就是纯 URL，或者空字符串。
 *
 * 解析规则：
 * 1. 空/空字符串返回空串
 * 2. 若字符串以 http 开头（纯 URL）返回原字符串
 * 3. 若不含 http 返回原字符串
 * 4. 否则取第一个 http 到其后第一个双引号之间的子串（多帧头像取第一帧 URL）
 */
export class AvatarUtils {
  /**
   * 从 js_escap_avatar 原始串解析出头像图片 URL。
   */
  static parseAvatarUrl(avatar: string): string {
    if (avatar === undefined || avatar === null || avatar.length === 0) {
      return '';
    }
    // 已是完整 URL（http/https）或相对路径开头
    if (avatar.indexOf('http') === 0) {
      return avatar;
    }
    // 不含 http，直接返回原串（可能是旧格式或相对路径）
    const httpIndex: number = avatar.indexOf('http');
    if (httpIndex < 0) {
      return avatar;
    }
    // 取 http 到其后第一个双引号之间的 URL
    const quoteIndex: number = avatar.indexOf('"', httpIndex);
    if (quoteIndex > httpIndex) {
      return avatar.substring(httpIndex, quoteIndex);
    }
    // 无后续双引号，取 http 到结尾
    return avatar.substring(httpIndex);
  }

  /**
   * 判断头像 URL 是否有效（非空且是 http/https）。
   */
  static isValidAvatar(url: string): boolean {
    if (url.length === 0) {
      return false;
    }
    return url.startsWith('http://') || url.startsWith('https://');
  }
}
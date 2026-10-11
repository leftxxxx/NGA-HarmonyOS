/*
 * 登录业务逻辑层：验证码加载、Cookie 解析、表单登录提交。
 * 对应 Android LoginPresenter / LoginModel 的业务职责。
 */

import http from '@ohos.net.http';
import { buffer } from '@kit.ArkTS';
import { UserIdentity } from './LoginStore';

/** 验证码图片请求地址（Android LoginModel.loadAuthCode 对齐） */
const AUTH_CODE_URL: string = 'https://bbs.ngacn.cc/login_check_code.php?id=';

/** 表单登录提交地址 */
const LOGIN_SUBMIT_URL: string = 'https://bbs.ngacn.cc/nuke.php';

/** WebView 登录站点地址（Android LoginWebFragment 对齐） */
export const WEB_LOGIN_URL: string = 'https://ngabbs.com/nuke.php?__lib=login&__act=account&login';

/** Cookie 提取所用域名 */
export const WEB_COOKIE_DOMAIN: string = 'https://ngabbs.com';

/** 表单登录结果值对象 */
export class FormLoginResult {
  success: boolean = false;
  uid: string = '';
  cid: string = '';
  userName: string = '';
  error: string = '';
}

/** HTTP 请求 header 接口（ArkTS 要求显式接口，不能用对象字面量赋 Object） */
interface FormHeader {
  'Content-Type': string;
}

/**
 * 登录业务服务。
 * - loadAuthCode: 加载验证码图片，返回 base64 data url
 * - parseCookie: 从 Cookie 串解析用户身份三件套
 * - formLogin: 账号密码表单登录提交
 */
export class LoginService {
  /** 验证码 Cookie（rid），由 loadAuthCode 记录、formLogin 使用 */
  private static rid: string = '';

  /**
   * 加载验证码图片。
   * 返回 base64 data url（data:image/png;base64,...），供 Image 组件直接渲染。
   * 同时记录验证码 Cookie（rid）。
   */
  static async loadAuthCode(): Promise<string> {
    const random: number = Math.floor(Math.random() * 1000000);
    const url: string = AUTH_CODE_URL + random.toString() + '/';
    const httpReq: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      };
      const result: http.HttpResponse = await httpReq.request(url, options);
      const raw: string | Object | ArrayBuffer = result.result;
      if (raw instanceof ArrayBuffer) {
        const arr: ArrayBuffer = raw as ArrayBuffer;
        const buf: buffer.Buffer = buffer.from(arr);
        const base64Str: string = buf.toString('base64');
        LoginService.extractRid(result.cookies);
        return 'data:image/png;base64,' + base64Str;
      }
      throw new Error('验证码响应非二进制');
    } finally {
      httpReq.destroy();
    }
  }

  /**
   * 从 Cookie 字符串解析用户身份三件套。
   * 键名：ngaPassportUid / ngaPassportCid / ngaPassportUrlencodedUname
   * 用户名经双重 URL 解码（Android 用 GBK 双重 URLDecoder，鸿蒙侧尽力而为用 UTF-8 解码）。
   */
  static parseCookie(cookieStr: string): UserIdentity {
    const user: UserIdentity = new UserIdentity();
    if (cookieStr.length === 0) {
      return user;
    }
    const parts: string[] = cookieStr.split(';');
    for (const part of parts) {
      const trimmed: string = part.trim();
      const eqIdx: number = trimmed.indexOf('=');
      if (eqIdx < 0) {
        continue;
      }
      const key: string = trimmed.substring(0, eqIdx);
      const val: string = trimmed.substring(eqIdx + 1);
      if (key === 'ngaPassportUid') {
        user.uid = val;
      } else if (key === 'ngaPassportCid') {
        user.cid = val;
      } else if (key === 'ngaPassportUrlencodedUname') {
        user.userName = LoginService.decodeUserName(val);
      }
    }
    return user;
  }

  /** 判断用户身份是否完整（三件套均非空） */
  static isComplete(user: UserIdentity): boolean {
    return user.uid.length > 0 && user.cid.length > 0 && user.userName.length > 0;
  }

  /**
   * 账号密码表单登录提交。
   * 字段与 Android LoginPresenter.login 对齐。
   * 成功判断依赖响应 Cookie 中是否包含完整的用户身份三件套。
   */
  static async formLogin(name: string, password: string, captcha: string): Promise<FormLoginResult> {
    const httpReq: http.HttpRequest = http.createHttp();
    try {
      const body: string = LoginService.buildFormBody(name, password, captcha);
      const headers: FormHeader = { 'Content-Type': 'application/x-www-form-urlencoded' };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: body
      };
      const result: http.HttpResponse = await httpReq.request(LOGIN_SUBMIT_URL, options);
      const loginResult: FormLoginResult = new FormLoginResult();

      // 从响应 Cookie 解析用户身份
      const user: UserIdentity = LoginService.parseCookie(result.cookies);
      if (LoginService.isComplete(user)) {
        loginResult.success = true;
        loginResult.uid = user.uid;
        loginResult.cid = user.cid;
        loginResult.userName = user.userName;
      } else {
        loginResult.success = false;
        // 尝试从响应体解析错误信息
        loginResult.error = LoginService.extractErrorMessage(result.result);
      }
      return loginResult;
    } finally {
      httpReq.destroy();
    }
  }

  /** 构建表单登录请求体（与 Android 提交字段对齐） */
  private static buildFormBody(name: string, password: string, captcha: string): string {
    const parts: string[] = [
      'name=' + encodeURIComponent(name),
      'type=name',
      'password=' + encodeURIComponent(password),
      'rid=' + LoginService.rid,
      'captcha=' + encodeURIComponent(captcha.toUpperCase()),
      '__lib=login',
      '__act=login',
      '__output=1',
      '__inchst=UTF-8',
      'raw=3',
      'qrkey='
    ];
    return parts.join('&');
  }

  /** 从验证码响应 Cookie 中提取 rid */
  private static extractRid(cookieStr: string): void {
    if (cookieStr.length === 0) {
      return;
    }
    const parts: string[] = cookieStr.split(';');
    for (const part of parts) {
      const trimmed: string = part.trim();
      const eqIdx: number = trimmed.indexOf('=');
      if (eqIdx < 0) {
        continue;
      }
      const key: string = trimmed.substring(0, eqIdx);
      const val: string = trimmed.substring(eqIdx + 1);
      if (key === 'rid') {
        LoginService.rid = val;
      }
    }
  }

  /**
   * 用户名双重 URL 解码。
   * Android 用 GBK 双重 URLDecoder；鸿蒙无原生 GBK 支持，用 UTF-8 decodeURIComponent 尽力解码。
   * spec 约定解码为实现细节，仅要求"用户名可正确展示为可读中文/字符"。
   */
  static decodeUserName(encoded: string): string {
    if (encoded.length === 0) {
      return '';
    }
    try {
      const first: string = decodeURIComponent(encoded);
      try {
        const second: string = decodeURIComponent(first);
        return second;
      } catch (err2) {
        return first;
      }
    } catch (err) {
      return encoded;
    }
  }

  /** 从登录响应体中提取错误提示文本（尽力而为） */
  private static extractErrorMessage(result: string | Object | ArrayBuffer): string {
    if (typeof result === 'string') {
      // NGA JSON 响应格式：{"data":...,"error":...} 或纯文本
      const errorIdx: number = result.indexOf('"error"');
      if (errorIdx >= 0) {
        const colonIdx: number = result.indexOf(':', errorIdx);
        if (colonIdx >= 0) {
          const quoteStart: number = result.indexOf('"', colonIdx + 1);
          const quoteEnd: number = result.indexOf('"', quoteStart + 1);
          if (quoteStart >= 0 && quoteEnd > quoteStart) {
            return result.substring(quoteStart + 1, quoteEnd);
          }
        }
      }
      return result.substring(0, Math.min(result.length, 100));
    }
    return '登录失败';
  }
}
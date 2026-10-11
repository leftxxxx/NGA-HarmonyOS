/*
 * HTTP 客户端封装：自动注入 Cookie 和 User-Agent。
 * 对应 Android HttpUtil.getHtml() 和 HttpPostClient：向 NGA API 发起 GET/POST 请求时自动携带 Cookie 和 User-Agent。
 */

import http from '@ohos.net.http';
import util from '@ohos.util';
import { BusinessError } from '@kit.BasicServicesKit';
import { LoginStore } from './LoginStore';
import { SettingsStore, SettingKeys, SettingDefaults } from './AppSettings';
import { GbkEncoder } from './GbkEncoder';

const USER_AGENT: string = 'Nga_Official/80023';

/** HTTP 请求 header 类型（使用 Record 避免 ArkTS 索引访问限制） */
type RequestHeader = Record<string, string>;

/** HTTP 请求结果 */
export class HttpResult {
  success: boolean = false;
  statusCode: number = 0;
  body: string = '';
  error: string = '';
  /** 受控诊断元数据；不会包含响应正文、Cookie 或请求字段。 */
  failureStage: string = '';
  nativeErrorCode: number = 0;
}

/** POST 请求参数键值对 */
export type PostFieldMap = Record<string, string>;

/** 域名候选列表（与 SettingsPage DOMAIN_OPTIONS 对齐） */
const DOMAIN_LIST: string[] = [
  'https://bbs.ngacn.cc',
  'https://bbs.nga.cn',
  'https://nga.178.com',
  'https://nga.donews.com',
  'https://ngabbs.com'
];

/**
 * HTTP 客户端单例。
 * - get: 发起 GET 请求，自动注入 Cookie 和 User-Agent
 * - post: 发起 POST 请求，自动注入 Cookie 和 User-Agent，支持 GBK 编码
 * - getDomain: 从 SettingsStore 读取当前域名
 */
export class HttpClient {
  /**
   * 发起 GET 请求。
   * 自动从 LoginStore 读取 Cookie，设置 User-Agent。
   * 成功返回响应体字符串，失败返回错误信息。
   *
   * @param url 请求 URL
   * @param extraHeaders 额外请求头（如 Referer）
   * @param usingCache 是否使用系统 HTTP 缓存；在线阅读需显式关闭，确保重试重新请求。
   */
  static async get(url: string, extraHeaders?: Record<string, string>, usingCache: boolean = true): Promise<HttpResult> {
    const result: HttpResult = new HttpResult();
    const httpReq: http.HttpRequest = http.createHttp();
    try {
      const cookie: string = LoginStore.getCookie();
      const header: RequestHeader = {
        'User-Agent': USER_AGENT,
        'Cookie': cookie,
        'Accept-Charset': 'GBK'
      };
      // 合并额外请求头
      if (extraHeaders !== undefined) {
        for (const key of Object.keys(extraHeaders)) {
          header[key] = extraHeaders[key];
        }
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: usingCache,
        connectTimeout: 10000,
        readTimeout: 15000
      };
      const response: http.HttpResponse = await httpReq.request(url, options);
      result.statusCode = response.responseCode;
      result.body = HttpClient.decodeResponse(response);
      if (response.responseCode === 200) {
        result.success = true;
      } else {
        result.error = 'HTTP ' + response.responseCode.toString();
      }
    } catch (err) {
      result.error = '网络请求异常: ' + (err as Error).message;
    } finally {
      httpReq.destroy();
    }
    return result;
  }

  /**
   * 发起 POST 请求（application/x-www-form-urlencoded 格式）。
   * 自动从 LoginStore 读取 Cookie，设置 User-Agent。
   * 参数值使用 GBK 编码（对应 Android PostParam.toString() 的 GBK 编码逻辑）。
   *
   * @param url 请求 URL
   * @param fields POST 参数键值对
   * @param useGbk 是否使用 GBK 编码参数值（默认 true，对应 NGA POST 接口要求）
   */
  static async post(url: string, fields: PostFieldMap, useGbk: boolean = true): Promise<HttpResult> {
    const result: HttpResult = new HttpResult();
    const httpReq: http.HttpRequest = http.createHttp();
    let requestStage: string = 'request';
    try {
      const cookie: string = LoginStore.getCookie();
      const header: RequestHeader = {
        'User-Agent': USER_AGENT,
        'Cookie': cookie,
        'Accept-Charset': 'GBK',
        'Content-Type': 'application/x-www-form-urlencoded'
      };
      // 构建 POST body
      const body: string = HttpClient.buildPostBody(fields, useGbk);
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 15000
      };
      // HTTP SDK 不接受 extraData: ''；安卓 @POST 无 @Body 的预检也是无正文请求。
      if (body.length > 0) {
        options.extraData = body;
      } else {
        // NGA 预检要求声明空 POST 的长度；OkHttp 同样会自动发送 Content-Length: 0。
        header['Content-Length'] = '0';
      }
      const response: http.HttpResponse = await httpReq.request(url, options);
      result.statusCode = response.responseCode;
      requestStage = 'decode';
      result.body = HttpClient.decodeResponse(response);
      if (response.responseCode === 200) {
        result.success = true;
      } else {
        result.failureStage = 'http';
        result.error = 'HTTP ' + response.responseCode.toString();
      }
    } catch (err) {
      const nativeError: BusinessError = err as BusinessError;
      result.failureStage = requestStage;
      result.nativeErrorCode = typeof nativeError.code === 'number' && Number.isSafeInteger(nativeError.code) ?
        nativeError.code : 0;
      result.error = '网络请求异常: ' + (err as Error).message;
    } finally {
      httpReq.destroy();
    }
    return result;
  }

  /** NGA 接口默认返回 GBK 字节，不能让网络层按 UTF-8 自动转成字符串。 */
  private static decodeResponse(response: http.HttpResponse): string {
    const raw: string | Object | ArrayBuffer = response.result;
    if (typeof raw === 'string') {
      return raw;
    }
    if (!(raw instanceof ArrayBuffer)) {
      throw new Error('响应体不是有效的文本数据');
    }
    let encoding: string = 'gbk';
    const headers: Record<string, Object> = response.header as Record<string, Object>;
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() === 'content-type') {
        const value: Object = headers[key];
        if (typeof value === 'string') {
          const charset: RegExpMatchArray | null = value.match(/charset\s*=\s*["']?([^;"'\s]+)/i);
          if (charset !== null) {
            encoding = charset[1].toLowerCase();
          }
        }
      }
    }
    const decoder: util.TextDecoder = util.TextDecoder.create(encoding, { ignoreBOM: true });
    return decoder.decodeToString(new Uint8Array(raw), { stream: false });
  }

  /**
   * 构建 POST 请求体（application/x-www-form-urlencoded 格式）。
   * 参数值使用 GBK 或 UTF-8 百分号编码。
   */
  private static buildPostBody(fields: PostFieldMap, useGbk: boolean): string {
    const parts: string[] = [];
    for (const key of Object.keys(fields)) {
      const value: string = fields[key];
      if (useGbk) {
        parts.push(key + '=' + GbkEncoder.encode(value));
      } else {
        parts.push(key + '=' + encodeURIComponent(value));
      }
    }
    return parts.join('&');
  }

  /**
   * 从 SettingsStore 读取当前域名。
   * 默认返回 https://bbs.nga.cn（索引1）。
   */
  static getDomain(): string {
    const index: number = SettingsStore.getInt(SettingKeys.DOMAIN, SettingDefaults.DOMAIN);
    if (index >= 0 && index < DOMAIN_LIST.length) {
      return DOMAIN_LIST[index];
    }
    return DOMAIN_LIST[1];
  }
}

/*
 * 帖子缓存存储工具。
 * 对应 Android ArticleListModel.cachePage / loadCachePage + TopicListModel.loadCache / removeCacheTopic。
 *
 * 缓存目录结构（与安卓端一致）：
 *   {filesDir}/cache/{tid}/{tid}.json  — 话题描述（ThreadPageInfo JSON）
 *   {filesDir}/cache/{tid}/{page}.json — 页面原始 JSON 响应
 *
 * 用户手动缓存（帖子详情页"缓存本页"按钮），读取时复用与网络请求相同的 JSON 解析逻辑。
 * 无自动过期机制。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ThreadPageInfo } from './ThreadPageInfo';

export class ArticleCacheStore {
  private static ctx: common.UIAbilityContext | null = null;

  static init(ctx: common.UIAbilityContext): void {
    ArticleCacheStore.ctx = ctx;
  }

  private static getCacheDir(): string {
    if (ArticleCacheStore.ctx === null) {
      return '';
    }
    return ArticleCacheStore.ctx.filesDir + '/cache';
  }

  private static getTopicDir(tid: number): string {
    return ArticleCacheStore.getCacheDir() + '/' + tid.toString();
  }

  /**
   * 缓存一页帖子数据。
   * @param tid 话题 ID
   * @param page 页码
   * @param rawData 页面原始 JSON 响应（来自网络请求）
   * @param topicInfoJson 话题描述 JSON 字符串（ThreadPageInfo 序列化）
   */
  static cachePage(tid: number, page: number, rawData: string, topicInfoJson: string): boolean {
    const topicDir: string = ArticleCacheStore.getTopicDir(tid);
    try {
      // 确保目录存在
      if (!fs.accessSync(topicDir)) {
        fs.mkdirSync(topicDir, true);
      }
      // 写入话题描述文件（仅首次缓存时写入，或覆盖更新）
      const descPath: string = topicDir + '/' + tid.toString() + '.json';
      const descFile: fs.File = fs.openSync(descPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(descFile.fd, topicInfoJson);
      fs.closeSync(descFile);

      // 写入页面数据文件
      const pagePath: string = topicDir + '/' + page.toString() + '.json';
      const pageFile: fs.File = fs.openSync(pagePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(pageFile.fd, rawData);
      fs.closeSync(pageFile);

      return true;
    } catch (err) {
      return false;
    }
  }

  /**
   * 从缓存加载一页帖子数据。
   * @param tid 话题 ID
   * @param page 页码
   * @returns 原始 JSON 字符串，若缓存不存在则返回空字符串
   */
  static loadCachePage(tid: number, page: number): string {
    const pagePath: string = ArticleCacheStore.getTopicDir(tid) + '/' + page.toString() + '.json';
    try {
      if (!fs.accessSync(pagePath)) {
        return '';
      }
      const file: fs.File = fs.openSync(pagePath, fs.OpenMode.READ_ONLY);
      const stat: fs.Stat = fs.statSync(pagePath);
      const buf: Uint8Array = new Uint8Array(stat.size);
      fs.readSync(file.fd, buf.buffer);
      fs.closeSync(file);
      const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return textDecoder.decodeToString(buf);
    } catch (err) {
      return '';
    }
  }

  /**
   * 加载所有缓存话题列表。
   * 扫描缓存目录，读取每个话题的描述文件，返回 ThreadPageInfo 列表。
   */
  static loadCacheTopicList(): ThreadPageInfo[] {
    const result: ThreadPageInfo[] = [];
    const cacheDir: string = ArticleCacheStore.getCacheDir();
    try {
      if (!fs.accessSync(cacheDir)) {
        return result;
      }
      const names: string[] = fs.listFileSync(cacheDir);
      for (const name of names) {
        const topicDir: string = cacheDir + '/' + name;
        const descPath: string = topicDir + '/' + name + '.json';
        try {
          if (!fs.accessSync(descPath)) {
            continue;
          }
          const file: fs.File = fs.openSync(descPath, fs.OpenMode.READ_ONLY);
          const stat: fs.Stat = fs.statSync(descPath);
          const buf: Uint8Array = new Uint8Array(stat.size);
          fs.readSync(file.fd, buf.buffer);
          fs.closeSync(file);
          const textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');
          const jsonStr: string = textDecoder.decodeToString(buf);
          const info: ThreadPageInfo = ArticleCacheStore.parseTopicInfo(jsonStr);
          if (info.tid > 0) {
            result.push(info);
          }
        } catch (err) {
          // 单个话题读取失败，跳过
        }
      }
    } catch (err) {
      // 缓存目录读取失败
    }
    return result;
  }

  /**
   * 删除指定话题的缓存目录。
   */
  static removeCacheTopic(tid: number): boolean {
    const topicDir: string = ArticleCacheStore.getTopicDir(tid);
    try {
      if (!fs.accessSync(topicDir)) {
        return false;
      }
      ArticleCacheStore.removeRecursively(topicDir);
      return true;
    } catch (err) {
      return false;
    }
  }

  /**
   * 检查指定话题的指定页是否有缓存。
   */
  static hasCachePage(tid: number, page: number): boolean {
    const pagePath: string = ArticleCacheStore.getTopicDir(tid) + '/' + page.toString() + '.json';
    try {
      return fs.accessSync(pagePath);
    } catch (err) {
      return false;
    }
  }

  /* ---------- 私有工具方法 ---------- */

  private static removeRecursively(path: string): void {
    try {
      const stat: fs.Stat = fs.statSync(path);
      if (stat.isDirectory()) {
        const names: string[] = fs.listFileSync(path);
        for (const name of names) {
          ArticleCacheStore.removeRecursively(path + '/' + name);
        }
        fs.rmdirSync(path);
      } else {
        fs.unlinkSync(path);
      }
    } catch (err) {
      // 忽略删除错误
    }
  }

  /**
   * 解析话题描述 JSON 为 ThreadPageInfo。
   * 格式与安卓端 ThreadPageInfo JSON 序列化一致。
   */
  private static parseTopicInfo(jsonStr: string): ThreadPageInfo {
    const info: ThreadPageInfo = new ThreadPageInfo();
    if (jsonStr.length === 0) {
      return info;
    }
    try {
      const root: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;

      const tid: Object | undefined = root['tid'];
      if (typeof tid === 'number') {
        info.tid = tid;
      }

      const subject: Object | undefined = root['subject'];
      if (typeof subject === 'string') {
        info.subject = subject;
      }

      const author: Object | undefined = root['author'];
      if (typeof author === 'string') {
        info.author = author;
      }

      const authorId: Object | undefined = root['authorid'];
      if (typeof authorId === 'number') {
        info.authorId = authorId;
      }

      const replies: Object | undefined = root['replies'];
      if (typeof replies === 'number') {
        info.replies = replies;
      }

      const lastPoster: Object | undefined = root['lastposter'];
      if (typeof lastPoster === 'string') {
        info.lastPoster = lastPoster;
      }

      const postDate: Object | undefined = root['postdate'];
      if (typeof postDate === 'number') {
        info.postDate = postDate;
      }

      const page: Object | undefined = root['page'];
      if (typeof page === 'number') {
        info.page = page;
      }
    } catch (err) {
      // JSON 解析失败
    }
    return info;
  }
}

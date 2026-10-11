/*
 * NGA API URL 构建工具。
 * 对应 Android HttpUtil 中的 URL 拼接逻辑：根据当前域名拼接 NGA API 请求地址。
 * 涵盖话题列表、帖子详情、搜索、收藏、支持/反对、回复/发帖、通知等全部 NGA API。
 */

import { HttpClient } from './HttpClient';

/**
 * URL 构建工具。
 * 涵盖 NGA 全部 API 端点：
 * - 话题列表 / 帖子详情 / 板块图标（已有）
 * - 搜索（主题搜索 / 板块搜索）
 * - 收藏话题 / 取消收藏
 * - 支持 / 反对帖子
 * - 回复 / 发帖（提交）
 * - 通知查询
 * - 短消息列表
 */
export class UrlBuilder {
  /* ---------- 已有：话题列表 / 帖子详情 / 板块图标 ---------- */

  /**
   * 构建话题列表 URL。
   * 子板块优先使用 stid，普通板块使用 fid（包括负数 fid）。
   */
  static buildTopicListUrl(fid: number, page: number, stid: number = 0): string {
    const domain: string = HttpClient.getDomain();
    const boardParam: string = stid !== 0 ? 'stid=' + stid.toString() : 'fid=' + fid.toString();
    return domain + '/thread.php?' + boardParam + '&page=' + page.toString() + '&lite=js&noprefix';
  }

  /**
   * 构建帖子详情 URL。
   * 格式：{domain}/read.php?page={page}&__output=8&noprefix&v2&tid={tid}
   */
  static buildArticleUrl(tid: number, page: number): string {
    const domain: string = HttpClient.getDomain();
    return domain + '/read.php?page=' + page.toString() + '&__output=8&noprefix&v2&tid=' + tid.toString();
  }

  /**
   * 构建板块图标 URL。
   * 格式：http://img4.nga.178.com/ngabbs/nga_classic/f/app/{fid}.png
   */
  static buildBoardIconUrl(fid: number): string {
    return 'http://img4.nga.178.com/ngabbs/nga_classic/f/app/' + fid.toString() + '.png';
  }

  /**
   * 构建子板块图标 URL。
   * 格式：https://img4.nga.178.com/proxy/cache_attach/ficon/{stid}v.png
   * 对应 Android ApiConstants.URL_BOARD_ICON_STID。
   */
  static buildSubBoardIconUrl(stid: number): string {
    return 'https://img4.nga.178.com/proxy/cache_attach/ficon/' + stid.toString() + 'v.png';
  }

  /* ---------- 搜索 ---------- */

  /**
   * 构建主题搜索 URL（关键词用 UTF-8 编码）。
   * 格式：{domain}/thread.php?key={key}&page={page}&lite=js&noprefix
   * 或带板块：{domain}/thread.php?fid={fid}&key={key}&content={0|1}&page={page}&lite=js&noprefix
   */
  static buildTopicSearchUrl(keyword: string, page: number, fid: number = 0, content: number = 0): string {
    const domain: string = HttpClient.getDomain();
    let url: string = domain + '/thread.php?';
    if (fid > 0) {
      url += 'fid=' + fid.toString() + '&';
    }
    url += 'key=' + encodeURIComponent(keyword) + '&content=' + content.toString() + '&page=' + page.toString() + '&lite=js&noprefix';
    return url;
  }

  /**
   * 构建板块搜索 URL（关键词用 GBK 编码）。
   * 格式：{domain}/forum.php?&__output=8&key={key}
   * 注意：板块搜索的关键词需要 GBK 编码，此处返回不含 key 的基础 URL，
   * 调用方需自行拼接 GBK 编码后的 key。
   */
  static buildBoardSearchBaseUrl(): string {
    const domain: string = HttpClient.getDomain();
    return domain + '/forum.php?&__output=8&key=';
  }

  /* ---------- 收藏话题 ---------- */

  /**
   * 构建收藏话题 URL。
   * 格式：{domain}/nuke.php?__lib=topic_favor&lite=js&noprefix&__act=topic_favor&action=add&tid={tid}
   * 请求方式：POST
   */
  static buildAddFavoriteUrl(tid: number): string {
    const domain: string = HttpClient.getDomain();
    return domain + '/nuke.php?__lib=topic_favor&lite=js&noprefix&__act=topic_favor&action=add&tid=' + tid.toString();
  }

  /**
   * 构建取消收藏 URL。
   * 格式：{domain}/nuke.php
   * 请求方式：POST，参数通过 fields 传递
   * 参数：__lib=topic_favor, __act=topic_favor, __output=8, action=del, page={page}, tidarray={tid}
   */
  static buildRemoveFavoriteUrl(): string {
    const domain: string = HttpClient.getDomain();
    return domain + '/nuke.php';
  }

  /* ---------- 支持/反对 ---------- */

  /**
   * 构建支持/反对帖子 URL。
   * 格式：{domain}/nuke.php
   * 请求方式：POST，参数通过 fields 传递
   * 参数：__lib=topic_recommend, __act=add, raw=3, __output=8, value={1|-1}, tid={tid}, pid={pid}
   * pid=0 仅用于楼主正文，回复必须传入对应回复的非零 pid。
   * value=1 表示支持，value=-1 表示反对
   */
  static buildLikeUrl(): string {
    const domain: string = HttpClient.getDomain();
    return domain + '/nuke.php';
  }

  /* ---------- 回复/发帖 ---------- */

  /**
   * 构建提交发帖/回复 URL。
   * 格式：{domain}/post.php
   * 请求方式：POST，body 通过 fields 传递
   * 参数：step=2, post_content={GBK编码内容}, tid/pid/fid/action 等
   */
  static buildPostSubmitUrl(): string {
    const domain: string = HttpClient.getDomain();
    return domain + '/post.php';
  }

  /* ---------- 通知 ---------- */

  /**
   * 构建通知查询 URL。
   * 格式：{domain}/nuke.php?__lib=noti&__output=8&__act=get_all
   * 请求方式：GET
   */
  static buildNotificationUrl(): string {
    const domain: string = HttpClient.getDomain();
    return domain + '/nuke.php?__lib=noti&__output=8&__act=get_all';
  }

  /* ---------- 短消息 ---------- */

  /**
   * 构建短消息列表 URL。
   * 格式：{domain}/nuke.php?__lib=message&__act=message&act=list&lite=js&page={page}
   * 请求方式：GET
   */
  static buildMessageListUrl(page: number): string {
    const domain: string = HttpClient.getDomain();
    return domain + '/nuke.php?__lib=message&__act=message&act=list&lite=js&page=' + page.toString();
  }

  /** 读取短消息会话。第一页包含最初发送的正文，后续页由 nextPage 指示。 */
  static buildMessageReadUrl(mid: number, page: number = 1): string {
    const domain: string = HttpClient.getDomain();
    return domain + '/nuke.php?__lib=message&__act=message&act=read&lite=js&page=' +
      page.toString() + '&mid=' + mid.toString();
  }

  /** 回复现有短消息会话，message/reply 参数由 POST 表单传递。 */
  static buildMessageReplyUrl(): string {
    return HttpClient.getDomain() + '/nuke.php';
  }

  /* ---------- 用户主页 ---------- */

  /**
   * 构建用户主页（资料）URL。
   * 格式：{domain}/nuke.php?__lib=ucp&__act=get&lite=js&noprefix&uid={uid}
   * 请求方式：GET，需 Referer 头：{domain}/nuke.php?func=ucp&lite=jsx&uid={uid}
   */
  static buildUserProfileUrl(uid: number): string {
    const domain: string = HttpClient.getDomain();
    return domain + '/nuke.php?__lib=ucp&__act=get&lite=js&noprefix&uid=' + uid.toString();
  }

  /**
   * 构建用户主页请求的 Referer 头。
   * 格式：{domain}/nuke.php?func=ucp&lite=jsx&uid={uid}
   */
  static buildUserProfileReferer(uid: number): string {
    const domain: string = HttpClient.getDomain();
    return domain + '/nuke.php?func=ucp&lite=jsx&uid=' + uid.toString();
  }
}

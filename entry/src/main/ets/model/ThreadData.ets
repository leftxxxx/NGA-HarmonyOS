/*
 * 帖子数据聚合模型。
 * 对应 Android ThreadData.java：rowList（帖子行列表）、threadInfo（话题信息）、__ROWS（总行数）、__F（板块信息）。
 */

import { ThreadRowInfo } from './ThreadRowInfo';
import { ThreadPageInfo } from './ThreadPageInfo';

export class ThreadData {
  success: boolean = false;
  error: string = '';
  /** 仅明确在 JSON 末尾中断时置位，供读帖请求进行一次有界恢复。 */
  responseIncomplete: boolean = false;
  attachmentBase: string = 'https://img.nga.cn/attachments/';
  rowList: ThreadRowInfo[] = [];
  threadInfo: ThreadPageInfo = new ThreadPageInfo();
  __ROWS: number = 0;
  __F: Record<string, string> = {};
}

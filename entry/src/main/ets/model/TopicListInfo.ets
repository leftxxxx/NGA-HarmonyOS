/*
 * 话题列表聚合模型。
 * 对应 Android TopicListInfo.java：name（板块名）、threadPageList（话题列表）、subBoardList（子板块列表）。
 */

import { ThreadPageInfo } from './ThreadPageInfo';
import { Board } from './Board';

export class TopicListInfo {
  success: boolean = false;
  error: string = '';
  name: string = '';
  threadPageList: ThreadPageInfo[] = [];
  subBoardList: Board[] = [];
}

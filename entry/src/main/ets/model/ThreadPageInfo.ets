/*
 * 话题数据模型。
 * 对应 Android ThreadPageInfo.java：tid、author、authorId、replies、subject、lastPoster、postDate、page。
 */

export class ThreadPageInfo {
  tid: number = 0;
  author: string = '';
  authorId: number = 0;
  replies: number = 0;
  subject: string = '';
  lastPoster: string = '';
  postDate: number = 0;
  page: number = 1;
}
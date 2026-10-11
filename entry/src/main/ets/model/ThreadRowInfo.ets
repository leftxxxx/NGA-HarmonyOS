/*
 * 帖子回复行数据模型。
 * 对应 Android ThreadRowInfo.java：tid、author、authorId、content、lou（楼层号）、avatar、postdate、attachs。
 */

export class ThreadRowInfo {
  tid: number = 0;
  author: string = '';
  authorId: number = 0;
  content: string = '';
  // 未知身份不能与合法的楼主（lou=0、pid=0）混淆。
  lou: number = -1;
  avatar: string = '';
  postdate: string = '';
  subject: string = '';
  pid: number = -1;
}

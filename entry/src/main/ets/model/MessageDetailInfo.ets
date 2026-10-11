/* 短消息会话详情，正文保持论坛原文，交给统一的富文本渲染器处理。 */

export class NgaMessagePost {
  key: string = '';
  index: number = 1;
  subject: string = '';
  content: string = '';
  authorId: number = 0;
  author: string = '';
  avatar: string = '';
  time: number = 0;
}

export class NgaMessageDetailData {
  success: boolean = false;
  errorMessage: string = '';
  mid: number = 0;
  subject: string = '';
  posts: NgaMessagePost[] = [];
  currentPage: number = 1;
  nextPage: number = 0;
  rowsPerPage: number = 20;
}

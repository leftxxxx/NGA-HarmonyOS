/*
 * 通知数据模型。
 * 对应 Android ForumNotificationFactory 解析的通知数据。
 */

/**
 * 被喷提醒（回复通知）项。
 * 对应 Android RecentReplyInfo。
 */
export class ReplyNotification {
  type: number = 0;       // 通知类型
  userId: number = 0;     // 用户ID
  userName: string = '';  // 用户名
  title: string = '';     // 帖子标题
  tid: number = 0;        // 话题ID
  pid: number = 0;        // 帖子ID
  timeStamp: number = 0;  // 时间戳
}

/**
 * 短消息项。
 * 对应 Android NotificationInfo。
 */
export class MessageNotification {
  mid: number = 0;              // 消息ID
  subject: string = '';          // 消息主题
  fromUserName: string = '';     // 发送者用户名
  lastFromUserName: string = ''; // 最近发送者用户名
  time: number = 0;              // 时间
  lastModify: number = 0;        // 最近修改时间
  posts: number = 0;             // 消息数
}

/**
 * 通知聚合数据。
 * 包含未读数、被喷提醒列表和短消息列表。
 */
export class NotificationData {
  unread: number = 0;
  replyList: ReplyNotification[] = [];
  messageList: MessageNotification[] = [];
}
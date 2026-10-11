import { HttpClient } from './HttpClient';
import { NgaTopicAttachment, TopicAttachmentProtocol } from './TopicAttachmentProtocol';

/** 发帖表单始终保存原始文本；编码由 HttpClient 在提交时统一执行。 */
export class NgaTopicPostInput {
  action: string = 'new';
  fid: number = 0;
  stid: number = 0;
  tid: number = 0;
  pid: number = 0;
  subject: string = '';
  content: string = '';
  anonymous: boolean = false;
  attachments: NgaTopicAttachment[] = [];
}

/** 对照安卓 PostParam/getPostInfo 的文字发帖协议，兼容负 fid 与 stid 子板块。 */
export class TopicPostProtocol {
  static validate(input: NgaTopicPostInput): string {
    if (input.action !== 'new' && input.action !== 'reply' && input.action !== 'modify') {
      return '发帖操作无效，请返回板块重新打开';
    }
    if (!Number.isSafeInteger(input.fid) || !Number.isSafeInteger(input.stid) || input.stid < 0 ||
      !Number.isSafeInteger(input.tid) || input.tid < 0 || !Number.isSafeInteger(input.pid) || input.pid < 0) {
      return '板块或话题编号无效，请返回后重试';
    }
    if (input.action === 'new' && input.fid === 0 && input.stid === 0) {
      return '未指定发帖板块，请返回板块重新打开';
    }
    if (input.action !== 'new' && input.tid === 0) {
      return '未指定话题，请返回话题重新打开';
    }
    if (input.action === 'new' && input.subject.trim().length === 0) {
      return '请输入帖子标题';
    }
    if (input.content.trim().length === 0) {
      return '请输入帖子内容';
    }
    return '';
  }

  /** 安卓预检为不含 step=2 的空 body POST；auth 只用于附件上传。 */
  static buildPrepareUrl(input: NgaTopicPostInput): string {
    let url: string = HttpClient.getDomain() + '/post.php?fid=' + input.fid.toString() +
      '&lite=js&action=' + input.action;
    if (input.pid > 0) {
      url += '&pid=' + input.pid.toString();
    }
    if (input.tid > 0) {
      url += '&tid=' + input.tid.toString();
    }
    if (input.stid > 0) {
      url += '&stid=' + input.stid.toString();
    }
    return url;
  }

  static buildFields(input: NgaTopicPostInput): Record<string, string> {
    const fields: Record<string, string> = {
      'step': '2', 'post_content': input.content, 'action': input.action
    };
    if (input.action === 'new' || input.subject.length > 0) {
      fields['post_subject'] = input.subject;
    }
    if (input.fid !== 0) {
      fields['fid'] = input.fid.toString();
    }
    if (input.stid > 0) {
      fields['stid'] = input.stid.toString();
    }
    if (input.action !== 'new' && input.tid > 0) {
      fields['tid'] = input.tid.toString();
    }
    if (input.action !== 'new' && input.pid > 0) {
      fields['pid'] = input.pid.toString();
    }
    if (input.anonymous) {
      fields['anony'] = '1';
    }
    let attachments: string = '';
    let attachmentsCheck: string = '';
    const included: Set<string> = new Set<string>();
    for (const attachment of input.attachments) {
      if (TopicAttachmentProtocol.isReferenced(input.content, attachment) && !included.has(attachment.url)) {
        attachments += '\t' + attachment.attachments;
        attachmentsCheck += '\t' + attachment.attachmentsCheck;
        included.add(attachment.url);
      }
    }
    if (attachments.length > 0) {
      fields['attachments'] = attachments;
      fields['attachments_check'] = attachmentsCheck;
    }
    return fields;
  }
}

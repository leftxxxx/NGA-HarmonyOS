import { NgaTopicAttachment } from './TopicAttachmentProtocol';

export class NgaTopicPostDraft {
  subject: string = '';
  content: string = '';
  anonymous: boolean = false;
  uncertain: boolean = false;
  attachments: NgaTopicAttachment[] = [];
}

// Drafts stay in this process only. Keep the caller's board context unchanged,
// including negative fid values and stid-only boards.
export class TopicPostStore {
  private static drafts: Map<string, NgaTopicPostDraft> = new Map<string, NgaTopicPostDraft>();
  private static revisions: Map<string, number> = new Map<string, number>();

  static load(accountKey: string, action: string, fid: number, stid: number,
    tid: number, pid: number): NgaTopicPostDraft {
    if (accountKey.length === 0) {
      return new NgaTopicPostDraft();
    }
    const savedDraft: NgaTopicPostDraft | undefined = TopicPostStore.drafts.get(
      TopicPostStore.draftKey(accountKey, action, fid, stid, tid, pid));
    if (savedDraft === undefined) {
      return new NgaTopicPostDraft();
    }
    return TopicPostStore.copyDraft(savedDraft);
  }

  static save(accountKey: string, action: string, fid: number, stid: number,
    tid: number, pid: number, draft: NgaTopicPostDraft): void {
    if (accountKey.length === 0) {
      return;
    }
    TopicPostStore.drafts.set(TopicPostStore.draftKey(accountKey, action, fid, stid, tid, pid),
      TopicPostStore.copyDraft(draft));
  }

  static remove(accountKey: string, action: string, fid: number, stid: number,
    tid: number, pid: number): void {
    if (accountKey.length === 0) {
      return;
    }
    TopicPostStore.drafts.delete(TopicPostStore.draftKey(accountKey, action, fid, stid, tid, pid));
  }

  static markPublished(accountKey: string, fid: number, stid: number): void {
    if (accountKey.length === 0) {
      return;
    }
    const revisionKey: string = TopicPostStore.boardKey(accountKey, fid, stid);
    const previousRevision: number = TopicPostStore.revisions.get(revisionKey) ?? 0;
    TopicPostStore.revisions.set(revisionKey, previousRevision + 1);
  }

  static getRevision(accountKey: string, fid: number, stid: number): number {
    if (accountKey.length === 0) {
      return 0;
    }
    return TopicPostStore.revisions.get(TopicPostStore.boardKey(accountKey, fid, stid)) ?? 0;
  }

  private static copyDraft(draft: NgaTopicPostDraft): NgaTopicPostDraft {
    const copiedDraft: NgaTopicPostDraft = new NgaTopicPostDraft();
    copiedDraft.subject = draft.subject;
    copiedDraft.content = draft.content;
    copiedDraft.anonymous = draft.anonymous;
    copiedDraft.uncertain = draft.uncertain;
    copiedDraft.attachments = draft.attachments.map((item: NgaTopicAttachment): NgaTopicAttachment => {
      const attachment: NgaTopicAttachment = new NgaTopicAttachment();
      attachment.url = item.url;
      attachment.attachments = item.attachments;
      attachment.attachmentsCheck = item.attachmentsCheck;
      return attachment;
    });
    return copiedDraft;
  }

  private static draftKey(accountKey: string, action: string, fid: number, stid: number,
    tid: number, pid: number): string {
    // Length prefixes keep account/action separators from colliding.
    return `${accountKey.length}:${accountKey}|${action.length}:${action}|${fid}|${stid}|${tid}|${pid}`;
  }

  private static boardKey(accountKey: string, fid: number, stid: number): string {
    return `${accountKey.length}:${accountKey}|${fid}|${stid}`;
  }
}

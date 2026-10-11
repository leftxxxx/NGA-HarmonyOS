/*
 * 用户资料数据模型。
 * 对应 Android ProfileData + ReputationData + AdminForumsData。
 */

/**
 * 声望（威望）项。
 * 对应 Android ReputationData：{"0":名称, "1":数值}。
 */
export class ReputationItem {
  name: string = '';
  value: string = '';
}

/**
 * 管理板块项。
 * 对应 Android AdminForumsData。
 */
export class AdminForumItem {
  fid: number = 0;
  name: string = '';
}

/**
 * 用户资料数据。
 * 对应 Android ProfileData。
 */
export class ProfileData {
  uid: number = 0;
  username: string = '';
  postCount: number = 0;
  registerDate: string = '';
  memberGroup: string = '';
  money: number = 0;
  fame: string = '';
  email: string = '';
  phone: string = '';
  sign: string = '';
  avatar: string = '';
  /** 账号状态：-1 = NUKED（封禁），< -1 = MUTED（禁言） */
  verified: number = 0;
  muted: boolean = false;
  nuked: boolean = false;
  mutedTime: string = '';
  reputationList: ReputationItem[] = [];
  adminForumList: AdminForumItem[] = [];

  /** 金钱拆分：金/银/铜 */
  getGold(): number {
    return Math.floor(this.money / 10000);
  }

  getSilver(): number {
    return Math.floor(this.money / 100) % 100;
  }

  getCopper(): number {
    return this.money % 100;
  }

  /** 账号状态文本描述 */
  getStateText(): string {
    if (this.nuked) {
      return '已封禁 (NUKED)';
    }
    if (this.muted) {
      return '已禁言' + (this.mutedTime.length > 0 ? '（至 ' + this.mutedTime + '）' : '');
    }
    return '正常';
  }
}
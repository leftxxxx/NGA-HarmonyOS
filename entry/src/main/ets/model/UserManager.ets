/*
 * 多账号管理器：支持多账号存储、切换、删除。
 * 对应 Android UserManagerImpl + User Entity + UserDao。
 *
 * 存储方案：preferences JSON 序列化（账号数量少，无需 SQLite）。
 * 账号列表以 JSON 数组存储在 'accounts' 键中，活跃索引存储在 'active_index' 键中。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** preferences 文件名 */
const PREF_NAME: string = 'nga_user_manager';

/** 账号数据模型（对应 Android User Entity） */
export class UserAccount {
  uid: string = '';
  cid: string = '';
  nickName: string = '';
  avatarUrl: string = '';
}

/**
 * 多账号管理单例。
 * - 账号列表管理（增删改查）
 * - 活跃账号索引管理
 * - Cookie 拼接
 * - 循环切换账号
 */
export class UserManager {
  private static store: preferences.Preferences | null = null;
  private static accounts: UserAccount[] = [];
  private static activeIndex: number = 0;

  /** 初始化（幂等）。必须在读取/写入前调用一次。 */
  static init(context: common.Context): void {
    if (UserManager.store === null) {
      const options: preferences.Options = { name: PREF_NAME };
      UserManager.store = preferences.getPreferencesSync(context, options);
      UserManager.loadFromStore();
    }
  }

  /** 从 preferences 加载账号列表和活跃索引 */
  private static loadFromStore(): void {
    if (UserManager.store === null) {
      return;
    }
    const indexVal: preferences.ValueType = UserManager.store.getSync('active_index', 0);
    if (typeof indexVal === 'number') {
      UserManager.activeIndex = indexVal;
    }
    const jsonVal: preferences.ValueType = UserManager.store.getSync('accounts', '[]');
    if (typeof jsonVal === 'string') {
      try {
        const parsed: Object[] = JSON.parse(jsonVal) as Object[];
        UserManager.accounts = [];
        for (const item of parsed) {
          const record: Record<string, Object> = item as Record<string, Object>;
          const account: UserAccount = new UserAccount();
          const uidVal: Object | undefined = record['uid'];
          if (typeof uidVal === 'string') {
            account.uid = uidVal;
          }
          const cidVal: Object | undefined = record['cid'];
          if (typeof cidVal === 'string') {
            account.cid = cidVal;
          }
          const nameVal: Object | undefined = record['nickName'];
          if (typeof nameVal === 'string') {
            account.nickName = nameVal;
          }
          const avatarVal: Object | undefined = record['avatarUrl'];
          if (typeof avatarVal === 'string') {
            account.avatarUrl = avatarVal;
          }
          UserManager.accounts.push(account);
        }
      } catch (err) {
        UserManager.accounts = [];
      }
    }
    // 确保 activeIndex 在合法范围
    if (UserManager.activeIndex >= UserManager.accounts.length) {
      UserManager.activeIndex = 0;
    }
  }

  /** 持久化账号列表和活跃索引 */
  private static commit(): void {
    if (UserManager.store === null) {
      return;
    }
    UserManager.store.putSync('accounts', JSON.stringify(UserManager.accounts));
    UserManager.store.putSync('active_index', UserManager.activeIndex);
    UserManager.store.flush();
  }

  /** 获取账号列表 */
  static getUserList(): UserAccount[] {
    return UserManager.accounts;
  }

  /** 获取账号数量 */
  static getUserSize(): number {
    return UserManager.accounts.length;
  }

  /** 是否有已登录账号 */
  static hasValidUser(): boolean {
    return UserManager.accounts.length > 0;
  }

  /** 获取当前活跃账号索引 */
  static getActiveIndex(): number {
    return UserManager.activeIndex;
  }

  /** 获取当前活跃账号；无账号返回 null */
  static getActiveUser(): UserAccount | null {
    if (UserManager.accounts.length === 0) {
      return null;
    }
    if (UserManager.activeIndex >= UserManager.accounts.length) {
      UserManager.activeIndex = 0;
    }
    return UserManager.accounts[UserManager.activeIndex];
  }

  /** 设置活跃账号索引 */
  static setActiveUser(index: number): void {
    if (index < 0 || index >= UserManager.accounts.length) {
      return;
    }
    UserManager.activeIndex = index;
    UserManager.commit();
  }

  /**
   * 循环切换账号（对应 Android UserManagerImpl.toggleUser）。
   * @param isNext true=下一个，false=上一个
   * @return 切换后的活跃索引
   */
  static toggleUser(isNext: boolean): number {
    const size: number = UserManager.accounts.length;
    if (size <= 1) {
      return UserManager.activeIndex;
    }
    if (isNext) {
      UserManager.activeIndex = (UserManager.activeIndex + 1) % size;
    } else {
      UserManager.activeIndex = (UserManager.activeIndex + size - 1) % size;
    }
    UserManager.commit();
    return UserManager.activeIndex;
  }

  /**
   * 添加账号（uid 相同则替换，对应 Android UserManagerImpl.addUser）。
   * 新增账号时自动设为活跃账号。
   */
  static addUser(uid: string, cid: string, nickName: string): void {
    for (let i: number = 0; i < UserManager.accounts.length; i++) {
      if (UserManager.accounts[i].uid === uid) {
        UserManager.accounts[i].cid = cid;
        UserManager.accounts[i].nickName = nickName;
        UserManager.activeIndex = i;
        UserManager.commit();
        return;
      }
    }
    const account: UserAccount = new UserAccount();
    account.uid = uid;
    account.cid = cid;
    account.nickName = nickName;
    UserManager.accounts.push(account);
    UserManager.activeIndex = UserManager.accounts.length - 1;
    UserManager.commit();
  }

  /**
   * 删除账号（对应 Android UserManagerImpl.removeUser）。
   * 删除当前活跃账号时重置为第一个。
   */
  static removeUser(index: number): void {
    if (index < 0 || index >= UserManager.accounts.length) {
      return;
    }
    UserManager.accounts.splice(index, 1);
    if (UserManager.accounts.length === 0 || UserManager.activeIndex === index) {
      UserManager.activeIndex = 0;
    } else if (UserManager.activeIndex > index) {
      UserManager.activeIndex = UserManager.activeIndex - 1;
    }
    UserManager.commit();
  }

  /**
   * 拼接鉴权 Cookie 串（对应 Android UserManagerImpl.getCookie）。
   */
  static getCookie(): string {
    const user: UserAccount | null = UserManager.getActiveUser();
    if (user === null || user.uid.length === 0) {
      return '';
    }
    return 'ngaPassportUid=' + user.uid + '; ngaPassportCid=' + user.cid;
  }

}

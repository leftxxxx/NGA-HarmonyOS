/*
 * 用户身份持久化层（兼容 facade）。
 * 内部委托给 UserManager，保持向后兼容。
 * 对应 Android UserManagerImpl 的单账号兼容接口。
 */

import { common } from '@kit.AbilityKit';
import { UserManager, UserAccount } from './UserManager';

/** 用户身份值对象（向后兼容） */
export class UserIdentity {
  uid: string = '';
  cid: string = '';
  userName: string = '';
}

/**
 * 登录态持久化 facade。
 * 内部委托给 UserManager，保持向后兼容。
 */
export class LoginStore {
  /** 初始化（幂等）。必须在读取/写入前调用一次。 */
  static init(context: common.Context): void {
    UserManager.init(context);
  }

  /** 是否存在已登录用户 */
  static hasUser(): boolean {
    return UserManager.hasValidUser();
  }

  /** 读取当前登录用户身份；未登录时返回空字段对象 */
  static getUser(): UserIdentity {
    const user: UserAccount | null = UserManager.getActiveUser();
    if (user === null) {
      return new UserIdentity();
    }
    const identity: UserIdentity = new UserIdentity();
    identity.uid = user.uid;
    identity.cid = user.cid;
    identity.userName = user.nickName;
    return identity;
  }

  /** 持久化用户身份（对应 Android UserManagerImpl.addUser） */
  static saveUser(uid: string, cid: string, userName: string): void {
    UserManager.addUser(uid, cid, userName);
  }

  /** 清除当前用户身份（删除当前活跃账号） */
  static clearUser(): void {
    if (UserManager.hasValidUser()) {
      UserManager.removeUser(UserManager.getActiveIndex());
    }
  }

  /** 拼接鉴权 Cookie 串，供后续接口请求携带 */
  static getCookie(): string {
    return UserManager.getCookie();
  }
}

/*
 * 黑名单持久化层：基于 @ohos.data.preferences 封装。
 * 对应 Android UserManagerImpl 的黑名单职责：add/remove/removeAll/getBlackList/checkBlackList。
 * 数据格式与 Android 对齐：JSON 字符串数组，每项含 userId + nickName。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME: string = 'nga_blacklist_store';
const KEY_BLACK_LIST: string = 'pref_black_list';

/** 黑名单用户条目 */
export class BlacklistUser {
  userId: string = '';
  nickName: string = '';
}

/**
 * 黑名单持久化单例。
 * 使用 getPreferencesSync 读取、putSync 写入并立即 flush。
 */
export class BlacklistStore {
  private static store: preferences.Preferences | null = null;

  /** 初始化（幂等）。必须在读取 / 写入前调用一次。 */
  static init(context: common.Context): void {
    if (BlacklistStore.store === null) {
      const options: preferences.Options = { name: PREF_NAME };
      BlacklistStore.store = preferences.getPreferencesSync(context, options);
    }
  }

  /** 获取黑名单列表 */
  static getList(): BlacklistUser[] {
    if (BlacklistStore.store === null) {
      return [];
    }
    const jsonStr: preferences.ValueType = BlacklistStore.store.getSync(KEY_BLACK_LIST, '');
    if (typeof jsonStr !== 'string' || jsonStr.length === 0) {
      return [];
    }
    try {
      const arr: object[] = JSON.parse(jsonStr) as object[];
      const result: BlacklistUser[] = [];
      for (const item of arr) {
        const u: BlacklistUser = new BlacklistUser();
        const userId = (item as Record<string, Object>)['userId'];
        const nickName = (item as Record<string, Object>)['nickName'];
        if (typeof userId === 'string') {
          u.userId = userId;
        }
        if (typeof nickName === 'string') {
          u.nickName = nickName;
        }
        result.push(u);
      }
      return result;
    } catch (err) {
      return [];
    }
  }

  /** 添加到黑名单（去重，按 userId 判断） */
  static add(userId: string, nickName: string): void {
    if (BlacklistStore.store === null) {
      return;
    }
    const list: BlacklistUser[] = BlacklistStore.getList();
    for (const user of list) {
      if (user.userId === userId) {
        return; // 已存在，不重复添加
      }
    }
    const u: BlacklistUser = new BlacklistUser();
    u.userId = userId;
    u.nickName = nickName;
    list.push(u);
    BlacklistStore.commit(list);
  }

  /** 从黑名单移除（按 userId 匹配） */
  static remove(userId: string): void {
    if (BlacklistStore.store === null) {
      return;
    }
    const list: BlacklistUser[] = BlacklistStore.getList();
    const filtered: BlacklistUser[] = [];
    for (const user of list) {
      if (user.userId !== userId) {
        filtered.push(user);
      }
    }
    BlacklistStore.commit(filtered);
  }

  /** 按索引移除 */
  static removeAt(index: number): void {
    if (BlacklistStore.store === null) {
      return;
    }
    const list: BlacklistUser[] = BlacklistStore.getList();
    if (index < 0 || index >= list.length) {
      return;
    }
    list.splice(index, 1);
    BlacklistStore.commit(list);
  }

  /** 清除全部黑名单 */
  static removeAll(): void {
    if (BlacklistStore.store === null) {
      return;
    }
    BlacklistStore.commit([]);
  }

  /** 检查某用户是否在黑名单中 */
  static checkExists(userId: string): boolean {
    const list: BlacklistUser[] = BlacklistStore.getList();
    for (const user of list) {
      if (user.userId === userId) {
        return true;
      }
    }
    return false;
  }

  /** 序列化并持久化 */
  private static commit(list: BlacklistUser[]): void {
    if (BlacklistStore.store === null) {
      return;
    }
    const jsonStr: string = JSON.stringify(list);
    BlacklistStore.store.putSync(KEY_BLACK_LIST, jsonStr);
    BlacklistStore.store.flush();
  }
}
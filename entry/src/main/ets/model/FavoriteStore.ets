/*
 * 收藏板块持久化层：基于 @ohos.data.preferences 封装。
 * 对应 Android BoardModel 的收藏管理职责。
 * 数据格式与 BlacklistStore 对齐：JSON 字符串数组，每项含 fid + stid + name。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Board } from './Board';

const PREF_NAME: string = 'nga_favorite_store';
const KEY_FAVORITE_LIST: string = 'pref_favorite_list';

/**
 * 收藏板块持久化单例。
 * 使用 getPreferencesSync 读取、putSync 写入并立即 flush。
 */
export class FavoriteStore {
  private static store: preferences.Preferences | null = null;

  /** 初始化（幂等）。必须在读取 / 写入前调用一次。 */
  static init(context: common.Context): void {
    if (FavoriteStore.store === null) {
      const options: preferences.Options = { name: PREF_NAME };
      FavoriteStore.store = preferences.getPreferencesSync(context, options);
    }
  }

  /** 获取收藏板块列表 */
  static getList(): Board[] {
    if (FavoriteStore.store === null) {
      return [];
    }
    const jsonStr: preferences.ValueType = FavoriteStore.store.getSync(KEY_FAVORITE_LIST, '');
    if (typeof jsonStr !== 'string' || jsonStr.length === 0) {
      return [];
    }
    try {
      const arr: object[] = JSON.parse(jsonStr) as object[];
      const result: Board[] = [];
      for (const item of arr) {
        const board: Board = new Board();
        const itemRecord: Record<string, Object> = item as Record<string, Object>;
        const fid: Object | undefined = itemRecord['fid'];
        if (typeof fid === 'number') {
          board.fid = fid;
        }
        const stid: Object | undefined = itemRecord['stid'];
        if (typeof stid === 'number') {
          board.stid = stid;
        }
        const name: Object | undefined = itemRecord['name'];
        if (typeof name === 'string') {
          board.name = name;
        }
        result.push(board);
      }
      return result;
    } catch (err) {
      return [];
    }
  }

  /** 添加到收藏（按 fid + stid 去重） */
  static add(board: Board): void {
    if (FavoriteStore.store === null || !FavoriteStore.isValidKey(board.fid, board.stid)) {
      return;
    }
    const list: Board[] = FavoriteStore.getList();
    for (const item of list) {
      if (item.fid === board.fid && item.stid === board.stid) {
        return; // 已存在，不重复添加
      }
    }
    list.push(board);
    FavoriteStore.commit(list);
  }

  /** 从收藏移除（按 fid + stid 匹配，普通板块默认 stid 为 0） */
  static remove(fid: number, stid: number = 0): void {
    if (FavoriteStore.store === null) {
      return;
    }
    const list: Board[] = FavoriteStore.getList();
    const filtered: Board[] = [];
    for (const item of list) {
      if (item.fid !== fid || item.stid !== stid) {
        filtered.push(item);
      }
    }
    FavoriteStore.commit(filtered);
  }

  /** 检查某板块是否已收藏（按 fid + stid 匹配） */
  static checkExists(fid: number, stid: number = 0): boolean {
    const list: Board[] = FavoriteStore.getList();
    for (const item of list) {
      if (item.fid === fid && item.stid === stid) {
        return true;
      }
    }
    return false;
  }

  /** 检查某板块是否已收藏（按 fid + stid 匹配） */
  static checkExistsByKey(fid: number, stid: number): boolean {
    return FavoriteStore.checkExists(fid, stid);
  }

  /** 手动添加板块到收藏（按 fid + stid 去重） */
  static addByFidStid(fid: number, stid: number, name: string): boolean {
    if (FavoriteStore.store === null || !FavoriteStore.isValidKey(fid, stid)) {
      return false;
    }
    if (FavoriteStore.checkExistsByKey(fid, stid)) {
      return false;
    }
    const board: Board = new Board(fid, stid, name);
    const list: Board[] = FavoriteStore.getList();
    list.push(board);
    FavoriteStore.commit(list);
    return true;
  }

  /** 普通板块允许负 fid；仅有 stid 的子板块也有效。 */
  private static isValidKey(fid: number, stid: number): boolean {
    return Number.isInteger(fid) && Number.isInteger(stid) && stid >= 0 && (fid !== 0 || stid > 0);
  }

  /** 交换两个收藏板块的位置（排序） */
  static swap(fromIndex: number, toIndex: number): void {
    if (FavoriteStore.store === null) {
      return;
    }
    const list: Board[] = FavoriteStore.getList();
    if (fromIndex < 0 || fromIndex >= list.length || toIndex < 0 || toIndex >= list.length) {
      return;
    }
    // 逐位交换（与安卓端 BoardModel.swapBookmark 一致）
    if (fromIndex < toIndex) {
      for (let i: number = fromIndex; i < toIndex; i++) {
        const tmp: Board = list[i];
        list[i] = list[i + 1];
        list[i + 1] = tmp;
      }
    } else {
      for (let i: number = fromIndex; i > toIndex; i--) {
        const tmp: Board = list[i];
        list[i] = list[i - 1];
        list[i - 1] = tmp;
      }
    }
    FavoriteStore.commit(list);
  }

  /** 上移收藏板块 */
  static moveUp(index: number): void {
    if (index <= 0) {
      return;
    }
    FavoriteStore.swap(index, index - 1);
  }

  /** 下移收藏板块 */
  static moveDown(index: number): void {
    const list: Board[] = FavoriteStore.getList();
    if (index >= list.length - 1) {
      return;
    }
    FavoriteStore.swap(index, index + 1);
  }

  /** 清空所有收藏板块 */
  static clearAll(): void {
    if (FavoriteStore.store === null) {
      return;
    }
    FavoriteStore.commit([]);
  }

  /** 序列化并持久化 */
  private static commit(list: Board[]): void {
    if (FavoriteStore.store === null) {
      return;
    }
    const jsonStr: string = JSON.stringify(list);
    FavoriteStore.store.putSync(KEY_FAVORITE_LIST, jsonStr);
    FavoriteStore.store.flush();
  }
}

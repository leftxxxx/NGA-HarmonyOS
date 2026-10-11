/*
 * 最近访问板块持久化层：基于 @ohos.data.preferences 封装。
 * 记录用户最近进入过的板块（fid + stid + name），最新访问的排在最前，最多保留 MAX_COUNT 个。
 * 与 FavoriteStore 数据结构对齐。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Board } from './Board';

const PREF_NAME: string = 'nga_recent_board_store';
const KEY_RECENT_LIST: string = 'pref_recent_list';
const MAX_COUNT: number = 10;

/**
 * 最近访问板块持久化单例。
 */
export class RecentBoardStore {
  private static store: preferences.Preferences | null = null;

  /** 初始化（幂等）。必须在读取 / 写入前调用一次。 */
  static init(context: common.Context): void {
    if (RecentBoardStore.store === null) {
      const options: preferences.Options = { name: PREF_NAME };
      RecentBoardStore.store = preferences.getPreferencesSync(context, options);
    }
  }

  /** 获取最近访问板块列表（最新在前） */
  static getList(): Board[] {
    if (RecentBoardStore.store === null) {
      return [];
    }
    const jsonStr: preferences.ValueType = RecentBoardStore.store.getSync(KEY_RECENT_LIST, '');
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

  /** 记录一次板块访问：去重（按 fid + stid）、最新在前、限制数量 */
  static record(fid: number, stid: number, name: string): void {
    if (RecentBoardStore.store === null) {
      return;
    }
    if (!Number.isInteger(fid) || !Number.isInteger(stid) || stid < 0 || (fid === 0 && stid <= 0)) {
      return;
    }
    const list: Board[] = RecentBoardStore.getList();
    const filtered: Board[] = [];
    for (const item of list) {
      if (!(item.fid === fid && item.stid === stid)) {
        filtered.push(item);
      }
    }
    const newest: Board[] = [];
    newest.push(new Board(fid, stid, name));
    for (const item of filtered) {
      newest.push(item);
    }
    const limit: number = newest.length > MAX_COUNT ? MAX_COUNT : newest.length;
    const trimmed: Board[] = [];
    for (let i: number = 0; i < limit; i++) {
      trimmed.push(newest[i]);
    }
    RecentBoardStore.commit(trimmed);
  }

  /** 序列化并持久化 */
  private static commit(list: Board[]): void {
    if (RecentBoardStore.store === null) {
      return;
    }
    const jsonStr: string = JSON.stringify(list);
    RecentBoardStore.store.putSync(KEY_RECENT_LIST, jsonStr);
    RecentBoardStore.store.flush();
  }
}

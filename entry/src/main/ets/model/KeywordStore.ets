/*
 * 关键词屏蔽持久化层：基于 @ohos.data.preferences 封装。
 * 对应 Android FilterKeywordsManagerImpl 的职责：add/remove/toggle/getKeywords。
 * 数据格式与 Android 对齐：JSON 字符串数组，每项含 keyword + enabled。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME: string = 'nga_keyword_store';
const KEY_FILTER_KEYWORDS: string = 'filter_keywords';

/** 关键词条目 */
export class FilterKeywordItem {
  keyword: string = '';
  enabled: boolean = true;
}

/**
 * 关键词持久化单例。
 * 使用 getPreferencesSync 读取、putSync 写入并立即 flush。
 */
export class KeywordStore {
  private static store: preferences.Preferences | null = null;

  /** 初始化（幂等）。必须在读取 / 写入前调用一次。 */
  static init(context: common.Context): void {
    if (KeywordStore.store === null) {
      const options: preferences.Options = { name: PREF_NAME };
      KeywordStore.store = preferences.getPreferencesSync(context, options);
    }
  }

  /** 获取关键词列表 */
  static getList(): FilterKeywordItem[] {
    if (KeywordStore.store === null) {
      return [];
    }
    const jsonStr: preferences.ValueType = KeywordStore.store.getSync(KEY_FILTER_KEYWORDS, '');
    if (typeof jsonStr !== 'string' || jsonStr.length === 0) {
      return [];
    }
    try {
      const arr: object[] = JSON.parse(jsonStr) as object[];
      const result: FilterKeywordItem[] = [];
      for (const item of arr) {
        const k: FilterKeywordItem = new FilterKeywordItem();
        const keyword = (item as Record<string, Object>)['keyword'];
        const enabled = (item as Record<string, Object>)['enabled'];
        if (typeof keyword === 'string') {
          k.keyword = keyword;
        }
        if (typeof enabled === 'boolean') {
          k.enabled = enabled;
        }
        result.push(k);
      }
      return result;
    } catch (err) {
      return [];
    }
  }

  /** 添加关键词 */
  static add(keyword: string): void {
    if (KeywordStore.store === null || keyword.length === 0) {
      return;
    }
    const list: FilterKeywordItem[] = KeywordStore.getList();
    const k: FilterKeywordItem = new FilterKeywordItem();
    k.keyword = keyword;
    k.enabled = true;
    list.push(k);
    KeywordStore.commit(list);
  }

  /** 按索引移除关键词 */
  static removeAt(index: number): void {
    if (KeywordStore.store === null) {
      return;
    }
    const list: FilterKeywordItem[] = KeywordStore.getList();
    if (index < 0 || index >= list.length) {
      return;
    }
    list.splice(index, 1);
    KeywordStore.commit(list);
  }

  /** 切换关键词启用/禁用状态 */
  static toggle(index: number): void {
    if (KeywordStore.store === null) {
      return;
    }
    const list: FilterKeywordItem[] = KeywordStore.getList();
    if (index < 0 || index >= list.length) {
      return;
    }
    list[index].enabled = !list[index].enabled;
    KeywordStore.commit(list);
  }

  /** 序列化并持久化 */
  private static commit(list: FilterKeywordItem[]): void {
    if (KeywordStore.store === null) {
      return;
    }
    const jsonStr: string = JSON.stringify(list);
    KeywordStore.store.putSync(KEY_FILTER_KEYWORDS, jsonStr);
    KeywordStore.store.flush();
  }
}
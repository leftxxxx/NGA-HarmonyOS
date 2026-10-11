/*
 * 设置项数据层：基于 @ohos.data.preferences 的本地持久化封装。
 * 仅承载 SettingsPage 所需的五项设置：主题配色、夜间模式、正文字号、加载图片策略、NGA 域名。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** preferences 文件名 */
const PREF_NAME: string = 'nga_app_settings';

/** 设置项键名（与 Android PreferenceKey 语义对齐） */
export class SettingKeys {
  static readonly THEME: string = 'material_theme';
  static readonly NIGHT: string = 'nightmode';
  static readonly FONT_SIZE: string = 'topic_content_size';
  static readonly LOAD_PIC: string = 'pref_load_pic_strategy';
  static readonly DOMAIN: string = 'nga_domain';
}

/** 默认值（与 Android 默认语义对齐） */
export class SettingDefaults {
  static readonly THEME: number = 0; // 统一白蓝配色
  static readonly NIGHT: boolean = false; // 关闭
  static readonly FONT_SIZE: number = 1; // 标准
  static readonly LOAD_PIC: number = 0; // 始终加载
  static readonly DOMAIN: number = 1; // https://bbs.nga.cn
}

/**
 * 设置项持久化单例。
 * 使用 getPreferencesSync 读取、putSync 写入并立即 flush，保证写入后重启仍可读取。
 */
export class SettingsStore {
  private static store: preferences.Preferences | null = null;

  /** 初始化（幂等）。必须在读取 / 写入前调用一次。 */
  static init(context: common.Context): void {
    if (SettingsStore.store === null) {
      const options: preferences.Options = { name: PREF_NAME };
      SettingsStore.store = preferences.getPreferencesSync(context, options);
      // 兼容旧棕/绿/黑主题值，只迁移配色项，保留其他设置与账号数据。
      if (SettingsStore.store.getSync(SettingKeys.THEME, SettingDefaults.THEME) !== SettingDefaults.THEME) {
        SettingsStore.store.putSync(SettingKeys.THEME, SettingDefaults.THEME);
        SettingsStore.store.flush();
      }
    }
  }

  static getInt(key: string, def: number): number {
    if (SettingsStore.store === null) {
      return def;
    }
    const value: preferences.ValueType = SettingsStore.store.getSync(key, def);
    if (typeof value === 'number') {
      return value;
    }
    return def;
  }

  static setInt(key: string, value: number): void {
    if (SettingsStore.store === null) {
      return;
    }
    SettingsStore.store.putSync(key, value);
    SettingsStore.store.flush();
  }

  static getBool(key: string, def: boolean): boolean {
    if (SettingsStore.store === null) {
      return def;
    }
    const value: preferences.ValueType = SettingsStore.store.getSync(key, def);
    if (typeof value === 'boolean') {
      return value;
    }
    return def;
  }

  static setBool(key: string, value: boolean): void {
    if (SettingsStore.store === null) {
      return;
    }
    SettingsStore.store.putSync(key, value);
    SettingsStore.store.flush();
  }
}

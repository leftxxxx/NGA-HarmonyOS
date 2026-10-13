/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, Configuration, systemConfiguration, UIAbility, Want } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { SettingsStore, NightModePolicy } from '../model/AppSettings';
import { applyApplicationColorMode, applyWindowTheme, WINDOW_TOP_SAFE_AREA_PX_KEY } from '../model/AppTheme';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private immersiveWindow: window.Window | undefined = undefined;
  private topAvoidAreaCallback: ((options: window.AvoidAreaOptions) => void) | undefined = undefined;
  private windowStageGeneration: number = 0;
  private themeContentReady: boolean = false;
  private systemThemeSubscribed: boolean = false;
  private systemThemeCallback: systemConfiguration.UpdatedCallback = {
    onColorModeUpdated: (colorMode: ConfigurationConstant.ColorMode): void => {
      SettingsStore.updateSystemColorMode(colorMode);
      this.updateWindowTheme();
    }
  };

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      SettingsStore.init(this.context);
      SettingsStore.initializeAppearance(this.context.config.colorMode);
      if (deviceInfo.sdkApiVersion >= 24) {
        this.context.getApplicationContext().onSystemConfigurationUpdated(this.systemThemeCallback);
        this.systemThemeSubscribed = true;
      }
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    if (this.systemThemeSubscribed) {
      this.context.getApplicationContext().offSystemConfigurationUpdated(this.systemThemeCallback);
      this.systemThemeSubscribed = false;
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    this.loadMainPage(windowStage);
  }

  private async loadMainPage(windowStage: window.WindowStage): Promise<void> {
    const generation: number = ++this.windowStageGeneration;
    this.themeContentReady = false;
    this.stopTopAvoidAreaObserver();
    AppStorage.setOrCreate<number>(WINDOW_TOP_SAFE_AREA_PX_KEY, 0);
    let mainWindow: window.Window | undefined = undefined;
    try {
      // Router 的转场画布覆盖手势区，页面根据动态顶部避让值安排标题内容。
      mainWindow = windowStage.getMainWindowSync();
      await mainWindow.setWindowLayoutFullScreen(true);
      if (generation !== this.windowStageGeneration) {
        return;
      }
      const topArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      AppStorage.setOrCreate<number>(WINDOW_TOP_SAFE_AREA_PX_KEY, Math.max(0, topArea.topRect.height));
      const observedWindow: window.Window = mainWindow;
      const callback: (options: window.AvoidAreaOptions) => void = (options: window.AvoidAreaOptions): void => {
        if (generation === this.windowStageGeneration && this.immersiveWindow === observedWindow &&
          options.type === window.AvoidAreaType.TYPE_SYSTEM) {
          AppStorage.setOrCreate<number>(WINDOW_TOP_SAFE_AREA_PX_KEY, Math.max(0, options.area.topRect.height));
        }
      };
      this.immersiveWindow = mainWindow;
      this.topAvoidAreaCallback = callback;
      mainWindow.on('avoidAreaChange', callback);
    } catch (error) {
      if (generation !== this.windowStageGeneration) {
        return;
      }
      this.stopTopAvoidAreaObserver();
      AppStorage.setOrCreate<number>(WINDOW_TOP_SAFE_AREA_PX_KEY, 0);
      hilog.warn(DOMAIN, 'testTag', 'Failed to initialize immersive window safe area; using native avoidance.');
      if (mainWindow !== undefined) {
        try {
          await mainWindow.setWindowLayoutFullScreen(false);
        } catch (fallbackError) {
          hilog.warn(DOMAIN, 'testTag', 'Failed to restore native window avoidance.');
        }
      }
    }
    if (generation !== this.windowStageGeneration) {
      return;
    }
    // 在首次绘制前设置窗口背景与透明系统栏，避免启动帧露出默认底色。
    await applyWindowTheme(this.context, SettingsStore.isNightMode());
    if (generation !== this.windowStageGeneration) {
      return;
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      if (generation !== this.windowStageGeneration) {
        return;
      }
      this.themeContentReady = true;
      applyApplicationColorMode(this.context);
      this.updateWindowTheme();
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  private stopTopAvoidAreaObserver(): void {
    const mainWindow: window.Window | undefined = this.immersiveWindow;
    const callback: ((options: window.AvoidAreaOptions) => void) | undefined = this.topAvoidAreaCallback;
    this.immersiveWindow = undefined;
    this.topAvoidAreaCallback = undefined;
    if (mainWindow !== undefined && callback !== undefined) {
      try {
        mainWindow.off('avoidAreaChange', callback);
      } catch (error) {
        // 窗口销毁时已解绑或不可访问，不再保留本地订阅。
      }
    }
  }

  onWindowStageDestroy(): void {
    this.themeContentReady = false;
    this.windowStageGeneration++;
    this.stopTopAvoidAreaObserver();
    AppStorage.setOrCreate<number>(WINDOW_TOP_SAFE_AREA_PX_KEY, 0);
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    if (this.themeContentReady) {
      // 应用色模式在内容就绪和用户更改策略时设置，回到前台只同步当前配色。
      if (!this.systemThemeSubscribed && SettingsStore.getNightModePolicy() === NightModePolicy.SYSTEM) {
        SettingsStore.updateSystemColorMode(this.context.config.colorMode);
      }
      this.updateWindowTheme();
    }
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 应用强制色模式的配置回调不能污染真实系统状态。
    if (!this.systemThemeSubscribed && SettingsStore.getNightModePolicy() === NightModePolicy.SYSTEM) {
      SettingsStore.updateSystemColorMode(newConfig.colorMode);
    }
    this.updateWindowTheme();
  }

  private updateWindowTheme(): void {
    if (this.themeContentReady) {
      applyWindowTheme(this.context, SettingsStore.isNightMode());
    }
  }
}

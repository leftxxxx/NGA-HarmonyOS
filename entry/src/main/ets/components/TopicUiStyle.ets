import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { COLOR_DAY_BG, COLOR_NIGHT_BG, COLOR_DAY_CARD, COLOR_NIGHT_CARD, themeSecondarySurfaceColor, themeDividerColor,
  themeMaterialSurfaceColor } from '../model/AppTheme';

/** 页面共享的卡片与控件层级。 */
export function topicSurfaceColor(nightMode: boolean): string {
  return nightMode ? COLOR_NIGHT_CARD : COLOR_DAY_CARD;
}

export function topicSecondarySurfaceColor(nightMode: boolean): string {
  return themeSecondarySurfaceColor(nightMode);
}

export function topicDividerColor(nightMode: boolean): string {
  return themeDividerColor(nightMode);
}

/** 标题栏与透明状态栏下的窗口使用同一底色，避免材质产生顶部色差。 */
export function topicTitleOptions(nightMode: boolean, barStyle: BarStyle = BarStyle.STACK): NavigationTitleOptions {
  const options: NavigationTitleOptions = {
    barStyle: barStyle,
    backgroundColor: nightMode ? COLOR_NIGHT_BG : COLOR_DAY_BG,
    backgroundBlurStyle: BlurStyle.NONE
  };
  if (deviceInfo.sdkApiVersion >= 26) {
    if (deviceInfo.apiAvailable('26.0.0')) {
      options.systemMaterial = uiMaterial.Material.empty;
    }
  }
  return options;
}

/** 左右操作胶囊分别使用系统沉浸光感；不支持的设备保留模糊底材。 */
export class TopicActionMaterialModifier implements AttributeModifier<RowAttribute> {
  private nightMode: boolean;

  constructor(nightMode: boolean) {
    this.nightMode = nightMode;
  }

  applyNormalAttribute(actionRow: RowAttribute): void {
    if (deviceInfo.sdkApiVersion >= 26) {
      if (deviceInfo.apiAvailable('26.0.0')) {
        try {
          if (uiMaterial.isImmersiveMaterialSupported()) {
            actionRow.systemMaterial(new uiMaterial.ImmersiveMaterial({
              style: uiMaterial.ImmersiveStyle.THIN,
              materialColor: themeMaterialSurfaceColor(this.nightMode, 0.6),
              colorInvert: false,
              applyShadow: true,
              interactive: true,
              lightEffect: { color: Color.White }
            }));
            return;
          }
        } catch (error) {
          // 系统材质不可用时，操作入口继续使用兼容底材。
        }
        actionRow.systemMaterial(uiMaterial.Material.empty);
      }
    }
    actionRow.backgroundColor(themeMaterialSurfaceColor(this.nightMode, 0.9));
    actionRow.backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR,
      { colorMode: this.nightMode ? ThemeColorMode.DARK : ThemeColorMode.LIGHT });
    actionRow.shadow({ radius: 16, color: '#18000000', offsetY: 4 });
  }
}

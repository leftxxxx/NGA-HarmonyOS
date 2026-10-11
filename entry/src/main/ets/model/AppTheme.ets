import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

export const COLOR_ACCENT_BLUE: string = '#ff1765c1';
export const COLOR_NIGHT_ACCENT_TEXT: string = '#ff8dbeff';
export const COLOR_DAY_BG: string = '#fff5f7fb';
export const COLOR_NIGHT_BG: string = '#ff101722';
// 日间以白色卡片承载内容，浅蓝灰背景和控件形成轻量层级。
export const COLOR_DAY_CARD: string = '#ffffffff';
export const COLOR_NIGHT_CARD: string = '#ff192333';
export const COLOR_DAY_SECONDARY: string = '#ffedf3fb';
export const COLOR_NIGHT_SECONDARY: string = '#ff263448';
export const COLOR_DAY_TEXT: string = '#ff182538';
export const COLOR_NIGHT_TEXT: string = '#ffe9eff8';
export const COLOR_DAY_SUB: string = '#ff53647a';
export const COLOR_NIGHT_SUB: string = '#ffb0bfd2';
export const COLOR_DAY_ERROR: string = '#ffb53d3d';
export const COLOR_NIGHT_ERROR: string = '#ffffa3a3';

/** 表单、提示条与选中项共享的次级表面。 */
export function themeSecondarySurfaceColor(nightMode: boolean): string {
  return nightMode ? COLOR_NIGHT_SECONDARY : COLOR_DAY_SECONDARY;
}

export function themeDividerColor(nightMode: boolean): string {
  return nightMode ? '#24ffffff' : '#14182538';
}

/** 底栏和浮层从同一表面色派生半透明材质。 */
export function themeMaterialSurfaceColor(nightMode: boolean, opacity: number): string {
  const alpha: string = Math.round(Math.max(0, Math.min(1, opacity)) * 255).toString(16).padStart(2, '0');
  const surface: string = nightMode ? COLOR_NIGHT_CARD : COLOR_DAY_CARD;
  return '#' + alpha + surface.substring(3);
}

export function themeErrorTextColor(nightMode: boolean): string {
  return nightMode ? COLOR_NIGHT_ERROR : COLOR_DAY_ERROR;
}

export function themeErrorSurfaceColor(nightMode: boolean): string {
  return nightMode ? '#ff382627' : '#fff9e9e7';
}

export function themeWarningTextColor(nightMode: boolean): string {
  return nightMode ? '#ffe5bc79' : '#ff94601a';
}

export function themeWarningSurfaceColor(nightMode: boolean): string {
  return nightMode ? '#ff332b20' : '#fff5ecd9';
}

/** 文本强调色独立于实心按钮底色，保证夜间深色主题仍可读。 */
export function themeAccentTextColor(nightMode: boolean): string {
  return nightMode ? COLOR_NIGHT_ACCENT_TEXT : COLOR_ACCENT_BLUE;
}

/** 同步原生控件和安全区域的底色，随应用的夜间开关更新。 */
export async function applyWindowTheme(context: common.UIAbilityContext, nightMode: boolean): Promise<void> {
  try {
    context.getApplicationContext().setColorMode(nightMode ?
      ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    const mainWindow: window.Window = await window.getLastWindow(context);
    const background: string = nightMode ? COLOR_NIGHT_BG : COLOR_DAY_BG;
    const foreground: string = nightMode ? COLOR_NIGHT_TEXT : COLOR_DAY_TEXT;
    mainWindow.setWindowBackgroundColor(background);
    await mainWindow.setWindowSystemBarProperties({
      // 状态栏透出页面底色；原生标题栏同步使用该底色，顶部保持连续。
      statusBarColor: '#00000000',
      // 此属性用于三键导航兼容，手势指示条继续由系统管理。
      navigationBarColor: '#00000000',
      statusBarContentColor: foreground,
      navigationBarContentColor: foreground
    });
  } catch (error) {
    hilog.error(0x0000, 'AppTheme', 'Failed to apply window theme: %{public}s', JSON.stringify(error));
  }
}

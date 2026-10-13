import { UIContext, window } from '@kit.ArkUI';

/** 页面铺到手势区，控件单独使用动态避让；键盘升起时不重复留底距。 */
export class BottomSafeAreaObserver {
  private mainWindow: window.Window | undefined = undefined;
  private uiContext: UIContext | undefined = undefined;
  private onInsetChanged: ((inset: number) => void) | undefined = undefined;
  private windowCallback: ((options: window.AvoidAreaOptions) => void) | undefined = undefined;
  private active: boolean = false;
  private pending: boolean = false;
  private generation: number = 0;
  private systemBottomPx: number = 0;
  private navigationBottomPx: number = 0;
  private keyboardVisible: boolean = false;
  private ready: boolean = false;
  private onAvoidAreaChanged: (options: window.AvoidAreaOptions) => void =
    (options: window.AvoidAreaOptions): void => {
      if (!this.active || this.mainWindow === undefined) {
        return;
      }
      if (options.type === window.AvoidAreaType.TYPE_SYSTEM) {
        this.systemBottomPx = options.area.bottomRect.height;
      } else if (options.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
        this.navigationBottomPx = options.area.bottomRect.height;
      } else if (options.type === window.AvoidAreaType.TYPE_KEYBOARD) {
        this.keyboardVisible = options.area.bottomRect.height > 0;
      } else {
        return;
      }
      // 变化回调直接使用系统提供的新值，不在窗口变更时查询旧数据。
      if (this.ready) {
        this.publishInset();
      } else {
        this.refresh();
      }
    };

  async start(uiContext: UIContext, onInsetChanged: (inset: number) => void): Promise<void> {
    if (this.mainWindow !== undefined || this.pending) {
      return;
    }
    this.active = true;
    this.pending = true;
    this.uiContext = uiContext;
    this.onInsetChanged = onInsetChanged;
    const generation: number = ++this.generation;
    try {
      const hostContext = uiContext.getHostContext();
      if (hostContext === undefined) {
        return;
      }
      const mainWindow: window.Window = await window.getLastWindow(hostContext);
      if (!this.active || generation !== this.generation) {
        return;
      }
      const callback: (options: window.AvoidAreaOptions) => void = (options: window.AvoidAreaOptions): void => {
        if (generation === this.generation) {
          this.onAvoidAreaChanged(options);
        }
      };
      mainWindow.on('avoidAreaChange', callback);
      this.windowCallback = callback;
      this.mainWindow = mainWindow;
      this.refresh();
    } catch (error) {
      // 获取失败时页面继续原生避让；onShown/onPageShow 可重试。
    } finally {
      if (generation === this.generation) {
        this.pending = false;
      }
    }
  }

  refresh(): void {
    if (!this.active || this.mainWindow === undefined) {
      return;
    }
    try {
      const systemBottomPx: number = this.mainWindow
        .getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).bottomRect.height;
      const navigationBottomPx: number = this.mainWindow
        .getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
      const keyboardVisible: boolean = this.mainWindow
        .getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD).bottomRect.height > 0;
      this.systemBottomPx = systemBottomPx;
      this.navigationBottomPx = navigationBottomPx;
      this.keyboardVisible = keyboardVisible;
      this.ready = true;
      this.publishInset();
    } catch (error) {
      // 暂时读取失败时保留最后一次有效避让值。
    }
  }

  stop(): void {
    this.active = false;
    this.pending = false;
    this.generation++;
    if (this.mainWindow !== undefined && this.windowCallback !== undefined) {
      try {
        this.mainWindow.off('avoidAreaChange', this.windowCallback);
      } catch (error) {
        // 窗口已销毁时只清理本地引用。
      }
    }
    this.mainWindow = undefined;
    this.windowCallback = undefined;
    this.uiContext = undefined;
    this.onInsetChanged = undefined;
    this.ready = false;
  }

  private publishInset(): void {
    if (this.uiContext !== undefined && this.onInsetChanged !== undefined) {
      this.onInsetChanged(this.keyboardVisible ? 0 :
        this.uiContext.px2vp(Math.max(this.systemBottomPx, this.navigationBottomPx)));
    }
  }
}

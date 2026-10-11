import { Callback } from '@kit.BasicServicesKit';
import { motion } from '@kit.MultimodalAwarenessKit';

// Observe the actual holding hand. Unsupported devices keep the page's default
// position; operating-hand events are not a substitute for holding posture.
export class PostGripObserver {
  private started: boolean = false;
  private generation: number = 0;
  private holdingHandCallback: Callback<motion.HoldingHandStatus> | null = null;

  start(onSideChanged: (isLeft: boolean) => void): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.generation += 1;
    const registrationGeneration: number = this.generation;
    const callback: Callback<motion.HoldingHandStatus> = (status: motion.HoldingHandStatus): void => {
      if (!this.started || this.generation !== registrationGeneration) {
        return;
      }
      if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) {
        onSideChanged(true);
      } else if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
        onSideChanged(false);
      }
    };
    this.holdingHandCallback = callback;
    try {
      motion.on('holdingHandChanged', callback);
    } catch (error) {
      if (this.generation !== registrationGeneration) {
        return;
      }
      // Invalidate even a callback retained by a failed native registration.
      this.generation += 1;
      this.holdingHandCallback = null;
      this.unsubscribe(callback);
    }
  }

  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.generation += 1;
    const callback: Callback<motion.HoldingHandStatus> | null = this.holdingHandCallback;
    this.holdingHandCallback = null;
    if (callback !== null) {
      this.unsubscribe(callback);
    }
  }

  private unsubscribe(callback: Callback<motion.HoldingHandStatus>): void {
    try {
      motion.off('holdingHandChanged', callback);
    } catch (error) {
      // Hardware and service failures must not interrupt page navigation.
    }
  }
}

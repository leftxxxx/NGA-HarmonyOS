/*
 * 缓存工具：统计目录占用大小、格式化可读大小、递归清空目录。
 */

import { fileIo as fs } from '@kit.CoreFileKit';

export class CacheUtil {
  /** 递归统计目录（或文件）占用的字节数；异常时返回已统计部分。 */
  static getDirSize(dirPath: string): number {
    let total: number = 0;
    try {
      const stat = fs.statSync(dirPath);
      if (!stat.isDirectory()) {
        return stat.size;
      }
      const names: string[] = fs.listFileSync(dirPath);
      for (const name of names) {
        total += CacheUtil.getDirSize(dirPath + '/' + name);
      }
    } catch (err) {
      return total;
    }
    return total;
  }

  /** 清空目录内容（保留目录本身）。 */
  static clearDir(dirPath: string): void {
    try {
      const names: string[] = fs.listFileSync(dirPath);
      for (const name of names) {
        CacheUtil.removeRecursively(dirPath + '/' + name);
      }
    } catch (err) {
      return;
    }
  }

  private static removeRecursively(path: string): void {
    try {
      const stat = fs.statSync(path);
      if (stat.isDirectory()) {
        const names: string[] = fs.listFileSync(path);
        for (const name of names) {
          CacheUtil.removeRecursively(path + '/' + name);
        }
        fs.rmdirSync(path);
      } else {
        fs.unlinkSync(path);
      }
    } catch (err) {
      return;
    }
  }

  /** 将字节数格式化为可读文本。 */
  static formatSize(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    if (bytes < 1024) {
      return bytes + ' B';
    }
    if (bytes < 1024 * 1024) {
      return (bytes / 1024).toFixed(1) + ' KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    }
    return (bytes / (1024 * 1024 * 1024)).toFixed(1) + ' GB';
  }
}
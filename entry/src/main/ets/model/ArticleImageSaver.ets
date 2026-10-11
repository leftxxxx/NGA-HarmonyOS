import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { http } from '@kit.NetworkKit';
import { TopicAttachmentProtocol } from './TopicAttachmentProtocol';

export class NgaArticleImageSaveResult {
  success: boolean = false;
  cancelled: boolean = false;
  message: string = '';
}

/** Save only after an explicit system media-library confirmation; no broad media permission. */
export class ArticleImageSaver {
  static readonly MAX_IMAGE_BYTES: number = 20 * 1024 * 1024;
  private static busy: boolean = false;

  static async save(url: string, context: common.Context,
    isCurrent: () => boolean): Promise<NgaArticleImageSaveResult> {
    const result: NgaArticleImageSaveResult = new NgaArticleImageSaveResult();
    if (ArticleImageSaver.busy) {
      result.message = '正在保存图片，请稍候';
      return result;
    }
    if (!/^https:\/\/[^\s'"<>\\\x00-\x1f\x7f]+$/i.test(url) || !isCurrent()) {
      result.message = '图片地址无效';
      return result;
    }
    ArticleImageSaver.busy = true;
    let request: http.HttpRequest | undefined = undefined;
    let temporaryPath: string = '';
    let temporaryFile: fileIo.File | undefined = undefined;
    let destination: fileIo.File | undefined = undefined;
    let helper: photoAccessHelper.PhotoAccessHelper | undefined = undefined;
    try {
      request = http.createHttp();
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        maxLimit: ArticleImageSaver.MAX_IMAGE_BYTES,
        connectTimeout: 15000,
        readTimeout: 20000,
        header: { 'Referer': 'https://bbs.nga.cn/' }
      });
      if (!isCurrent()) {
        result.cancelled = true;
        return result;
      }
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer) ||
        response.result.byteLength === 0 || response.result.byteLength > ArticleImageSaver.MAX_IMAGE_BYTES) {
        result.message = '图片下载失败或超过 20 MB';
        return result;
      }
      const bytes: ArrayBuffer = response.result;
      const format: string = TopicAttachmentProtocol.detectImageType(bytes);
      const extension: string = ArticleImageSaver.extensionFor(format);
      if (extension.length === 0) {
        result.message = '暂不支持保存这种图片格式';
        return result;
      }
      const title: string = 'NGA_' + Date.now().toString();
      temporaryPath = context.cacheDir + '/article-image-' + title + '.' + extension;
      temporaryFile = await fileIo.open(temporaryPath, fileIo.OpenMode.CREATE |
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      let written: number = 0;
      while (written < bytes.byteLength) {
        const count: number = await fileIo.write(temporaryFile.fd, bytes.slice(written), { offset: written });
        if (count <= 0) {
          throw new Error('Incomplete image write');
        }
        written += count;
      }
      await fileIo.close(temporaryFile);
      temporaryFile = undefined;
      if (!isCurrent()) {
        result.cancelled = true;
        return result;
      }
      helper = photoAccessHelper.getPhotoAccessHelper(context);
      const config: photoAccessHelper.PhotoCreationConfig = {
        title: title, fileNameExtension: extension, photoType: photoAccessHelper.PhotoType.IMAGE
      };
      const created: string[] = await helper.showAssetsCreationDialog(
        [fileUri.getUriFromPath(temporaryPath)], [config]);
      if (created.length === 0 || !created[0].startsWith('file://')) {
        result.cancelled = true;
        return result;
      }
      // A confirmed save finishes even if the viewer was closed while the system dialog was open.
      destination = await fileIo.open(created[0], fileIo.OpenMode.WRITE_ONLY);
      await fileIo.copyFile(temporaryPath, destination.fd);
      result.success = true;
      result.message = '图片已保存到图库';
      return result;
    } catch (error) {
      result.message = '图片保存失败，请稍后重试';
      return result;
    } finally {
      try {
        if (request !== undefined) {
          request.destroy();
        }
      } catch (cleanupError) {}
      try {
        if (temporaryFile !== undefined) {
          await fileIo.close(temporaryFile);
        }
      } catch (cleanupError) {}
      try {
        if (destination !== undefined) {
          await fileIo.close(destination);
        }
      } catch (cleanupError) {}
      try {
        if (helper !== undefined) {
          await helper.release();
        }
      } catch (cleanupError) {}
      try {
        if (temporaryPath.length > 0) {
          await fileIo.unlink(temporaryPath);
        }
      } catch (cleanupError) {
        // A private cache file can be reclaimed by the system if cleanup fails.
      } finally {
        ArticleImageSaver.busy = false;
      }
    }
  }

  private static extensionFor(format: string): string {
    switch (format) {
      case 'image/jpeg': return 'jpg';
      case 'image/png': return 'png';
      case 'image/gif': return 'gif';
      case 'image/webp': return 'webp';
      case 'image/heif': return 'heic';
      case 'image/avif': return 'avif';
      case 'image/bmp': return 'bmp';
      default: return '';
    }
  }
}

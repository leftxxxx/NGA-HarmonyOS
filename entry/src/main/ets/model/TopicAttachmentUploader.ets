import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { HttpClient, HttpResult } from './HttpClient';
import { LoginStore } from './LoginStore';
import { NgaTopicPostInput, TopicPostProtocol } from './TopicPostProtocol';
import { TopicAttachmentProtocol, NgaTopicAttachmentPreparation, NgaTopicAttachmentResult } from './TopicAttachmentProtocol';

class NgaTopicUploadImage {
  content: ArrayBuffer = new ArrayBuffer(0);
  contentType: string = '';
}

/** 系统图库 URI → 异步读取/压缩 → NGA 附件上传；不提交帖子，不记录鉴权或图片内容。 */
export class TopicAttachmentUploader {
  static async upload(uri: string, input: NgaTopicPostInput,
    isCurrent: () => boolean): Promise<NgaTopicAttachmentResult> {
    let failure: string = '无法读取该图片，请重新选择';
    try {
      TopicAttachmentUploader.checkCurrent(isCurrent);
      if (!uri.startsWith('file://')) {
        return TopicAttachmentUploader.failed('请选择系统图库中的图片');
      }
      const content: ArrayBuffer = await TopicAttachmentUploader.readImage(uri, isCurrent);
      const contentType: string = TopicAttachmentProtocol.detectImageType(content);
      if (contentType.length === 0) {
        return TopicAttachmentUploader.failed('暂不支持该图片格式，请选择 JPG、PNG、GIF 或 WebP 图片');
      }
      failure = '图片处理失败，请尝试选择其他图片';
      const uploadImage: NgaTopicUploadImage = await TopicAttachmentUploader.prepareImage(content, contentType, isCurrent);
      TopicAttachmentUploader.checkCurrent(isCurrent);
      failure = '图片上传授权加载失败，请检查网络后重试';
      console.info('[NGAImageUpload] stage=prepare-start method=POST');
      const prepared: HttpResult = await HttpClient.post(TopicPostProtocol.buildPrepareUrl(input), {});
      TopicAttachmentUploader.checkCurrent(isCurrent);
      TopicAttachmentUploader.logPreparation(prepared);
      if (!prepared.success) {
        return TopicAttachmentUploader.failed(TopicAttachmentUploader.preparationFailure(prepared));
      }
      const auth: NgaTopicAttachmentPreparation =
        TopicAttachmentProtocol.parsePreparation(prepared.body, input.fid, input.stid);
      if (!auth.success) {
        console.info('[NGAImageUpload] stage=prepare-parse success=false');
        return TopicAttachmentUploader.failed(auth.errorMessage);
      }
      console.info('[NGAImageUpload] stage=prepare-parse success=true');
      failure = '图片上传失败，请检查网络后重试';
      const result: NgaTopicAttachmentResult = await TopicAttachmentUploader.uploadImage(uploadImage, auth, isCurrent);
      if (result.success) {
        result.previewSource = await TopicAttachmentUploader.createPreview(uploadImage, isCurrent);
        TopicAttachmentUploader.checkCurrent(isCurrent);
      }
      return result;
    } catch (error) {
      if (!isCurrent()) {
        return TopicAttachmentUploader.failed('已取消图片插入');
      }
      const message: string = (error as Error).message;
      if (message === '图片不能超过 10 MB' || message === '图片内容为空' ||
        message === '图片读取不完整，请重新选择' || message === '图片压缩后仍过大，请选择更小的图片') {
        return TopicAttachmentUploader.failed(message);
      }
      return TopicAttachmentUploader.failed(failure);
    }
  }

  /** 原始文本字段交给网络层组成 multipart，文件字段保持二进制。 */
  static buildFormParts(content: ArrayBuffer, contentType: string,
    preparation: NgaTopicAttachmentPreparation): http.MultiFormData[] {
    const filename: string = contentType === 'image/jpeg' ? 'image.jpg' :
      'image.' + contentType.substring('image/'.length);
    const fields: Record<string, string> = {
      'attachment_file1_url_utf8_name': filename,
      'fid': preparation.fid.toString(),
      'auth': preparation.auth,
      'func': 'upload',
      'v2': '1',
      'lite': 'js',
      'attachment_file1_auto_size': '',
      'attachment_file1_watermark': '',
      'attachment_file1_dscp': '',
      'attachment_file1_img': '1',
      'origin_domain': 'bbs.ngacn.cc'
    };
    const parts: http.MultiFormData[] = [{
      name: 'attachment_file1', contentType: contentType, remoteFileName: filename, data: content
    }];
    for (const key of Object.keys(fields)) {
      parts.push({ name: key, contentType: 'text/plain', data: fields[key] });
    }
    return parts;
  }

  private static async readImage(uri: string, isCurrent: () => boolean): Promise<ArrayBuffer> {
    const selectedFile: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = await fileIo.stat(selectedFile.fd);
      TopicAttachmentUploader.checkCurrent(isCurrent);
      if (!Number.isSafeInteger(stat.size) || stat.size <= 0) {
        throw new Error('图片内容为空');
      }
      if (stat.size > TopicAttachmentProtocol.MAX_FILE_BYTES) {
        throw new Error('图片不能超过 10 MB');
      }
      const content: ArrayBuffer = new ArrayBuffer(stat.size);
      const destination: Uint8Array = new Uint8Array(content);
      let position: number = 0;
      while (position < stat.size) {
        TopicAttachmentUploader.checkCurrent(isCurrent);
        const chunk: ArrayBuffer = new ArrayBuffer(Math.min(65536, stat.size - position));
        const readBytes: number = await fileIo.read(selectedFile.fd, chunk,
          { offset: position, length: chunk.byteLength });
        if (readBytes <= 0 || readBytes > chunk.byteLength) {
          throw new Error('图片读取不完整，请重新选择');
        }
        destination.set(new Uint8Array(chunk, 0, readBytes), position);
        position += readBytes;
      }
      return content;
    } finally {
      await fileIo.close(selectedFile);
    }
  }

  private static async prepareImage(content: ArrayBuffer, contentType: string,
    isCurrent: () => boolean): Promise<NgaTopicUploadImage> {
    const result: NgaTopicUploadImage = new NgaTopicUploadImage();
    result.content = content;
    result.contentType = contentType;
    const requiresConversion: boolean = contentType === 'image/heif' || contentType === 'image/avif' ||
      contentType === 'image/bmp';
    if (contentType === 'image/gif' ||
      (!requiresConversion && content.byteLength <= TopicAttachmentProtocol.COMPRESS_TARGET_BYTES)) {
      return result;
    }
    const source: image.ImageSource = image.createImageSource(content);
    let packer: image.ImagePacker | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      // 保留动图；NGA 会明确反馈超过其实际上传限额的图片。
      if (contentType === 'image/webp' && await source.getFrameCount() > 1) {
        return result;
      }
      const imageInfo: image.ImageInfo = await source.getImageInfo();
      if (imageInfo.size.width <= 0 || imageInfo.size.height <= 0) {
        throw new Error('图片尺寸无效');
      }
      const format: string = contentType === 'image/png' || contentType === 'image/webp' ? 'image/png' : 'image/jpeg';
      packer = image.createImagePacker();
      // PNG 保留透明区域；逐级缩小尺寸控制上传大小，JPEG 同时降低编码质量。
      const edges: number[] = [2048, 1440, 1024, 720, 512];
      const qualities: number[] = [85, 80, 75, 70, 65];
      for (let index: number = 0; index < edges.length; index++) {
        TopicAttachmentUploader.checkCurrent(isCurrent);
        const ratio: number = Math.min(1, edges[index] / Math.max(imageInfo.size.width, imageInfo.size.height));
        pixelMap = await source.createPixelMap({
          desiredSize: { width: Math.max(1, Math.floor(imageInfo.size.width * ratio)),
            height: Math.max(1, Math.floor(imageInfo.size.height * ratio)) }
        });
        const encoded: ArrayBuffer = await packer.packToData(pixelMap, {
          format: format, quality: qualities[index], bufferSize: 20 * 1024 * 1024, needsPackProperties: false
        });
        await pixelMap.release();
        pixelMap = undefined;
        if (encoded.byteLength > 0 && encoded.byteLength <= TopicAttachmentProtocol.COMPRESS_TARGET_BYTES) {
          result.content = encoded;
          result.contentType = format;
          return result;
        }
      }
      throw new Error('图片压缩后仍过大，请选择更小的图片');
    } finally {
      try {
        if (pixelMap !== undefined) {
          await pixelMap.release();
        }
      } finally {
        try {
          if (packer !== undefined) {
            await packer.release();
          }
        } finally {
          await source.release();
        }
      }
    }
  }

  private static async uploadImage(uploadImage: NgaTopicUploadImage,
    preparation: NgaTopicAttachmentPreparation, isCurrent: () => boolean): Promise<NgaTopicAttachmentResult> {
    TopicAttachmentUploader.checkCurrent(isCurrent);
    const httpRequest: http.HttpRequest = http.createHttp();
    let uploadStage: string = 'request';
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'multipart/form-data',
          'Cookie': LoginStore.getCookie(),
          'User-Agent': 'Nga_Official/80023',
          'Referer': HttpClient.getDomain() + '/post.php',
          'Accept-Charset': 'GBK'
        },
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        maxLimit: 1024 * 1024,
        connectTimeout: 15000,
        readTimeout: 60000,
        multiFormDataList: TopicAttachmentUploader.buildFormParts(uploadImage.content, uploadImage.contentType, preparation)
      };
      TopicAttachmentUploader.checkCurrent(isCurrent);
      const response: http.HttpResponse = await httpRequest.request(TopicAttachmentProtocol.ENDPOINT, options);
      TopicAttachmentUploader.checkCurrent(isCurrent);
      TopicAttachmentUploader.logUploadResponse(response);
      if (response.responseCode !== 200) {
        return TopicAttachmentUploader.failed('图片上传失败（HTTP ' + response.responseCode.toString() + '），请重试');
      }
      uploadStage = 'decode';
      const body: string = TopicAttachmentUploader.decodeResponse(response);
      console.info('[NGAImageUpload] stage=upload-structure chars=' + body.length.toString() +
        ' ' + TopicAttachmentProtocol.describeUpload(body));
      uploadStage = 'parse';
      const result: NgaTopicAttachmentResult = TopicAttachmentProtocol.parseUpload(body);
      const reason: string = result.failureStage === 'server' || result.failureStage === 'receipt' ||
        result.failureStage === 'json' ? result.failureStage : result.success ? 'none' : 'unknown';
      console.info('[NGAImageUpload] stage=upload-parse success=' + (result.success ? 'true' : 'false') + ' reason=' + reason);
      return result;
    } catch (error) {
      if (!isCurrent()) {
        throw new Error('已取消图片插入');
      }
      console.info('[NGAImageUpload] stage=upload-failed reason=' + uploadStage);
      if (uploadStage === 'decode') {
        return TopicAttachmentUploader.failed('图片上传响应无法解码，请稍后重试');
      }
      if (uploadStage === 'parse') {
        return TopicAttachmentUploader.failed('服务器返回了无法识别的图片上传结果，请稍后重试');
      }
      return TopicAttachmentUploader.failed('图片上传失败，请检查网络后重试');
    } finally {
      httpRequest.destroy();
    }
  }

  /** CDN 尚未同步时直接预览本次已上传的字节；生成失败不改变已确认的上传结果。 */
  private static async createPreview(uploadImage: NgaTopicUploadImage, isCurrent: () => boolean): Promise<string> {
    let source: image.ImageSource | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      TopicAttachmentUploader.checkCurrent(isCurrent);
      source = image.createImageSource(uploadImage.content);
      const info: image.ImageInfo = await source.getImageInfo();
      TopicAttachmentUploader.checkCurrent(isCurrent);
      if (!Number.isFinite(info.size.width) || !Number.isFinite(info.size.height) ||
        info.size.width <= 0 || info.size.height <= 0) { return ''; }
      const format: string = uploadImage.contentType === 'image/jpeg' ? 'image/jpeg' : 'image/png';
      packer = image.createImagePacker();
      const edges: number[] = [512, 384, 256, 192, 128];
      const qualities: number[] = [85, 80, 75, 70, 65];
      for (let index: number = 0; index < edges.length; index++) {
        TopicAttachmentUploader.checkCurrent(isCurrent);
        const ratio: number = Math.min(1, edges[index] / Math.max(info.size.width, info.size.height));
        pixelMap = await source.createPixelMap({
          desiredSize: { width: Math.max(1, Math.floor(info.size.width * ratio)),
            height: Math.max(1, Math.floor(info.size.height * ratio)) }
        });
        TopicAttachmentUploader.checkCurrent(isCurrent);
        const encoded: ArrayBuffer = await packer.packToData(pixelMap, {
          format: format, quality: qualities[index], bufferSize: 2 * 1024 * 1024, needsPackProperties: false
        });
        TopicAttachmentUploader.checkCurrent(isCurrent);
        await pixelMap.release();
        pixelMap = undefined;
        // 180 KiB 图片编码为 Base64 后，连同 data URI 前缀仍小于 256 KiB。
        if (encoded.byteLength > 0 && encoded.byteLength <= 180 * 1024) {
          const base64: util.Base64Helper = new util.Base64Helper();
          const data: string = await base64.encodeToString(new Uint8Array(encoded));
          TopicAttachmentUploader.checkCurrent(isCurrent);
          const preview: string = 'data:' + format + ';base64,' + data;
          return preview.length <= 256 * 1024 ? preview : '';
        }
      }
    } catch (error) {
      // 预览仅用于本次编辑器；编码/解码异常不得丢掉服务器已确认的附件回执。
    } finally {
      if (pixelMap !== undefined) {
        try { await pixelMap.release(); } catch (error) {}
      }
      if (packer !== undefined) {
        try { await packer.release(); } catch (error) {}
      }
      if (source !== undefined) {
        try { await source.release(); } catch (error) {}
      }
    }
    return '';
  }

  private static decodeResponse(response: http.HttpResponse): string {
    if (typeof response.result === 'string') {
      return response.result;
    }
    if (!(response.result instanceof ArrayBuffer)) {
      throw new Error('上传响应格式无效');
    }
    // 附件 v2 接口采用 UTF-8；与安卓 ResponseBody.string() 默认解码一致。
    let encoding: string = 'utf-8';
    const headers: Record<string, Object> = response.header as Record<string, Object>;
    for (const key of Object.keys(headers)) {
      const headerValue: Object = headers[key];
      if (key.toLowerCase() === 'content-type' && typeof headerValue === 'string') {
        const charset: RegExpMatchArray | null = headerValue.match(new RegExp('charset\\s*=\\s*["\']?([^;"\'\\s]+)', 'i'));
        if (charset !== null) {
          encoding = charset[1].toLowerCase();
        }
      }
    }
    const decoder: util.TextDecoder = util.TextDecoder.create(encoding, { ignoreBOM: true });
    return decoder.decodeToString(new Uint8Array(response.result), { stream: false });
  }

  private static checkCurrent(isCurrent: () => boolean): void {
    if (!isCurrent()) {
      throw new Error('已取消图片插入');
    }
  }

  private static logUploadResponse(response: http.HttpResponse): void {
    const status: number = Number.isSafeInteger(response.responseCode) && response.responseCode >= 0 &&
      response.responseCode <= 599 ? response.responseCode : 0;
    const kind: string = response.result instanceof ArrayBuffer ? 'array-buffer' :
      typeof response.result === 'string' ? 'string' : 'object';
    const length: number = response.result instanceof ArrayBuffer ? response.result.byteLength :
      typeof response.result === 'string' ? response.result.length : 0;
    console.info('[NGAImageUpload] stage=upload-http status=' + status.toString() +
      ' responseType=' + kind + ' length=' + length.toString());
  }

  /** 只输出有限枚举和整数，绝不输出错误原文、请求 URL、选图 URI、正文或鉴权。 */
  private static logPreparation(prepared: HttpResult): void {
    const status: number = Number.isSafeInteger(prepared.statusCode) && prepared.statusCode >= 0 &&
      prepared.statusCode <= 599 ? prepared.statusCode : 0;
    const code: number = Number.isSafeInteger(prepared.nativeErrorCode) && prepared.nativeErrorCode >= 0 &&
      prepared.nativeErrorCode <= 99999999 ? prepared.nativeErrorCode : 0;
    const reason: string = prepared.failureStage === 'request' || prepared.failureStage === 'decode' ||
      prepared.failureStage === 'http' ? prepared.failureStage : prepared.success ? 'none' : 'unknown';
    console.info('[NGAImageUpload] stage=prepare-http status=' + status.toString() +
      ' success=' + (prepared.success ? 'true' : 'false') + ' reason=' + reason + ' native=' + code.toString());
  }

  private static preparationFailure(prepared: HttpResult): string {
    if (prepared.statusCode >= 400 && prepared.statusCode <= 599) {
      return '图片上传授权请求失败（HTTP ' + prepared.statusCode.toString() + '），请稍后重试';
    }
    if (prepared.failureStage === 'decode') {
      return '图片上传授权响应无法解析，请重试';
    }
    if (prepared.nativeErrorCode === 2300028) {
      return '获取图片上传授权超时，请重试';
    }
    if (prepared.nativeErrorCode === 2300006 || prepared.nativeErrorCode === 2300007) {
      return '暂时无法连接图片上传授权服务器，请稍后重试';
    }
    return '图片上传授权加载失败，请检查网络后重试';
  }

  private static failed(message: string): NgaTopicAttachmentResult {
    const result: NgaTopicAttachmentResult = new NgaTopicAttachmentResult();
    result.errorMessage = message;
    return result;
  }
}

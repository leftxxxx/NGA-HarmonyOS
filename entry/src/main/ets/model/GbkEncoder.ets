import { util } from '@kit.ArkTS';

/** NGA 表单和搜索参数使用系统 GBK 编码，避免手写字表漏字或混入 UTF-8。 */
export class GbkEncoder {
  /** 百分号转义 GBK 字节；沿用原来的安全 ASCII 字符和空格转 + 规则。 */
  static encode(str: string): string {
    if (str.length === 0) {
      return '';
    }
    GbkEncoder.validateUtf16(str);
    const encoder: util.TextEncoder = new util.TextEncoder('gbk');
    const bytes: Uint8Array = encoder.encodeInto(str);
    const decoder: util.TextDecoder = util.TextDecoder.create('gbk', { ignoreBOM: true });
    // 系统编码器可能把 GBK 不支持的字符替换为 ?，不能将被改写的正文发送出去。
    if (decoder.decodeToString(bytes, { stream: false }) !== str) {
      throw new Error('文本包含 GBK 不支持的字符，请移除系统表情或特殊字符后重试');
    }
    let result: string = '';
    let trailingByte: boolean = false;
    for (const byte of bytes) {
      // GBK 双字节字符的尾字节也必须转义，即使其数值落在 ASCII 字母范围内。
      if (trailingByte) {
        result += '%' + GbkEncoder.byteToHex(byte);
        trailingByte = false;
      } else if (byte >= 0x81) {
        result += '%' + GbkEncoder.byteToHex(byte);
        trailingByte = true;
      } else if (GbkEncoder.isSafeAscii(byte)) {
        result += String.fromCharCode(byte);
      } else if (byte === 0x20) {
        result += '+';
      } else {
        result += '%' + GbkEncoder.byteToHex(byte);
      }
    }
    return result;
  }

  private static isSafeAscii(byte: number): boolean {
    return (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||
      (byte >= 0x30 && byte <= 0x39) || byte === 0x2D || byte === 0x5F ||
      byte === 0x2E || byte === 0x7E || byte === 0x21 || byte === 0x2A ||
      byte === 0x27 || byte === 0x28 || byte === 0x29;
  }

  private static validateUtf16(str: string): void {
    for (let index: number = 0; index < str.length; index++) {
      const code: number = str.charCodeAt(index);
      if (code >= 0xD800 && code <= 0xDBFF) {
        const next: number = index + 1 < str.length ? str.charCodeAt(index + 1) : 0;
        if (next < 0xDC00 || next > 0xDFFF) {
          throw new Error('文本包含无效字符，请删除该字符后重试');
        }
        index++;
      } else if (code >= 0xDC00 && code <= 0xDFFF) {
        throw new Error('文本包含无效字符，请删除该字符后重试');
      }
    }
  }

  private static byteToHex(byte: number): string {
    const hexChars: string = '0123456789ABCDEF';
    return hexChars.charAt((byte >> 4) & 0x0F) + hexChars.charAt(byte & 0x0F);
  }
}

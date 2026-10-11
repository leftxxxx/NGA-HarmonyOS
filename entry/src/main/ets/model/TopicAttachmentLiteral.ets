/** 附件接口返回的单一 NGA 赋值或纯对象数据；不执行任何 JavaScript。 */
export class TopicAttachmentLiteral {
  static parseResponse(body: string): Record<string, Object> {
    const reader: NgaAttachmentLiteralReader = new NgaAttachmentLiteralReader(body);
    return JSON.parse(reader.readResponse()) as Record<string, Object>;
  }
}

/** 限定对象字面量词法：对象/数组/字符串/有限数字/bool/null，完整消费响应。 */
class NgaAttachmentLiteralReader {
  private source: string;
  private cursor: number = 0;
  private jsLiteral: boolean = false;

  constructor(body: string) {
    if (body.length > 1024 * 1024) { throw new Error('附件响应大小无效'); }
    this.source = body.trim();
    if (this.source.length === 0 || this.source.length > 1024 * 1024) {
      throw new Error('附件响应大小无效');
    }
  }

  readResponse(): string {
    this.skipSpace();
    this.readMarkers();
    const assignment: string = 'window.script_muti_get_var_store';
    if (this.source.startsWith(assignment, this.cursor)) {
      this.jsLiteral = true;
      this.cursor += assignment.length;
      this.skipSpace();
      this.expect('=');
      this.skipSpace();
    }
    if (this.peek() !== '{') {
      throw new Error('附件响应不是单一对象');
    }
    const converted: string = this.readObject(0);
    this.skipSpace();
    if (this.jsLiteral && this.peek() === ';') {
      this.cursor++;
      this.skipSpace();
    }
    this.readMarkers();
    if (this.cursor !== this.source.length) {
      throw new Error('附件响应含不支持的尾部内容');
    }
    return converted;
  }

  private readMarkers(): void {
    for (let index: number = 0; index < 4 && this.source.startsWith('/*$js$*/', this.cursor); index++) {
      this.cursor += '/*$js$*/'.length;
      this.skipSpace();
    }
  }

  private readValue(depth: number): string {
    if (depth > 32) {
      throw new Error('附件响应嵌套过深');
    }
    this.skipSpace();
    const character: string = this.peek();
    if (character === '{') { return this.readObject(depth); }
    if (character === '[') { return this.readArray(depth); }
    if (character === '"' || character === "'") { return JSON.stringify(this.readString()); }
    for (const keyword of ['true', 'false', 'null']) {
      if (this.source.startsWith(keyword, this.cursor)) {
        this.cursor += keyword.length;
        return keyword;
      }
    }
    const numberText: RegExpMatchArray | null = this.source.substring(this.cursor)
      .match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/);
    if (numberText !== null && Number.isFinite(Number(numberText[0]))) {
      this.cursor += numberText[0].length;
      return numberText[0];
    }
    throw new Error('附件响应含不支持的值');
  }

  private readObject(depth: number): string {
    this.expect('{');
    this.skipSpace();
    const pairs: string[] = [];
    const keys: Set<string> = new Set<string>();
    if (this.peek() === '}') {
      this.cursor++;
      return '{}';
    }
    while (this.cursor < this.source.length) {
      const key: string = this.readKey();
      if (keys.has(key) || key === '__proto__' || key === 'constructor' || key === 'prototype') {
        throw new Error('附件响应含重复或保留字段');
      }
      keys.add(key);
      this.skipSpace();
      this.expect(':');
      pairs.push(JSON.stringify(key) + ':' + this.readValue(depth + 1));
      this.skipSpace();
      if (this.peek() === '}') {
        this.cursor++;
        return '{' + pairs.join(',') + '}';
      }
      this.expect(',');
      this.skipSpace();
      if (this.jsLiteral && this.peek() === '}') {
        this.cursor++;
        return '{' + pairs.join(',') + '}';
      }
    }
    throw new Error('附件响应对象未闭合');
  }

  private readArray(depth: number): string {
    this.expect('[');
    this.skipSpace();
    const values: string[] = [];
    if (this.peek() === ']') {
      this.cursor++;
      return '[]';
    }
    while (this.cursor < this.source.length) {
      values.push(this.readValue(depth + 1));
      this.skipSpace();
      if (this.peek() === ']') {
        this.cursor++;
        return '[' + values.join(',') + ']';
      }
      this.expect(',');
      this.skipSpace();
      if (this.jsLiteral && this.peek() === ']') {
        this.cursor++;
        return '[' + values.join(',') + ']';
      }
    }
    throw new Error('附件响应数组未闭合');
  }

  private readKey(): string {
    this.skipSpace();
    const quote: string = this.peek();
    if (quote === '"' || quote === "'") { return this.readString(); }
    if (!this.jsLiteral) { throw new Error('JSON 字段必须带双引号'); }
    const identifier: RegExpMatchArray | null = this.source.substring(this.cursor)
      .match(/^(?:[a-zA-Z_$][a-zA-Z0-9_$]*|[0-9]+)/);
    if (identifier === null) {
      throw new Error('附件响应字段格式无效');
    }
    this.cursor += identifier[0].length;
    return identifier[0];
  }

  private readString(): string {
    const quote: string = this.peek();
    if (quote === "'" && !this.jsLiteral) { throw new Error('JSON 字符串必须带双引号'); }
    this.cursor++;
    let decoded: string = '';
    while (this.cursor < this.source.length) {
      const character: string = this.source.charAt(this.cursor++);
      if (character === quote) { return decoded; }
      if (character.charCodeAt(0) < 32) {
        throw new Error('附件响应字符串含未转义控制字符');
      }
      if (character !== '\\') {
        decoded += character;
        continue;
      }
      const escaped: string = this.source.charAt(this.cursor++);
      if (escaped === '\\' || escaped === '"' || (escaped === "'" && this.jsLiteral) || escaped === '/') {
        decoded += escaped;
      } else if (escaped === 'b') { decoded += '\b';
      } else if (escaped === 'f') { decoded += '\f';
      } else if (escaped === 'n') { decoded += '\n';
      } else if (escaped === 'r') { decoded += '\r';
      } else if (escaped === 't') { decoded += '\t';
      } else if ((escaped === 'x' && this.jsLiteral) || escaped === 'u') {
        const length: number = escaped === 'x' ? 2 : 4;
        const hex: string = this.source.substring(this.cursor, this.cursor + length);
        if (hex.length !== length || !/^[a-fA-F0-9]+$/.test(hex)) {
          throw new Error('附件响应字符串转义无效');
        }
        decoded += String.fromCharCode(parseInt(hex, 16));
        this.cursor += length;
      } else {
        throw new Error('附件响应字符串转义无效');
      }
    }
    throw new Error('附件响应字符串未闭合');
  }

  private peek(): string { return this.source.charAt(this.cursor); }

  private skipSpace(): void {
    while (this.cursor < this.source.length && /[ \t\r\n]/.test(this.peek())) { this.cursor++; }
  }

  private expect(character: string): void {
    if (this.peek() !== character) { throw new Error('附件响应数据格式无效'); }
    this.cursor++;
  }
}

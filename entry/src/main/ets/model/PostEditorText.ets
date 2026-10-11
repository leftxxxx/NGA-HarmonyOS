export class NgaPostEditorInsertion {
  content: string = '';
  caret: number = 0;
}

/** 编辑器保存论坛原始正文，插入时替换选区并保留其余文字。 */
export class PostEditorText {
  static insert(content: string, start: number, end: number, markup: string): NgaPostEditorInsertion {
    const first: number = PostEditorText.offset(content, start);
    const last: number = PostEditorText.offset(content, end);
    const from: number = Math.min(first, last);
    const to: number = Math.max(first, last);
    const result: NgaPostEditorInsertion = new NgaPostEditorInsertion();
    result.content = content.substring(0, from) + markup + content.substring(to);
    result.caret = from + markup.length;
    return result;
  }

  private static offset(content: string, position: number): number {
    let offset: number = Number.isFinite(position) && position >= 0 ? Math.min(content.length, Math.floor(position)) :
      content.length;
    if (offset > 0 && offset < content.length && content.charCodeAt(offset) >= 0xdc00 &&
      content.charCodeAt(offset) <= 0xdfff && content.charCodeAt(offset - 1) >= 0xd800 &&
      content.charCodeAt(offset - 1) <= 0xdbff) {
      offset--;
    }
    return offset;
  }
}

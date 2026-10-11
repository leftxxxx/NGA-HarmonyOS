/*
 * 板块数据模型。
 * 对应 Android Board.java：fid（板块ID）、stid（子板块ID）、name（板块名称）、boardHead（板块头像）。
 */

export class Board {
  fid: number = 0;
  stid: number = 0;
  name: string = '';
  boardHead: string = '';

  constructor(fid: number = 0, stid: number = 0, name: string = '') {
    this.fid = fid;
    this.stid = stid;
    this.name = name;
  }
}
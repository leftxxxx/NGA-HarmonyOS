/*
 * 表情 UBB 码解码工具。
 * 将 [s:类别:名称]、[s:数字] 及默认分类数字别名替换为 <img> HTML 标签。
 * 对应 Android ForumEmoticonDecoder + ForumBasicDecoder 的表情处理部分。
 *
 * 分类表情优先读取已打包的 rawfile，避免已失效的远程 smile 路径。
 * 类别：ac(AC娘) / a2(新版AC娘) / ng(NG娘) / pg(企鹅) / pst(潘斯特) / dt(外域三人组)
 */

/** 调用方将 rawfile 相对路径转为 Web 可读取的图片地址（通常是 data URI）。 */
export type LocalEmoticonSource = (path: string) => string;

/** 官方 js_bbscode_core.js 的 smiles[0]：数字编码并非 aN.gif。 */
const LEGACY_MAP: Record<string, string> = {
  '1': 'smile.gif', '2': 'mrgreen.gif', '3': 'question.gif', '4': 'wink.gif',
  '5': 'redface.gif', '6': 'sad.gif', '7': 'cool.gif', '8': 'crazy.gif',
  '24': '04.gif', '25': '05.gif', '26': '06.gif', '27': '07.gif',
  '28': '08.gif', '29': '09.gif', '30': '10.gif', '32': '12.gif',
  '33': '13.gif', '34': '14.gif', '35': '15.gif', '36': '16.gif',
  '37': '17.gif', '38': '18.gif', '39': '19.gif', '40': '20.gif',
  '41': '21.gif', '42': '22.gif', '43': '23.gif'
};

/** AC娘表情是否使用反转滤镜（夜间模式） */
const ACNIANG_CATEGORIES: string[] = ['ac', 'a2'];

/** AC娘 (ac) UBB 码 → 文件名映射 (45个) */
const AC_MAP: Record<string, string> = {
  'blink': '-47218_5052bca81a77f.png',
  'goodjob': '-47218_5052bd3b4b3bd.png',
  '上': '-1324875_50e597f5ce78d.png',
  '中枪': '-47218_5052bcba15fcf.png',
  '偷笑': '-47218_5052bcb6e96d1.png',
  '冷': '-47218_5052bd2a0d49a.png',
  '凌乱': '-47218_5052c10aa0303.png',
  '反对': '-47218_5052bcaaacb45.png',
  '吓': '-1324875_50e597c090c58.png',
  '吻': '-47218_5052c104b8e27.png',
  '呆': '-47218_5052bc587c6f9.png',
  '咦': '-47218_5052c1076f119.png',
  '哦': '-47218_5052bd2497822.png',
  '哭': '-47218_5052bd2fa0790.png',
  '哭1': '-47218_5052c0f6da079.png',
  '哭笑': '-47218_5052bc4cc6331.png',
  '哼': '-47218_5052bcf37c4c9.png',
  '喘': '-1324875_513394fbc54e1.gif',
  '喷': '-47218_5052bc4f51be7.png',
  '嘲笑': '-47218_5052c1101747c.png',
  '嘲笑1': '-47218_5052c10d1f08c.png',
  '囧': '-47218_5052bcdd279bc.png',
  '委屈': '-47218_5052bce27ab4d.png',
  '心': '-47218_5052bd35aec58.png',
  '忧伤': '-47218_5052bcdfd9c69.png',
  '怒': '-47218_5052bc835856c.png',
  '怕': '-47218_5052bce4f2963.png',
  '惊': '-47218_5052bd330dfad.png',
  '愁': '-47218_5052bc7d91913.png',
  '抓狂': '-47218_5052c112b3b1b.png',
  '抠鼻': '-47218_5052bcf0ba2db.png',
  '擦汗': '-47218_5052bc8638067.png',
  '无语': '-47218_5052bca55cb6e.png',
  '晕': '-47218_5052bc521c04b.png',
  '汗': '-47218_5052bca2a2f43.png',
  '瞎': '-47218_5052bcad49530.png',
  '羞': '-47218_5052bceb823da.png',
  '羡慕': '-47218_5052bc80140e3.png',
  '花痴': '-47218_5052bcb3b8944.png',
  '茶': '-1324875_50d841a63a673.png',
  '衰': '-47218_5052bcf68ddc2.png',
  '计划通': '-1324875_50e597e9d6319.png',
  '赞同': '-47218_5052bd27520ef.png',
  '闪光': '-47218_5052bcbe35760.png',
  '黑枪': '-1324875_50e597f190a11.png'
};

/** 新版AC娘 (a2) UBB 码 → 文件名映射 (46个) */
const A2_MAP: Record<string, string> = {
  'goodjob': 'a2_02.png',
  '诶嘿': 'a2_05.png',
  '偷笑': 'a2_03.png',
  '怒': 'a2_04.png',
  '笑': 'a2_07.png',
  '那个…': 'a2_08.png',
  '哦嗬嗬嗬': 'a2_09.png',
  '舔': 'a2_10.png',
  '鬼脸': 'a2_14.png',
  '冷': 'a2_16.png',
  '大哭': 'a2_15.png',
  '哭': 'a2_17.png',
  '恨': 'a2_21.png',
  '中枪': 'a2_23.png',
  '囧': 'a2_24.png',
  '你看看你': 'a2_25.png',
  'doge': 'a2_27.png',
  '自戳双目': 'a2_28.png',
  '偷吃': 'a2_30.png',
  '冷笑': 'a2_31.png',
  '壁咚': 'a2_32.png',
  '不活了': 'a2_33.png',
  '不明觉厉': 'a2_36.png',
  '是在下输了': 'a2_51.png',
  '你为猴这么': 'a2_53.png',
  '干杯': 'a2_54.png',
  '干杯2': 'a2_55.png',
  '异议': 'a2_47.png',
  '认真': 'a2_48.png',
  '你已经死了': 'a2_45.png',
  '你这种人…': 'a2_49.png',
  '妮可妮可妮': 'a2_18.png',
  '惊': 'a2_19.png',
  '抢镜头': 'a2_52.png',
  'yes': 'a2_26.png',
  '有何贵干': 'a2_11.png',
  '病娇': 'a2_12.png',
  'lucky': 'a2_13.png',
  'poi': 'a2_20.png',
  '囧2': 'a2_22.png',
  '威吓': 'a2_42.png',
  'jojo立': 'a2_37.png',
  'jojo立2': 'a2_38.png',
  'jojo立3': 'a2_39.png',
  'jojo立4': 'a2_41.png',
  'jojo立5': 'a2_40.png'
};

/** NG娘 (ng)：官方 js_bbscode_core.js smiles.ng 的 34 个有效映射。 */
const NG_MAP: Record<string, string> = {
  '呲牙笑': 'ng_1.png',
  '奸笑': 'ng_2.png',
  '问号': 'ng_3.png',
  '茶': 'ng_4.png',
  '笑指': 'ng_5.png',
  '燃尽': 'ng_6.png',
  '晕': 'ng_7.png',
  '扇笑': 'ng_8.png',
  '寄': 'ng_9.png',
  '别急': 'ng_10.png',
  'doge': 'ng_11.png',
  '丧': 'ng_12.png',
  '汗': 'ng_13.png',
  '叹气': 'ng_15.png',
  '吃饼': 'ng_16.png',
  '吃瓜': 'ng_17.png',
  '吐舌': 'ng_18.png',
  '哭': 'ng_19.png',
  '喘': 'ng_20.png',
  '心': 'ng_21.png',
  '喷': 'ng_22.png',
  '困': 'ng_24.png',
  '大哭': 'ng_25.png',
  '大惊': 'ng_26.png',
  '害怕': 'ng_27.png',
  '惊': 'ng_28.png',
  '暴怒': 'ng_30.png',
  '气愤': 'ng_31.png',
  '热': 'ng_32.png',
  '瓜不熟': 'ng_33.png',
  '瞎': 'ng_34.png',
  '色': 'ng_35.png',
  '斜眼': 'ng_37.png',
  '问号大': 'ng_38.png'
};

/** 企鹅 (pg) UBB 码 → 文件名映射 (15个) */
const PG_MAP: Record<string, string> = {
  '战斗力': 'pg01.png',
  '哈啤': 'pg02.png',
  '满分': 'pg03.png',
  '衰': 'pg04.png',
  '拒绝': 'pg05.png',
  '心': 'pg06.png',
  '严肃': 'pg07.png',
  '吃瓜': 'pg08.png',
  '嘣': 'pg09.png',
  '嘣2': 'pg10.png',
  '冻': 'pg11.png',
  '谢': 'pg12.png',
  '哭': 'pg13.png',
  '响指': 'pg14.png',
  '转身': 'pg15.png'
};

/** 潘斯特 (pst) UBB 码 → 文件名映射 (65个) */
const PST_MAP: Record<string, string> = {
  '举手': 'pt00.png',
  '亲': 'pt01.png',
  '偷笑': 'pt02.png',
  '偷笑2': 'pt03.png',
  '偷笑3': 'pt04.png',
  '傻眼': 'pt05.png',
  '傻眼2': 'pt06.png',
  '兔子': 'pt07.png',
  '发光': 'pt08.png',
  '呆': 'pt09.png',
  '呆2': 'pt10.png',
  '呆3': 'pt11.png',
  '呕': 'pt12.png',
  '呵欠': 'pt13.png',
  '哭': 'pt14.png',
  '哭2': 'pt15.png',
  '哭3': 'pt16.png',
  '嘲笑': 'pt17.png',
  '基': 'pt18.png',
  '宅': 'pt19.png',
  '安慰': 'pt20.png',
  '幸福': 'pt21.png',
  '开心': 'pt22.png',
  '开心2': 'pt23.png',
  '开心3': 'pt24.png',
  '怀疑': 'pt25.png',
  '怒': 'pt26.png',
  '怒2': 'pt27.png',
  '怨': 'pt28.png',
  '惊吓': 'pt29.png',
  '惊吓2': 'pt30.png',
  '惊呆': 'pt31.png',
  '惊呆2': 'pt32.png',
  '惊呆3': 'pt33.png',
  '惨': 'pt34.png',
  '斜眼': 'pt35.png',
  '晕': 'pt36.png',
  '汗': 'pt37.png',
  '泪': 'pt38.png',
  '泪2': 'pt39.png',
  '泪3': 'pt40.png',
  '泪4': 'pt41.png',
  '满足': 'pt42.png',
  '满足2': 'pt43.png',
  '火星': 'pt44.png',
  '牙疼': 'pt45.png',
  '电击': 'pt46.png',
  '看戏': 'pt47.png',
  '眼袋': 'pt48.png',
  '眼镜': 'pt49.png',
  '笑而不语': 'pt50.png',
  '紧张': 'pt51.png',
  '美味': 'pt52.png',
  '背': 'pt53.png',
  '脸红': 'pt54.png',
  '脸红2': 'pt55.png',
  '腐': 'pt56.png',
  '星星眼': 'pt57.png',
  '谢': 'pt58.png',
  '醉': 'pt59.png',
  '闷': 'pt60.png',
  '闷2': 'pt61.png',
  '音乐': 'pt62.png',
  '黑脸': 'pt63.png',
  '鼻血': 'pt64.png'
};

/** 外域三人组 (dt) UBB 码 → 文件名映射 (33个) */
const DT_MAP: Record<string, string> = {
  'ROLL': 'dt01.png',
  '上': 'dt02.png',
  '傲娇': 'dt03.png',
  '叉出去': 'dt04.png',
  '发光': 'dt05.png',
  '呵欠': 'dt06.png',
  '哭': 'dt07.png',
  '啃古头': 'dt08.png',
  '嘲笑': 'dt09.png',
  '心': 'dt10.png',
  '怒': 'dt11.png',
  '怒2': 'dt12.png',
  '怨': 'dt13.png',
  '惊': 'dt14.png',
  '惊2': 'dt15.png',
  '无语': 'dt16.png',
  '星星眼': 'dt17.png',
  '星星眼2': 'dt18.png',
  '晕': 'dt19.png',
  '注意': 'dt20.png',
  '注意2': 'dt21.png',
  '泪': 'dt22.png',
  '泪2': 'dt23.png',
  '烧': 'dt24.png',
  '笑': 'dt25.png',
  '笑2': 'dt26.png',
  '笑3': 'dt27.png',
  '脸红': 'dt28.png',
  '药': 'dt29.png',
  '衰': 'dt30.png',
  '鄙视': 'dt31.png',
  '闲': 'dt32.png',
  '黑脸': 'dt33.png'
};

/** 所有类别映射表：类别 → (UBB码 → 文件名) */
const EMOTION_TABLE: Record<string, Record<string, string>> = {
  'ac': AC_MAP,
  'a2': A2_MAP,
  'ng': NG_MAP,
  'pg': PG_MAP,
  'pst': PST_MAP,
  'dt': DT_MAP
};

/** 表情类别列表（用于表情选择器） */
export const EMOTION_CATEGORIES: string[] = ['ac', 'a2', 'ng', 'pg', 'pst', 'dt'];

/** 表情类别中文名列表 */
export const EMOTION_CATEGORY_LABELS: Record<string, string> = {
  'ac': 'AC娘',
  'a2': '新版AC娘',
  'ng': 'NG娘',
  'pg': '企鹅',
  'pst': '潘斯特',
  'dt': '外域三人组'
};

/**
 * 判断类别是否为 AC娘类（需要反转滤镜）。
 */
function isAcNiangCategory(category: string): boolean {
  for (const cat of ACNIANG_CATEGORIES) {
    if (category === cat) {
      return true;
    }
  }
  return false;
}

/**
 * 解码 [s:类别:名称] 格式的表情 UBB 码。
 * 将表情码替换为 <img> HTML 标签，优先使用已打包资源。
 *
 * @param content 原始内容
 * @return 替换后的 HTML 内容
 */
export function decodeEmoticons(content: string, localSource?: LocalEmoticonSource): string {
  // 官网将空分类视为默认分类 0，因此 [s::1] 与 [s:0:1] 都是 smile.gif。
  const pattern: RegExp = /\[s:([a-z0-9_]*):([^\]\r\n]+)\]/gi;
  return content.replace(pattern, (matched: string, categoryValue: string, emoticon: string): string => {
    const category: string = categoryValue.toLowerCase();
    const path: string = getEmoticonRawfilePath(category, emoticon);
    if (path.length === 0) {
      return matched;
    }
    const localUrl: string = localSource !== undefined ? localSource(path) : '';
    const source: string = localUrl || getEmoticonImageUrl(category, emoticon);
    if (!isEmoticonImageSource(source)) {
      return matched;
    }
    const cssClass: string = isAcNiangCategory(category) ? 'emoticon invertFilter' : 'emoticon';
    return `<img class='${cssClass}' src='${escapeImageAttribute(source)}' alt='${escapeImageAttribute(matched)}' style='height:1.5em;vertical-align:middle;'>`;
  });
}

/**
 * 解码 [s:数字] 格式的旧版表情 UBB 码。
 * 按官方映射读取本地 GIF；未定义的数字编码保留原文。
 *
 * @param content 原始内容
 * @return 替换后的 HTML 内容
 */
export function decodeLegacyEmoticons(content: string, localSource?: LocalEmoticonSource): string {
  return content.replace(/\[s:(\d+)\]/gi, (matched: string, number: string): string => {
    const file: string | undefined = LEGACY_MAP[number];
    if (file === undefined) {
      return matched;
    }
    const path: string = getLegacyEmoticonRawfilePath(number);
    const local: string = localSource !== undefined ? localSource(path) : '';
    const source: string = local || 'https://img4.nga.cn/ngabbs/post/smile/' + file;
    if (!isEmoticonImageSource(source)) {
      return matched;
    }
    return `<img class='emoticon' src='${escapeImageAttribute(source)}' alt='${escapeImageAttribute(matched)}' style='height:1.5em;vertical-align:middle;'>`;
  });
}

/**
 * 解码所有表情 UBB 码（先解码分类表情，再解码旧版数字表情）。
 *
 * @param content 原始内容
 * @return 替换后的 HTML 内容
 */
export function decodeAllEmoticons(content: string, localSource?: LocalEmoticonSource): string {
  let result: string = decodeEmoticons(content, localSource);
  result = decodeLegacyEmoticons(result, localSource);
  return result;
}

/**
 * 获取指定类别的所有表情项（用于表情选择器）。
 * 返回 UBB 码列表，如 ['blink', 'goodjob', ...]
 */
export function getEmoticonList(category: string): string[] {
  if (category === '' || category === '0') {
    return Object.keys(LEGACY_MAP);
  }
  const categoryMap: Record<string, string> | undefined = getKnownCategoryMap(category);
  if (categoryMap === undefined) {
    return [];
  }
  return Object.keys(categoryMap);
}

/**
 * 获取指定类别和表情名的图片 URL。
 */
export function getEmoticonImageUrl(category: string, emoticon: string): string {
  if (category === '' || category === '0') {
    const legacyPath: string = getLegacyEmoticonRawfilePath(emoticon);
    return legacyPath.length > 0 ? 'https://img4.nga.cn/ngabbs/post/smile/' + LEGACY_MAP[emoticon] : '';
  }
  const categoryMap: Record<string, string> | undefined = getKnownCategoryMap(category);
  if (categoryMap === undefined) {
    return '';
  }
  if (Object.keys(categoryMap).indexOf(emoticon) < 0) {
    return '';
  }
  const imageFile: string | undefined = categoryMap[emoticon];
  if (typeof imageFile !== 'string') {
    return '';
  }
  // 旧 AC 图片的文件名包含创建时间，实际位于 attachments/mon_YYYYMM/DD。
  // 新分类的网络别名不可推导，调用方应使用已打包的本地资源。
  const timestamp: RegExpMatchArray | null = imageFile.match(/^-[0-9]+_([0-9a-f]{8})[0-9a-f]*\.(?:png|gif)$/i);
  if (timestamp === null) {
    return '';
  }
  const date: Date = new Date((parseInt(timestamp[1], 16) + 8 * 60 * 60) * 1000);
  const month: string = (date.getUTCMonth() + 1).toString().padStart(2, '0');
  const day: string = date.getUTCDate().toString().padStart(2, '0');
  return 'https://img.nga.cn/attachments/mon_' + date.getUTCFullYear().toString() + month + '/' + day + '/' + imageFile;
}

/** 分类表情的实际 rawfile 路径，所有映射项均已随包提供。 */
export function getEmoticonRawfilePath(category: string, emoticon: string): string {
  if (category === '' || category === '0') {
    return getLegacyEmoticonRawfilePath(emoticon);
  }
  const categoryMap: Record<string, string> | undefined = getKnownCategoryMap(category);
  if (categoryMap === undefined || Object.keys(categoryMap).indexOf(emoticon) < 0) {
    return '';
  }
  const file: string | undefined = categoryMap !== undefined ? categoryMap[emoticon] : undefined;
  return typeof file === 'string' ? 'emoticon/' + category.toLowerCase() + '/' + file : '';
}

export function getLegacyEmoticonRawfilePath(number: string): string {
  if (Object.keys(LEGACY_MAP).indexOf(number) < 0) {
    return '';
  }
  const file: string | undefined = LEGACY_MAP[number];
  return typeof file === 'string' ? 'emoticon/legacy/' + file : '';
}

/** 对类别先检查允许列表，避免 Record 访问继承的原型属性。 */
function getKnownCategoryMap(category: string): Record<string, string> | undefined {
  const normalizedCategory: string = category.toLowerCase();
  return EMOTION_CATEGORIES.indexOf(normalizedCategory) >= 0 ? EMOTION_TABLE[normalizedCategory] : undefined;
}

function isEmoticonImageSource(source: string): boolean {
  return /^data:image\/(?:png|gif|jpe?g|webp);base64,[a-z0-9+/=]+$/i.test(source) ||
    /^https:\/\/[^\s'"<>\\]+$/i.test(source);
}

function escapeImageAttribute(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/'/g, '&#39;').replace(/"/g, '&quot;')
    .replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/**
 * 将表情的网络 URL 映射到本地 rawfile 路径。
 * 用于 [img]表情URL[/img] 格式的表情本地化。
 * 对应 Android EmoticonUtils.getPathByURI()。
 *
 * @param url 表情图片的网络 URL
 * @return 本地 rawfile 路径（如 'emoticon/ac/-47218_xxx.png'），未找到返回空字符串
 */
export function getPathByUrl(url: string): string {
  // 提取 URL 中的文件名
  const cleanUrl: string = url.split(/[?#]/)[0];
  const lastSlashIdx: number = cleanUrl.lastIndexOf('/');
  if (lastSlashIdx < 0) {
    return '';
  }
  const fileName: string = cleanUrl.substring(lastSlashIdx + 1);

  if (/^https?:\/\/(?:img\d*\.)?nga\.(?:cn|178\.com)\/ngabbs\/post\/smile\//i.test(cleanUrl)) {
    for (const number of Object.keys(LEGACY_MAP)) {
      if (LEGACY_MAP[number] === fileName) {
        return 'emoticon/legacy/' + fileName;
      }
    }
  }

  // 在所有类别中查找该文件名
  for (const category of Object.keys(EMOTION_TABLE)) {
    const categoryMap: Record<string, string> = EMOTION_TABLE[category];
    for (const emoticon of Object.keys(categoryMap)) {
      if (categoryMap[emoticon] === fileName) {
        return 'emoticon/' + category + '/' + fileName;
      }
    }
  }
  return '';
}

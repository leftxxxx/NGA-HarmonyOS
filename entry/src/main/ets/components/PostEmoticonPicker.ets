import {
  EMOTION_CATEGORIES,
  EMOTION_CATEGORY_LABELS,
  getEmoticonList,
  getEmoticonRawfilePath
} from '../model/EmoticonUtils';
import {
  COLOR_DAY_CARD,
  COLOR_NIGHT_CARD,
  COLOR_DAY_SUB,
  COLOR_NIGHT_SUB,
  themeAccentTextColor,
  themeSecondarySurfaceColor
} from '../model/AppTheme';

/** 发帖和回复共用的本地表情面板，由外层 Sheet 管理关闭。 */
@Component
export struct PostEmoticonPicker {
  @Prop nightMode: boolean = false;
  @State private selectedCategory: string = 'ac';
  @State private emoticonNames: string[] = getEmoticonList('ac');
  onSelect: (code: string) => void = (_code: string): void => {};
  private categoryCodes: string[] = EMOTION_CATEGORIES.concat(['0']);
  private gridScroller: Scroller = new Scroller();

  private categoryLabel(category: string): string {
    return category === '0' ? '经典表情' : (EMOTION_CATEGORY_LABELS[category] ?? category);
  }

  private selectCategory(category: string): void {
    if (category === this.selectedCategory) {
      return;
    }
    this.selectedCategory = category;
    this.emoticonNames = getEmoticonList(category);
    this.gridScroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }

  private insertEmoticon(name: string): void {
    this.onSelect('[s:' + this.selectedCategory + ':' + name + ']');
  }

  build() {
    Column({ space: 12 }) {
      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.categoryCodes, (category: string) => {
            Button({ type: ButtonType.Capsule }) {
              Text(this.categoryLabel(category))
                .fontSize(14)
                .fontWeight(this.selectedCategory === category ? FontWeight.Medium : FontWeight.Regular)
                .fontColor(this.selectedCategory === category ? themeAccentTextColor(this.nightMode) :
                  (this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB))
                .maxLines(1)
            }
            .height(44)
            .padding({ left: 14, right: 14 })
            .backgroundColor(this.selectedCategory === category ? themeSecondarySurfaceColor(this.nightMode) :
              Color.Transparent)
            .accessibilityText(this.categoryLabel(category))
            .id('post-emoticon-category-' + category)
            .onClick((): void => this.selectCategory(category))
          }, (category: string): string => category)
        }
      }
      .width('100%')
      .height(44)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)

      Grid(this.gridScroller) {
        ForEach(this.emoticonNames, (name: string) => {
          GridItem() {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 3 }) {
                Image($rawfile(getEmoticonRawfilePath(this.selectedCategory, name)))
                  .width(32)
                  .height(32)
                  .objectFit(ImageFit.Contain)
                  .invert(this.nightMode && (this.selectedCategory === 'ac' || this.selectedCategory === 'a2') ? 1 : 0)
                Text(name)
                  .fontSize(11)
                  .fontColor(this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Center)
                  .width('100%')
              }
              .width('100%')
            }
            .width('100%')
            .height(60)
            .padding(4)
            .borderRadius(12)
            .backgroundColor(Color.Transparent)
            .accessibilityText('插入' + this.categoryLabel(this.selectedCategory) + '表情：' + name)
            .id('post-emoticon-' + this.selectedCategory + '-' + name)
            .onClick((): void => this.insertEmoticon(name))
          }
        }, (name: string): string => this.selectedCategory + ':' + name)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
      .columnsGap(8)
      .rowsGap(8)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .width('100%')

      Text('点击表情可连续插入')
        .fontSize(12)
        .fontColor(this.nightMode ? COLOR_NIGHT_SUB : COLOR_DAY_SUB)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 16 })
    .backgroundColor(this.nightMode ? COLOR_NIGHT_CARD : COLOR_DAY_CARD)
    .id('post-emoticon-picker')
  }
}

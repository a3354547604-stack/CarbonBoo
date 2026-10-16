/**
 * ScienceDetailPage —— 科普文章（附录 C §17，二级页 `scienceDetail`）。
 *
 * 正文由 `ScienceService.body()` 从 rawfile 读入，`MarkdownRenderer` 转成可渲染的块；
 * 滚动 ≥80% 且停留 ≥3 秒才标记已读（口径同 D4-4），收藏写 `science_progress`。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { RouteName, RouteParam, NavParams } from '../viewmodel/RouteName';
import { ScienceArticleMeta, ScienceProgress } from '../model/ScienceTypes';
import { ScienceService } from '../viewmodel/ScienceService';
import { AppTheme, LiteralConstants } from '../util/AppTheme';
import { Formatter } from '../util/Formatter';
import { DateUtil } from '../util/DateUtil';
import { MarkdownRenderer, MdBlock } from '../util/MarkdownRenderer';
import { PageHeader } from '../components/PageHeader';
import { SectionCard } from '../components/SectionCard';
import { EmptyView } from '../components/EmptyView';
import { LoadingOverlay } from '../components/LoadingOverlay';

@Component
export struct ScienceDetailPage {
  @Consume('navStack') stack: NavPathStack;
  @State meta: ScienceArticleMeta | undefined = undefined;
  @State blocks: MdBlock[] = [];
  @State title: string = '';
  @State summary: string = '';
  @State favorited: boolean = false;
  @State progress: number = 0;
  @State prevId: string = '';
  @State nextId: string = '';
  @State read: boolean = false;
  @State ready: boolean = false;
  private articleId: string = '';
  private enterAt: number = 0;
  private marked: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const param: RouteParam = NavParams.take();
    const id: string | undefined = param.articleId;
    this.articleId = id === undefined ? '' : id;
    this.enterAt = Date.now();
    this.reload();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const userId: string = hub.state.userId();
    const meta: ScienceArticleMeta | undefined = await hub.science.metaOf(this.articleId);
    if (meta === undefined) {
      this.ready = true;
      return;
    }
    const text: string = await hub.science.body(this.articleId);
    const blocks: MdBlock[] = MarkdownRenderer.parse(text);
    const prog: ScienceProgress | undefined = (await hub.science.progressMap(userId)).get(this.articleId);
    const nb: Map<string, string> = await hub.science.neighbours(this.articleId);
    const prev: string | undefined = nb.get('prev');
    const next: string | undefined = nb.get('next');
    this.meta = meta;
    this.title = meta.title;
    this.summary = meta.summary === undefined ? '' : meta.summary;
    this.blocks = blocks;
    this.favorited = prog !== undefined && prog.isFavorite === 1;
    this.progress = prog === undefined ? 0 : prog.progress;
    this.read = ScienceService.isRead(prog);
    this.prevId = prev === undefined ? '' : prev;
    this.nextId = next === undefined ? '' : next;
    this.ready = true;
  }

  /** 滚动到底部附近且停留够久才标已读（页脚按钮触发，保证 ≥80% 阅读）。 */
  private async markRead(): Promise<void> {
    if (this.marked || this.read) {
      this.marked = true;
      return;
    }
    const dwell: number = Date.now() - this.enterAt;
    const hub: ServiceHub = ServiceHub.get();
    if (dwell >= LiteralConstants.READ_DWELL_MS) {
      await hub.science.markProgress(hub.state.userId(), this.articleId, 1);
      this.progress = 1;
      this.read = true;
    }
    this.marked = true;
  }

  private async toggleFavorite(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    this.favorited = await hub.science.toggleFavorite(hub.state.userId(), this.articleId);
  }

  private go(articleId: string): void {
    if (articleId.length === 0) {
      return;
    }
    NavParams.set(RouteParam.article(articleId));
    this.scroller.scrollEdge(Edge.Top);
    this.ready = false;
    this.marked = false;
    this.enterAt = Date.now();
    this.articleId = articleId;
    this.reload();
  }

  @Builder
  listLines(items: string[]) {
    Column({ space: 4 }) {
      ForEach(items, (line: string, index: number) => {
        Text(`· ${line}`)
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .width('100%')
      }, (line: string, index: number) => `li-${index}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  tableBlock(header: string[], rows: string[][]) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        ForEach(header, (cell: string, index: number) => {
          Text(cell)
            .fontSize(AppTheme.FONT_CAPTION)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
            .layoutWeight(1)
        }, (cell: string, index: number) => `th-${index}`)
      }
      .width('100%')
      ForEach(rows, (row: string[], rowIndex: number) => {
        Row({ space: 8 }) {
          ForEach(row, (cell: string, cellIndex: number) => {
            Text(cell)
              .fontSize(AppTheme.FONT_CAPTION)
              .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
              .layoutWeight(1)
          }, (cell: string, cellIndex: number) => `td-${rowIndex}-${cellIndex}`)
        }
        .width('100%')
      }, (row: string[], rowIndex: number) => `tr-${rowIndex}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  blockView(block: MdBlock) {
    Column({ space: 4 }) {
      if (block.kind === 'h1' || block.kind === 'h2' || block.kind === 'h3') {
        Text(block.text === undefined ? '' : block.text)
          .fontSize(block.kind === 'h1' ? AppTheme.FONT_TITLE : AppTheme.FONT_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .width('100%')
      } else if (block.kind === 'ul' || block.kind === 'ol') {
        this.listLines(block.items === undefined ? [] : block.items)
      } else if (block.kind === 'quote') {
        Text(block.text === undefined ? '' : block.text)
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          .padding({ left: AppTheme.CARD_GAP })
          .borderWidth({ left: 2 })
          .borderColor(AppTheme.COLOR_DIVIDER)
          .width('100%')
      } else if (block.kind === 'divider') {
        Divider().color(AppTheme.COLOR_DIVIDER)
      } else if (block.kind === 'table') {
        this.tableBlock(block.header === undefined ? [] : block.header,
          block.rows === undefined ? [] : block.rows)
      } else {
        Text(block.text === undefined ? '' : block.text)
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
          .lineHeight(AppTheme.FONT_BODY * 1.7)
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      PageHeader({
        title: this.meta === undefined ? $r('app.string.science_title') : ScienceService.categoryName(this.meta.category),
        onBack: () => this.stack.pop()
      })

      if (!this.ready) {
        LoadingOverlay({ visible: true, text: '' })
      } else if (this.meta === undefined) {
        EmptyView({ text: '文章不存在', hint: '回到科普列表重新选择' })
      } else {
        Scroll(this.scroller) {
          Column({ space: AppTheme.CARD_GAP }) {
            SectionCard({ showTitle: false }) {
              Text(this.title)
                .fontSize(AppTheme.FONT_TITLE)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                .width('100%')
              Row({ space: 8 }) {
                Text(`${ScienceService.categoryName(this.meta.category)} · ${this.meta.readMinutes} 分钟`)
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_TEXT_HINT)
                  .layoutWeight(1)
                Text(this.favorited ? $r('app.string.science_favorited') : $r('app.string.science_favorite'))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(this.favorited ? AppTheme.COLOR_WARNING : AppTheme.COLOR_PRIMARY)
                  .onClick(() => this.toggleFavorite())
              }
              .width('100%')
              Row({ space: 8 }) {
                Text(ScienceService.percentText(this.progress))
                  .fontSize(AppTheme.FONT_CAPTION)
                  .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
                if (this.read) {
                  Text($r('app.string.science_read_tag'))
                    .fontSize(AppTheme.FONT_CAPTION)
                    .fontColor(AppTheme.COLOR_TEXT_HINT)
                }
              }
              .width('100%')
            }

            ForEach(this.blocks, (block: MdBlock) => {
              this.blockView(block)
            }, (block: MdBlock, index: number) => `b-${index}`)

            Row({ space: AppTheme.CARD_GAP }) {
              Text($r('app.string.science_prev'))
                .fontSize(AppTheme.FONT_BODY)
                .fontColor(this.prevId.length > 0 ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_TEXT_HINT)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .height(AppTheme.BTN_HEIGHT)
                .onClick(() => this.go(this.prevId))
              Text($r('app.string.science_next'))
                .fontSize(AppTheme.FONT_BODY)
                .fontColor(this.nextId.length > 0 ? AppTheme.COLOR_PRIMARY : AppTheme.COLOR_TEXT_HINT)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .height(AppTheme.BTN_HEIGHT)
                .onClick(() => this.go(this.nextId))
            }
            .width('100%')

            Button($r('app.string.science_mark_read'))
              .width('100%')
              .height(AppTheme.BTN_HEIGHT)
              .backgroundColor(AppTheme.COLOR_PRIMARY)
              .fontColor(AppTheme.COLOR_SURFACE)
              .onClick(() => this.markRead())
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .onScrollEdge((side: Edge) => {
          if (side === Edge.Bottom) {
            this.markRead();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING })
    .backgroundColor(AppTheme.COLOR_BG)
  }
}

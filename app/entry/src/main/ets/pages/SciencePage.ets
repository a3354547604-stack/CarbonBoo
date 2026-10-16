/**
 * SciencePage —— 双碳科普（附录 C §8，Tab3）。
 *
 * 12 篇文章来自 `science_article` 表（种子由 `SeedRepository` 从 `science/science-index.json` 写入），
 * 正文 Markdown 从 rawfile 读（不联网）。收藏与已读状态走 `ScienceService`。
 */
import { ServiceHub } from '../viewmodel/ServiceHub';
import { RouteName, RouteParam, NavParams } from '../viewmodel/RouteName';
import { ScienceArticleMeta, ScienceProgress } from '../model/ScienceTypes';
import { ScienceService } from '../viewmodel/ScienceService';
import { AppTheme } from '../util/AppTheme';
import { SegmentedBar, SegmentOption } from '../components/SegmentedBar';
import { EmptyView } from '../components/EmptyView';
import { LoadingOverlay } from '../components/LoadingOverlay';
import { PageHeader } from '../components/PageHeader';

@Component
export struct SciencePage {
  @Prop @Watch('onTick') tick: number = 0;
  @Consume('navStack') stack: NavPathStack;
  @State articles: ScienceArticleMeta[] = [];
  @State progress: Map<string, ScienceProgress> = new Map();
  @State favoriteIds: string[] = [];
  @State filter: string = 'all';
  @State keyword: string = '';
  @State searching: boolean = false;
  @State ready: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  onTick(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    const hub: ServiceHub = ServiceHub.get();
    const userId: string = hub.state.userId();
    const list: ScienceArticleMeta[] = await hub.science.list();
    this.articles = list;
    this.progress = await hub.science.progressMap(userId);
    const favs: ScienceArticleMeta[] = await hub.science.favorites(userId);
    const ids: string[] = [];
    let i: number = 0;
    while (i < favs.length) {
      ids.push(favs[i].id);
      i = i + 1;
    }
    this.favoriteIds = ids;
    this.ready = true;
  }

  private options(): SegmentOption[] {
    const opts: SegmentOption[] = [
      SegmentOption.of('all', '全部'), SegmentOption.of('policy', '政策'),
      SegmentOption.of('tips', '低碳技巧'), SegmentOption.of('knowledge', '知识')
    ];
    return opts;
  }

  private matches(meta: ScienceArticleMeta): boolean {
    if (this.filter !== 'all' && meta.category !== this.filter) {
      return false;
    }
    if (this.keyword.length === 0) {
      return true;
    }
    const kw: string = this.keyword;
    if (meta.title.indexOf(kw) >= 0) {
      return true;
    }
    let i: number = 0;
    while (i < meta.tags.length) {
      if (meta.tags[i].indexOf(kw) >= 0) {
        return true;
      }
      i = i + 1;
    }
    const summary: string = meta.summary === undefined ? '' : meta.summary;
    return summary.indexOf(kw) >= 0;
  }

  private visible(): ScienceArticleMeta[] {
    const out: ScienceArticleMeta[] = [];
    let i: number = 0;
    while (i < this.articles.length) {
      if (this.matches(this.articles[i])) {
        out.push(this.articles[i]);
      }
      i = i + 1;
    }
    return out;
  }

  private favoriteArticles(): ScienceArticleMeta[] {
    const out: ScienceArticleMeta[] = [];
    let i: number = 0;
    while (i < this.articles.length) {
      if (this.favoriteIds.indexOf(this.articles[i].id) >= 0) {
        out.push(this.articles[i]);
      }
      i = i + 1;
    }
    return out;
  }

  private isRead(id: string): boolean {
    return ScienceService.isRead(this.progress.get(id));
  }

  private push(articleId: string): void {
    NavParams.set(RouteParam.article(articleId));
    this.stack.pushPath({ name: RouteName.SCIENCE_DETAIL });
  }

  private categoryIcon(category: string): string {
    if (category === 'policy') {
      return '📜';
    }
    if (category === 'tips') {
      return '💡';
    }
    return '🌍';
  }

  @Builder
  articleCard(meta: ScienceArticleMeta, showFavorite: boolean) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.categoryIcon(meta.category)).fontSize(AppTheme.ICON_MD)
        Text(meta.title)
          .fontSize(AppTheme.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isRead(meta.id) ? AppTheme.COLOR_TEXT_HINT : AppTheme.COLOR_TEXT_PRIMARY)
          .layoutWeight(1)
          .maxLines(2)
        if (this.isRead(meta.id)) {
          Text($r('app.string.science_read_tag'))
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppTheme.COLOR_TEXT_HINT)
        }
      }
      .width('100%')
      if (meta.summary !== undefined) {
        Text(meta.summary)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_SECONDARY)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Row({ space: 8 }) {
        Text(ScienceService.categoryName(meta.category))
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_PRIMARY)
        Text(`${meta.readMinutes} 分钟`)
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(AppTheme.COLOR_TEXT_HINT)
        if (showFavorite) {
          Text('★')
            .fontSize(AppTheme.FONT_CAPTION)
            .fontColor(AppTheme.COLOR_WARNING)
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AppTheme.CARD_PADDING)
    .backgroundColor(AppTheme.COLOR_SURFACE)
    .borderRadius(AppTheme.CARD_RADIUS)
    .onClick(() => this.push(meta.id))
  }

  build() {
    Column({ space: AppTheme.CARD_GAP }) {
      PageHeader({
        title: $r('app.string.science_title'),
        showBack: false,
        onBack: () => {}
      }) {
        Text($r('app.string.common_search'))
          .fontSize(AppTheme.FONT_BODY)
          .fontColor(AppTheme.COLOR_PRIMARY)
          .height(AppTheme.HEADER_HEIGHT)
          .onClick(() => {
            this.searching = !this.searching;
          })
      }

      if (this.searching) {
        TextInput({ placeholder: $r('app.string.science_search_hint'), text: this.keyword })
          .height(AppTheme.BTN_HEIGHT)
          .backgroundColor(AppTheme.COLOR_SURFACE)
          .borderRadius(AppTheme.BTN_RADIUS)
          .fontSize(AppTheme.FONT_BODY)
          .onChange((value: string) => {
            this.keyword = value;
          })
      }

      SegmentedBar({
        options: this.options(),
        selected: this.filter,
        onSelect: (key: string) => {
          this.filter = key;
        }
      })

      Scroll() {
        Column({ space: AppTheme.CARD_GAP }) {
          if (!this.ready) {
            LoadingOverlay({ visible: true, text: '' })
          } else if (this.visible().length === 0) {
            EmptyView({ text: '没有匹配的文章', hint: '换个关键词试试' })
          } else {
            if (this.filter === 'all' && this.favoriteArticles().length > 0) {
              Text($r('app.string.science_my_favorite'))
                .fontSize(AppTheme.FONT_SECTION)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.COLOR_TEXT_PRIMARY)
                .width('100%')
              ForEach(this.favoriteArticles(), (meta: ScienceArticleMeta) => {
                this.articleCard(meta, true)
              }, (meta: ScienceArticleMeta) => `fav-${meta.id}`)
            }
            ForEach(this.visible(), (meta: ScienceArticleMeta) => {
              this.articleCard(meta, false)
            }, (meta: ScienceArticleMeta) => meta.id)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: AppTheme.PAGE_PADDING, right: AppTheme.PAGE_PADDING })
    .backgroundColor(AppTheme.COLOR_BG)
  }
}

/**
 * ScienceService —— 科普（S5）：索引、正文、阅读进度、收藏。
 *
 * 职责：
 *  ① 索引来自 `science_article`（app-core 从 `rawfile/science/science-index.json` 播种），
 *     正文来自 `rawfile/science/<id>.md`（本层读，**不联网**）；
 *  ② 阅读进度：滚动 ≥80% 且停留 ≥3 秒 → 写 `science_progress.progress = 1`
 *     （`ScienceReadTracker` 判定，见 `components/ScienceReader`）；
 *  ③ 收藏：`is_favorite` 0/1，UPSERT 到 `uq_sp(user_id, article_id)`；
 *  ④ 分类计数与「我的收藏」分组，供科普页与我的页使用。
 *
 * 为什么正文不进数据库：12 篇 Markdown 是**静态资源**，进库会让备份体积无谓翻倍，
 * 也让「改一篇文章」需要迁移数据；索引进库只是为了排序与筛选能被 SQL 处理。
 */
import { ScienceArticleMeta, ScienceCategory, ScienceProgress } from '../model/ScienceTypes';
import { StorePort, firstOf, numOf, textOf } from './store/StorePort';
import { RowMapper } from './store/RowMapper';
import { ResourcePort } from './store/ResourcePort';
import { AppState } from './AppState';
import { IdUtil } from './domain/IdUtil';

/** 科普页的一个分类块（含计数）。 */
export interface ScienceGroup {
  category: ScienceCategory;
  name: string;
  count: number;
}

export class ScienceService {
  private readonly store: StorePort;
  private readonly state: AppState;
  private readonly resources: ResourcePort;

  constructor(store: StorePort, state: AppState, resources: ResourcePort) {
    this.store = store;
    this.state = state;
    this.resources = resources;
  }

  /** 全部文章（按 `order`）。 */
  async list(): Promise<ScienceArticleMeta[]> {
    const rows = await this.store.query('SELECT * FROM science_article ORDER BY "order" ASC', []);
    return RowMapper.scienceMetas(rows);
  }

  /** 分类计数（政策 4 / 技巧 4 / 知识 4）。 */
  async groups(): Promise<ScienceGroup[]> {
    const all: ScienceArticleMeta[] = await this.list();
    const cats: ScienceCategory[] = ['policy', 'tips', 'knowledge'];
    const out: ScienceGroup[] = [];
    let i: number = 0;
    while (i < cats.length) {
      let n: number = 0;
      let k: number = 0;
      while (k < all.length) {
        if (all[k].category === cats[i]) {
          n = n + 1;
        }
        k = k + 1;
      }
      out.push({ category: cats[i], name: ScienceService.categoryName(cats[i]), count: n });
      i = i + 1;
    }
    return out;
  }

  /** 分类中文名。 */
  static categoryName(category: ScienceCategory): string {
    if (category === 'policy') {
      return '政策';
    }
    if (category === 'tips') {
      return '低碳技巧';
    }
    return '知识';
  }

  /** 阅读进度表（articleId → 进度）。 */
  async progressMap(userId: string): Promise<Map<string, ScienceProgress>> {
    const rows = await this.store.query(
      'SELECT article_id, progress, is_favorite, last_read_at FROM science_progress WHERE user_id = ? AND is_deleted = 0',
      [userId]
    );
    const list: ScienceProgress[] = RowMapper.scienceProgressList(rows);
    const out = new Map<string, ScienceProgress>();
    let i: number = 0;
    while (i < list.length) {
      out.set(list[i].articleId, list[i]);
      i = i + 1;
    }
    return out;
  }

  /** 单篇元信息。 */
  async metaOf(articleId: string): Promise<ScienceArticleMeta | undefined> {
    const rows = await this.store.query('SELECT * FROM science_article WHERE id = ?', [articleId]);
    const row = firstOf(rows);
    return row === undefined ? undefined : RowMapper.scienceMeta(row);
  }

  /** 正文 Markdown（rawfile；缺文件返回空串，由页面显示「正文加载失败」）。 */
  async body(articleId: string): Promise<string> {
    return this.resources.readRawText(`science/${articleId}.md`);
  }

  /** 上一篇 / 下一篇（按 order）。 */
  async neighbours(articleId: string): Promise<Map<string, string>> {
    const all: ScienceArticleMeta[] = await this.list();
    const out = new Map<string, string>();
    let i: number = 0;
    while (i < all.length) {
      if (all[i].id === articleId) {
        if (i > 0) {
          out.set('prev', all[i - 1].id);
        }
        if (i + 1 < all.length) {
          out.set('next', all[i + 1].id);
        }
        break;
      }
      i = i + 1;
    }
    return out;
  }

  /**
   * 标记已读（口径：滚动 ≥80% 且停留 ≥3 秒，附录 C §17 规则 3 / 验收 D4-4）。
   * @param userId 用户
   * @param articleId 文章
   * @param progress 0~1
   */
  async markProgress(userId: string, articleId: string, progress: number): Promise<void> {
    const now: number = Date.now();
    const clamped: number = progress < 0 ? 0 : (progress > 1 ? 1 : progress);
    await this.store.exec(
      'INSERT INTO science_progress (id, user_id, article_id, progress, is_favorite, last_read_at, created_at, updated_at, is_deleted, device_id, sync_state) ' +
      'VALUES (?, ?, ?, ?, 0, ?, ?, ?, 0, ?, ?) ' +
      'ON CONFLICT(user_id, article_id) DO UPDATE SET ' +
      'progress = MAX(science_progress.progress, excluded.progress), last_read_at = excluded.last_read_at, ' +
      'updated_at = excluded.updated_at, is_deleted = 0',
      [IdUtil.uuid(), userId, articleId, clamped, now, now, now, this.state.deviceId(), this.state.syncState()]
    );
  }

  /** 切换收藏（返回切换后的状态）。 */
  async toggleFavorite(userId: string, articleId: string): Promise<boolean> {
    const map = await this.progressMap(userId);
    const cur: ScienceProgress | undefined = map.get(articleId);
    const next: number = cur === undefined || cur.isFavorite === 0 ? 1 : 0;
    const now: number = Date.now();
    await this.store.exec(
      'INSERT INTO science_progress (id, user_id, article_id, progress, is_favorite, last_read_at, created_at, updated_at, is_deleted, device_id, sync_state) ' +
      'VALUES (?, ?, ?, 0, ?, NULL, ?, ?, 0, ?, ?) ' +
      'ON CONFLICT(user_id, article_id) DO UPDATE SET is_favorite = excluded.is_favorite, updated_at = excluded.updated_at, is_deleted = 0',
      [IdUtil.uuid(), userId, articleId, next, now, now, this.state.deviceId(), this.state.syncState()]
    );
    return next === 1;
  }

  /** 收藏文章（按 order）。 */
  async favorites(userId: string): Promise<ScienceArticleMeta[]> {
    const rows = await this.store.query(
      'SELECT a.* FROM science_article a JOIN science_progress p ON p.article_id = a.id ' +
      "WHERE p.user_id = ? AND p.is_favorite = 1 AND p.is_deleted = 0 ORDER BY a.\"order\" ASC",
      [userId]
    );
    return RowMapper.scienceMetas(rows);
  }

  /** 已读数（「我的」页可展示 12 篇里的进度）。 */
  async readCount(userId: string): Promise<number> {
    const rows = await this.store.query(
      'SELECT COUNT(*) AS n FROM science_progress WHERE user_id = ? AND is_deleted = 0 AND progress >= 1',
      [userId]
    );
    const row = firstOf(rows);
    return row === undefined ? 0 : numOf(row, 'n');
  }

  /** 本地搜索（标题 + 标签 + 摘要，不联网）。 */
  async search(userId: string, keyword: string): Promise<ScienceArticleMeta[]> {
    const all: ScienceArticleMeta[] = await this.list();
    if (keyword.length === 0) {
      return all;
    }
    const out: ScienceArticleMeta[] = [];
    let i: number = 0;
    while (i < all.length) {
      const a: ScienceArticleMeta = all[i];
      const summary: string = a.summary === undefined ? '' : a.summary;
      const hit: boolean = a.title.indexOf(keyword) >= 0 || summary.indexOf(keyword) >= 0 || a.tags.join(',').indexOf(keyword) >= 0;
      if (hit) {
        out.push(a);
      }
      i = i + 1;
    }
    return out;
  }

  /** 已读判定用的进度值（供页面显示 `▓▓▓ 62%`）。 */
  static percentText(progress: number): string {
    const p: number = progress < 0 ? 0 : (progress > 1 ? 1 : progress);
    return `${Math.round(p * 100)}%`;
  }

  /** `progress` 列的中文展示（列表里的「已读 ✓」）。 */
  static isRead(p: ScienceProgress | undefined): boolean {
    return p !== undefined && p.progress >= 1;
  }
}

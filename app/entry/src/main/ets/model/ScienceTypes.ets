/**
 * ScienceTypes —— 双碳科普域类型（12 篇内置文章）。
 *
 * 职责：定义科普分类 `ScienceCategory`、索引元信息 `ScienceArticleMeta`、阅读进度 `ScienceProgress`。
 *
 * 依据：`docs/APPENDIX-B-data-and-api.md` §4 + §8.6；分类计数政策 4 / 技巧 4 / 知识 4；
 * 正文为 Markdown，落 `rawfile/science/sci-01.md` … `sci-12.md`，**完全离线**。
 * 已读判定统一为「滚动 ≥80% 且停留 ≥3 秒」（B18）。
 */
export type ScienceCategory = 'policy' | 'tips' | 'knowledge';

/** 科普索引条目，与 `rawfile/science/science-index.json` 逐字段对应。 */
export interface ScienceArticleMeta {
  id: string;
  title: string;
  category: ScienceCategory;
  summary?: string;
  cover?: string;
  readMinutes: number;
  tags: string[];
  order: number;
}

export interface ScienceProgress {
  articleId: string;
  /** 0~1。 */
  progress: number;
  isFavorite: number;
  lastReadAt?: number;
}

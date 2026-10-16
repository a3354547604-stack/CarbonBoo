/**
 * RowMapper —— SQL 行 → 模型对象的**唯一映射点**。
 *
 * 职责：把 `RowShape`（列名 → string|number|null）翻译成 model 层类型
 *（`CarbonRecord` / `PointRecord` / `GoalDef` / `BadgeDef` / `ShopItem` / `Appearance` /
 * `ScienceArticleMeta` / `ScienceProgress` / `CarbonIncludeRecord` / `SyncLogRow`）。
 *
 * 为什么必须有这一层：19 张表的列名是 snake_case、模型字段是 camelCase，
 * 如果每个 Service 各写一遍取值，就会出现「某页把 `point_capped` 读成 `is_capped` 而静默为 0」
 * 这类只有肉眼能发现的错。列名与字段名只在这里对齐一次。
 *
 * 窄化口径：枚举列非法值**抛错**（见 `RowMapper.category`），
 * 其余缺列按「0 / 空串」处理——因为 SELECT 的列是代码自己写的，缺列属编程错误而非数据问题。
 */
import {
  CarbonRecord, CategoryKey, Confidence, SyncState,
} from '../../model/CarbonTypes';
import { FlowKind, PointRecord, PointSourceType, PointType } from '../../model/PointTypes';
import { GoalDef, GoalMetric, GoalPeriod, GoalTier } from '../../model/GoalTypes';
import { BadgeDef, BadgeMetric } from '../../model/BadgeTypes';
import { Appearance, ShopItem } from '../../model/ShopTypes';
import { ScienceArticleMeta, ScienceCategory, ScienceProgress } from '../../model/ScienceTypes';
import { CarbonIncludeRecord, IncludeBenefit } from '../../model/IncludeTypes';
import { RowShape, numOf, optNumOf, optTextOf, textOf } from './StorePort';

/** 积分流水行（`sync_log` 之外的展示扩展）。 */
export interface SyncLogRow {
  id: string;
  userId: string;
  peerDevice: string;
  direction: string;
  status: string;
  pulledCount: number;
  pushedCount: number;
  conflictCount: number;
  errorMsg?: string;
  startedAt: number;
  finishedAt?: number;
  createdAt: number;
}

export class RowMapper {
  // ---------------------------------------------------------------- 碳记录

  static carbonRecord(row: RowShape): CarbonRecord {
    const out: CarbonRecord = {
      id: textOf(row, 'id'),
      userId: textOf(row, 'user_id'),
      category: RowMapper.category(textOf(row, 'category')),
      subType: textOf(row, 'sub_type'),
      amount: numOf(row, 'amount'),
      unit: textOf(row, 'unit'),
      occurredAt: numOf(row, 'occurred_at'),
      reductionKg: numOf(row, 'reduction_kg'),
      factorValue: numOf(row, 'factor_value'),
      factorVersion: textOf(row, 'factor_version'),
      factorSource: textOf(row, 'factor_source'),
      confidence: RowMapper.confidence(textOf(row, 'confidence')),
      pointAwarded: numOf(row, 'point_awarded'),
      revision: numOf(row, 'revision'),
      pointCapped: numOf(row, 'point_capped'),
      isAbnormal: numOf(row, 'is_abnormal'),
      createdAt: numOf(row, 'created_at'),
      updatedAt: numOf(row, 'updated_at'),
      isDeleted: numOf(row, 'is_deleted'),
      syncState: RowMapper.syncState(textOf(row, 'sync_state')),
    };
    const note: string | undefined = optTextOf(row, 'note');
    if (note !== undefined) {
      out.note = note;
    }
    const device: string | undefined = optTextOf(row, 'device_id');
    if (device !== undefined) {
      out.deviceId = device;
    }
    return out;
  }

  static carbonRecords(rows: RowShape[]): CarbonRecord[] {
    const out: CarbonRecord[] = [];
    let i: number = 0;
    while (i < rows.length) {
      out.push(RowMapper.carbonRecord(rows[i]));
      i = i + 1;
    }
    return out;
  }

  // ---------------------------------------------------------------- 积分

  static pointRecord(row: RowShape): PointRecord {
    const out: PointRecord = {
      id: textOf(row, 'id'),
      userId: textOf(row, 'user_id'),
      type: RowMapper.pointType(textOf(row, 'type')),
      flowKind: RowMapper.flowKind(textOf(row, 'flow_kind')),
      points: numOf(row, 'points'),
      sourceType: RowMapper.sourceType(textOf(row, 'source_type')),
      sourceId: textOf(row, 'source_id'),
      title: textOf(row, 'title'),
      occurredAt: numOf(row, 'occurred_at'),
      createdAt: numOf(row, 'created_at'),
      updatedAt: numOf(row, 'updated_at'),
      isDeleted: numOf(row, 'is_deleted'),
      syncState: RowMapper.syncState(textOf(row, 'sync_state')),
    };
    const remark: string | undefined = optTextOf(row, 'remark');
    if (remark !== undefined) {
      out.remark = remark;
    }
    const device: string | undefined = optTextOf(row, 'device_id');
    if (device !== undefined) {
      out.deviceId = device;
    }
    return out;
  }

  static pointRecords(rows: RowShape[]): PointRecord[] {
    const out: PointRecord[] = [];
    let i: number = 0;
    while (i < rows.length) {
      out.push(RowMapper.pointRecord(rows[i]));
      i = i + 1;
    }
    return out;
  }

  // ---------------------------------------------------------------- 目标 / 徽章

  static goalDef(row: RowShape): GoalDef {
    const out: GoalDef = {
      id: textOf(row, 'id'),
      name: textOf(row, 'name'),
      tier: RowMapper.tier(textOf(row, 'tier')),
      period: RowMapper.period(textOf(row, 'period')),
      metric: RowMapper.goalMetric(textOf(row, 'metric')),
      threshold: numOf(row, 'threshold'),
      reward: numOf(row, 'reward'),
      icon: textOf(row, 'icon'),
      order: numOf(row, 'order'),
    };
    const category: string | undefined = optTextOf(row, 'category');
    if (category !== undefined && category.length > 0) {
      out.category = RowMapper.category(category);
    }
    const subTypes: string | undefined = optTextOf(row, 'sub_types');
    if (subTypes !== undefined && subTypes.length > 0) {
      out.subTypes = RowMapper.stringArray(subTypes);
    }
    const unit: string | undefined = optTextOf(row, 'unit');
    if (unit !== undefined && unit.length > 0) {
      out.unit = unit;
    }
    return out;
  }

  static goalDefs(rows: RowShape[]): GoalDef[] {
    const out: GoalDef[] = [];
    let i: number = 0;
    while (i < rows.length) {
      out.push(RowMapper.goalDef(rows[i]));
      i = i + 1;
    }
    return out;
  }

  static badgeDef(row: RowShape): BadgeDef {
    return {
      id: textOf(row, 'id'),
      name: textOf(row, 'name'),
      description: textOf(row, 'description'),
      tier: RowMapper.badgeTier(textOf(row, 'tier')),
      icon: textOf(row, 'icon'),
      metric: RowMapper.badgeMetric(textOf(row, 'metric')),
      threshold: numOf(row, 'threshold'),
      order: numOf(row, 'order'),
    };
  }

  static badgeDefs(rows: RowShape[]): BadgeDef[] {
    const out: BadgeDef[] = [];
    let i: number = 0;
    while (i < rows.length) {
      out.push(RowMapper.badgeDef(rows[i]));
      i = i + 1;
    }
    return out;
  }

  // ---------------------------------------------------------------- 商品 / 外观

  static shopItem(row: RowShape): ShopItem {
    const out: ShopItem = {
      id: textOf(row, 'id'),
      section: RowMapper.section(textOf(row, 'section')),
      name: textOf(row, 'name'),
      price: numOf(row, 'price'),
      icon: textOf(row, 'icon'),
      order: numOf(row, 'order'),
      onShelf: numOf(row, 'on_shelf'),
      isDefaultFree: numOf(row, 'is_default_free'),
    };
    const description: string | undefined = optTextOf(row, 'description');
    if (description !== undefined) {
      out.description = description;
    }
    return out;
  }

  static shopItems(rows: RowShape[]): ShopItem[] {
    const out: ShopItem[] = [];
    let i: number = 0;
    while (i < rows.length) {
      out.push(RowMapper.shopItem(rows[i]));
      i = i + 1;
    }
    return out;
  }

  static appearance(row: RowShape): Appearance {
    const out: Appearance = {
      avatarId: textOf(row, 'avatar_id'),
      themeId: textOf(row, 'theme_id'),
    };
    const frame: string | undefined = optTextOf(row, 'frame_id');
    if (frame !== undefined && frame.length > 0) {
      out.frameId = frame;
    }
    const nickname: string | undefined = optTextOf(row, 'nickname');
    if (nickname !== undefined) {
      out.nickname = nickname;
    }
    return out;
  }

  // ---------------------------------------------------------------- 科普

  static scienceMeta(row: RowShape): ScienceArticleMeta {
    const out: ScienceArticleMeta = {
      id: textOf(row, 'id'),
      title: textOf(row, 'title'),
      category: RowMapper.scienceCategory(textOf(row, 'category')),
      readMinutes: numOf(row, 'read_minutes'),
      tags: RowMapper.stringArray(textOf(row, 'tags')),
      order: numOf(row, 'order'),
    };
    const summary: string | undefined = optTextOf(row, 'summary');
    if (summary !== undefined) {
      out.summary = summary;
    }
    const cover: string | undefined = optTextOf(row, 'cover');
    if (cover !== undefined && cover.length > 0) {
      out.cover = cover;
    }
    return out;
  }

  static scienceMetas(rows: RowShape[]): ScienceArticleMeta[] {
    const out: ScienceArticleMeta[] = [];
    let i: number = 0;
    while (i < rows.length) {
      out.push(RowMapper.scienceMeta(rows[i]));
      i = i + 1;
    }
    return out;
  }

  static scienceProgress(row: RowShape): ScienceProgress {
    const out: ScienceProgress = {
      articleId: textOf(row, 'article_id'),
      progress: numOf(row, 'progress'),
      isFavorite: numOf(row, 'is_favorite'),
    };
    const lastRead: number | undefined = optNumOf(row, 'last_read_at');
    if (lastRead !== undefined) {
      out.lastReadAt = lastRead;
    }
    return out;
  }

  static scienceProgressList(rows: RowShape[]): ScienceProgress[] {
    const out: ScienceProgress[] = [];
    let i: number = 0;
    while (i < rows.length) {
      out.push(RowMapper.scienceProgress(rows[i]));
      i = i + 1;
    }
    return out;
  }

  // ---------------------------------------------------------------- 碳普惠

  static includeRecord(row: RowShape): CarbonIncludeRecord {
    const out: CarbonIncludeRecord = {
      id: textOf(row, 'id'),
      userId: textOf(row, 'user_id'),
      action: textOf(row, 'action') === 'redeem' ? 'redeem' : 'exchange',
      pointsSpent: numOf(row, 'points_spent'),
      coinAmount: numOf(row, 'coin_amount'),
      occurredAt: numOf(row, 'occurred_at'),
      createdAt: numOf(row, 'created_at'),
      updatedAt: numOf(row, 'updated_at'),
      isDeleted: numOf(row, 'is_deleted'),
      syncState: RowMapper.syncState(textOf(row, 'sync_state')),
    };
    const benefitId: string | undefined = optTextOf(row, 'benefit_id');
    if (benefitId !== undefined && benefitId.length > 0) {
      out.benefitId = benefitId;
    }
    const benefitName: string | undefined = optTextOf(row, 'benefit_name');
    if (benefitName !== undefined && benefitName.length > 0) {
      out.benefitName = benefitName;
    }
    const device: string | undefined = optTextOf(row, 'device_id');
    if (device !== undefined) {
      out.deviceId = device;
    }
    return out;
  }

  static includeRecords(rows: RowShape[]): CarbonIncludeRecord[] {
    const out: CarbonIncludeRecord[] = [];
    let i: number = 0;
    while (i < rows.length) {
      out.push(RowMapper.includeRecord(rows[i]));
      i = i + 1;
    }
    return out;
  }

  /** 权益（来自 `app_config['benefits']` 的 JSON 数组行）。 */
  static benefitFromJson(o: RowShape): IncludeBenefit {
    return {
      id: textOf(o, 'id'),
      name: textOf(o, 'name'),
      description: textOf(o, 'description'),
      coinCost: numOf(o, 'coinCost'),
      icon: textOf(o, 'icon'),
    };
  }

  // ---------------------------------------------------------------- 协同日志

  static syncLog(row: RowShape): SyncLogRow {
    const out: SyncLogRow = {
      id: textOf(row, 'id'),
      userId: textOf(row, 'user_id'),
      peerDevice: textOf(row, 'peer_device'),
      direction: textOf(row, 'direction'),
      status: textOf(row, 'status'),
      pulledCount: numOf(row, 'pulled_count'),
      pushedCount: numOf(row, 'pushed_count'),
      conflictCount: numOf(row, 'conflict_count'),
      startedAt: numOf(row, 'started_at'),
      createdAt: numOf(row, 'created_at'),
    };
    const err: string | undefined = optTextOf(row, 'error_msg');
    if (err !== undefined) {
      out.errorMsg = err;
    }
    const finished: number | undefined = optNumOf(row, 'finished_at');
    if (finished !== undefined) {
      out.finishedAt = finished;
    }
    return out;
  }

  static syncLogs(rows: RowShape[]): SyncLogRow[] {
    const out: SyncLogRow[] = [];
    let i: number = 0;
    while (i < rows.length) {
      out.push(RowMapper.syncLog(rows[i]));
      i = i + 1;
    }
    return out;
  }

  // ---------------------------------------------------------------- 窄化

  static category(v: string): CategoryKey {
    if (v === 'travel' || v === 'utility' || v === 'recycle' || v === 'plate') {
      return v;
    }
    throw new Error(`carbon_record.category 非法值：${v}`);
  }

  static confidence(v: string): Confidence {
    if (v === 'verified' || v === 'provisional') {
      return v;
    }
    throw new Error(`confidence 非法值：${v}`);
  }

  static syncState(v: string): SyncState {
    if (v === 'local' || v === 'synced' || v === 'pending') {
      return v;
    }
    throw new Error(`sync_state 非法值：${v}`);
  }

  static pointType(v: string): PointType {
    if (v === 'record' || v === 'record_capped' || v === 'goal' || v === 'purchase' || v === 'carbon_include' || v === 'reverse') {
      return v;
    }
    throw new Error(`point_record.type 非法值：${v}`);
  }

  static flowKind(v: string): FlowKind {
    if (v === 'primary' || v === 'reverse') {
      return v;
    }
    throw new Error(`point_record.flow_kind 非法值：${v}`);
  }

  static sourceType(v: string): PointSourceType {
    if (v === 'carbon_record' || v === 'goal' || v === 'shop_item' || v === 'carbon_include') {
      return v;
    }
    throw new Error(`point_record.source_type 非法值：${v}`);
  }

  static tier(v: string): GoalTier {
    if (v === 'short' || v === 'mid' || v === 'long') {
      return v;
    }
    throw new Error(`goal_def.tier 非法值：${v}`);
  }

  static period(v: string): GoalPeriod {
    if (v === 'day' || v === 'week' || v === 'month' || v === 'quarter' || v === 'year' || v === 'hundred_days') {
      return v;
    }
    throw new Error(`goal_def.period 非法值：${v}`);
  }

  static goalMetric(v: string): GoalMetric {
    if (v === 'count' || v === 'sum_amount' || v === 'sum_reduction' || v === 'distinct_days') {
      return v;
    }
    throw new Error(`goal_def.metric 非法值：${v}`);
  }

  static badgeMetric(v: string): BadgeMetric {
    if (v === 'first_record' || v === 'streak' || v === 'total_reduction' || v === 'travel_count' || v === 'recycle_kg' || v === 'frame_count') {
      return v;
    }
    throw new Error(`badge_def.metric 非法值：${v}`);
  }

  static badgeTier(v: string): 'bronze' | 'silver' | 'gold' {
    if (v === 'bronze' || v === 'silver' || v === 'gold') {
      return v;
    }
    throw new Error(`badge_def.tier 非法值：${v}`);
  }

  static section(v: string): 'frame' | 'theme' {
    if (v === 'frame' || v === 'theme') {
      return v;
    }
    throw new Error(`shop_item.section 非法值：${v}`);
  }

  static scienceCategory(v: string): ScienceCategory {
    if (v === 'policy' || v === 'tips' || v === 'knowledge') {
      return v;
    }
    throw new Error(`science_article.category 非法值：${v}`);
  }

  /** JSON 数组字符串 → 字符串数组（非法输入返回空数组，不抛错：字典可缺）。 */
  static stringArray(text: string): string[] {
    if (text.length === 0) {
      return [];
    }
    const parsed: Object = JSON.parse(text);
    const arr: Object[] = Array.isArray(parsed) ? parsed : [];
    const out: string[] = [];
    let i: number = 0;
    while (i < arr.length) {
      const v: Object = arr[i];
      out.push(typeof v === 'string' ? v : `${v}`);
      i = i + 1;
    }
    return out;
  }
}

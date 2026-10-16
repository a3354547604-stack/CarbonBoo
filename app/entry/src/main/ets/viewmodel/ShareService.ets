/**
 * ShareService —— 分享卡片（附录 C §23.2 / 创新项 S7）。
 *
 * 职责：① 产出卡面数据（纯函数在 `ShareCardModel`）；② 按**真实像素**尺寸（1080×1440 / 1080×1080）
 * 在离屏画布上渲染 → 编码 PNG → 写入相册；③ 落一条 `share_record`（本机专属，不参与同步）。
 *
 * 边界：页面/半模态只传尺寸与数据、只读结果，不碰 Canvas 与相册 API；
 * 隐私由 `ShareCardModel` 的结构保证——卡面没有姓名/学校/队名/指导教师字段。
 */
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AppResult, fail, ok } from '../model/Result';
import { CardRenderer, CardSize, ShareCardData, ShareCardModel } from '../util/CardRenderer';
import { RowShape, StorePort, firstOf, numOf, textOf } from './store/StorePort';
import { AppState } from './AppState';
import { IdUtil } from './domain/IdUtil';

/** 分享历史行（share_record）。 */
export class ShareRow {
  id: string = '';
  cardSize: string = '';
  reductionKg: number = 0;
  badgeCount: number = 0;
  savedPath: string = '';
  sharedTo: string = '';
  createdAt: number = 0;
}

export class ShareService {
  private readonly context: common.Context;
  private readonly store: StorePort;
  private readonly state: AppState;

  constructor(context: common.Context, store: StorePort, state: AppState) {
    this.context = context;
    this.store = store;
    this.state = state;
  }

  /** 卡面数据（减排量 + 徽章数），数据取自本机账本。 */
  async cardData(userId: string, now: number): Promise<ShareCardData> {
    const rows = await this.store.query(
      'SELECT COALESCE(SUM(reduction_kg), 0) AS total, COUNT(*) AS cnt FROM carbon_record WHERE user_id = ? AND is_deleted = 0',
      [userId]
    );
    let badges: number = 0;
    const badgeRows = await this.store.query(
      'SELECT COUNT(*) AS cnt FROM user_badge WHERE user_id = ? AND unlocked = 1 AND is_deleted = 0', [userId]
    );
    if (badgeRows.length > 0) {
      badges = numOf(badgeRows[0], 'cnt');
    }
    const first: RowShape | undefined = firstOf(rows);
    const total: number = first === undefined ? 0 : numOf(first, 'total');
    return ShareCardModel.build(total, badges, 8);
  }

  /**
   * 按指定尺寸渲染并保存到相册。
   * @returns 成功时 `data` 是相册 uri；失败时给出可直接展示的原因。
   */
  async saveCard(userId: string, size: string, data: ShareCardData, now: number): Promise<AppResult<string>> {
    try {
      const w: number = CardSize.widthOf(size);
      const h: number = CardSize.heightOf(size);
      const off: OffscreenCanvas = new OffscreenCanvas(w, h);
      const settings: RenderingContextSettings = new RenderingContextSettings(true);
      const ctx: OffscreenCanvasRenderingContext2D = off.getContext('2d', settings);
      CardRenderer.draw(ctx, size, data);
      const pixels: PixelMap = ctx.getPixelMap(0, 0, w, h);
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(this.context);
      const uri: string = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'png');
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      const packer: image.ImagePacker = image.createImagePacker();
      const buf: ArrayBuffer = await packer.packing(pixels, { format: 'image/png', quality: 100 });
      fileIo.writeSync(file.fd, buf);
      fileIo.closeSync(file);
      await this.record(userId, size, data, uri, 'album', now);
      return ok(uri);
    } catch (err) {
      return fail<string>('SHARE_SAVE_FAILED', '保存到相册失败，请检查相册权限后重试');
    }
  }

  /** 走系统分享面板（不接第三方 SDK）：记录一次分享意图。 */
  async markShared(userId: string, size: string, data: ShareCardData, now: number): Promise<AppResult<boolean>> {
    await this.record(userId, size, data, '', 'system', now);
    return ok(true);
  }

  /** 最近分享记录（本机专属）。 */
  /**
   * 文本合规性检查（设置页「文本合规性检查」）：返回卡面命中的敏感词，空数组 = 通过。
   * 命中词表与判据都在 `ShareCardModel.violations` 里（唯一实现），页面只读结果。
   */
  async violations(userId: string, now: number): Promise<string[]> {
    const data: ShareCardData = await this.cardData(userId, now);
    return ShareCardModel.violations(data);
  }

  async history(userId: string, limit: number): Promise<ShareRow[]> {
    const rows = await this.store.query(
      'SELECT id, card_size, reduction_kg, badge_count, saved_path, shared_to, created_at ' +
      'FROM share_record WHERE user_id = ? ORDER BY created_at DESC LIMIT ?', [userId, limit]
    );
    const out: ShareRow[] = [];
    for (const r of rows) {
      const row: ShareRow = new ShareRow();
      row.id = textOf(r, 'id');
      row.cardSize = textOf(r, 'card_size');
      row.reductionKg = numOf(r, 'reduction_kg');
      row.badgeCount = numOf(r, 'badge_count');
      row.savedPath = textOf(r, 'saved_path');
      row.sharedTo = textOf(r, 'shared_to');
      row.createdAt = numOf(r, 'created_at');
      out.push(row);
    }
    return out;
  }

  private async record(userId: string, size: string, data: ShareCardData, path: string, to: string, now: number): Promise<void> {
    await this.store.exec(
      'INSERT INTO share_record (id, user_id, card_size, reduction_kg, badge_count, saved_path, shared_to, created_at) ' +
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [IdUtil.uuid(), userId, size, data.reductionKg, data.badgeCount, path, to, now]
    );
  }
}

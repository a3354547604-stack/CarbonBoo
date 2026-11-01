/**
 * AvatarWithFrame —— 头像 + 头像框（环 + 角标）。
 *
 * 职责：把「头像」与「头像框」画成**两层**，而不是两个并列的图标：
 *   · 内层：头像 emoji（avatar_leaf…avatar_earth，8 个，全部免费）；
 *   · 外层：**环**——由「渐变外圆 + 内圆遮罩」构成，用户戴的是这个环；
 *   · 角标：每个框自带一个小饰物（右下角），进一步和头像区分开。
 *
 * 为什么不用图片资源：`resources/base/media/` 里只有 `app_icon.png`，
 * AGENTS §7.1 又禁止引入第三方图标库；用渐变 + 内圆遮罩画环，不新增二进制资源。
 *
 * 未拥有（`locked`）时环降透明度、中心盖 🔒，且**不画角标**——避免"看起来已经拥有"。
 */
import { AppTheme } from '../util/AppTheme';

/** 一个头像框的样式：环的渐变两端 + 右下角饰物。 */
interface FrameStyle {
  from: string;
  to: string;
  ornament: string;
}

const FRAME_STYLES: Record<string, FrameStyle> = {
  'frame_01': { from: '#A5D6A7', to: '#2E7D32', ornament: '🌱' },  // 嫩芽
  'frame_02': { from: '#DCE775', to: '#558B2F', ornament: '🌿' },  // 藤蔓
  'frame_03': { from: '#FFCC80', to: '#E64A19', ornament: '🎡' },  // 风车
  'frame_04': { from: '#9FA8DA', to: '#1A237E', ornament: '✨' },  // 星河
  'frame_05': { from: '#80CBC4', to: '#7C4DFF', ornament: '🌠' },  // 极光
  'frame_06': { from: '#90A4AE', to: '#263238', ornament: '🎋' },  // 墨竹
  'frame_07': { from: '#FFE082', to: '#F57F17', ornament: '👑' },  // 鎏金
  'frame_08': { from: '#D7CCC8', to: '#6D4C41', ornament: '🍂' }   // 年轮
};

/** 8 个头像（与 shop-items.json 的 avatar_* 一一对应）。 */
const AVATAR_ICONS: Record<string, string> = {
  'avatar_leaf': '🌿',
  'avatar_drop': '💧',
  'avatar_bike': '🚲',
  'avatar_bulb': '💡',
  'avatar_recycle': '♻️',
  'avatar_plate': '🍽️',
  'avatar_sprout': '🌱',
  'avatar_earth': '🌍'
};

export function avatarEmojiOf(avatarId: string): string {
  const emoji: string | undefined = AVATAR_ICONS[avatarId];
  return emoji === undefined ? '🌿' : emoji;
}

export function isKnownFrame(frameId: string): boolean {
  return frameId.length > 0 && FRAME_STYLES[frameId] !== undefined;
}

@Component
export struct AvatarWithFrame {
  @Prop avatarId: string = 'avatar_leaf';
  /** 直接给 emoji 时优先用它（碳小铺里用固定示例头像预览框效果）。 */
  @Prop avatarEmoji: string = '';
  @Prop frameId: string = '';
  @Prop diameter: number = AppTheme.AVATAR_SIZE;
  @Prop locked: boolean = false;

  private ringWidth(): number {
    const w: number = this.diameter * 0.09;
    return w < 3 ? 3 : w;
  }

  private centerEmoji(): string {
    if (this.avatarEmoji.length > 0) {
      return this.avatarEmoji;
    }
    return avatarEmojiOf(this.avatarId);
  }

  private hasFrame(): boolean {
    return isKnownFrame(this.frameId);
  }

  private style(): FrameStyle {
    const s: FrameStyle | undefined = FRAME_STYLES[this.frameId];
    if (s === undefined) {
      return { from: AppTheme.COLOR_DISABLED_BG, to: AppTheme.COLOR_BG, ornament: '' };
    }
    return s;
  }

  private ornament(): string {
    if (this.locked || !this.hasFrame()) {
      return '';
    }
    return this.style().ornament;
  }

  private innerSize(): number {
    return this.diameter - this.ringWidth() * 2;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // ① 环本体（渐变外圆）
      Row()
        .width(this.diameter)
        .height(this.diameter)
        .borderRadius(this.diameter / 2)
        .linearGradient({
          angle: 135,
          colors: [[this.style().from, 0.0], [this.style().to, 1.0]]
        })
        .opacity(this.locked ? 0.30 : 1)

      // ② 内圆遮罩：与卡片底同色，把中心挖空，只剩一圈环
      Row()
        .width(this.innerSize())
        .height(this.innerSize())
        .borderRadius(this.innerSize() / 2)
        .backgroundColor(AppTheme.COLOR_BG)

      // ③ 头像本体
      Text(this.centerEmoji())
        .fontSize(this.diameter * 0.44)
        .textAlign(TextAlign.Center)
        .opacity(this.locked ? 0.40 : 1)

      // ④ 右下角角标（仅已解锁且装了框）
      if (this.ornament().length > 0) {
        Text(this.ornament())
          .fontSize(this.diameter * 0.20)
          .width(this.diameter * 0.30)
          .height(this.diameter * 0.30)
          .textAlign(TextAlign.Center)
          .backgroundColor(AppTheme.COLOR_BG)
          .borderRadius(this.diameter * 0.15)
          .offset({ x: this.diameter * 0.31, y: this.diameter * 0.31 })
      }

      // ⑤ 未解锁：中心叠锁
      if (this.locked) {
        Text('🔒')
          .fontSize(this.diameter * 0.36)
          .textAlign(TextAlign.Center)
      }
    }
    .width(this.diameter + this.diameter * 0.32)
    .height(this.diameter + this.diameter * 0.32)
  }
}

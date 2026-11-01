/**
 * AvatarWithFrame —— 头像 + 头像框（戴在头像上的「环」）。
 *
 * 设计目标（v4.18）：
 *   1. 框必须是**环**，不是第二个 emoji；
 *   2. 8 个框要**彼此一眼可辨**：靠「环的粗细 / 层数 / 光晕 / 饰物位置与数量」区分，
 *      而不是只换颜色（只换颜色在小尺寸下几乎看不出差别）；
 *   3. 未拥有时只显示一个淡环 + 🔒，不泄露配色细节。
 *
 * 为什么不用图片资源：`resources/base/media/` 只有 `app_icon.png`，
 * AGENTS §7.1 禁止引第三方图标库；用「渐变圆 + 同色内圆遮罩」画环即可，零二进制资源。
 */
import { AppTheme } from '../util/AppTheme';

/** 环上的一枚饰物：位置用角度表示（0°=右，90°=下，180°=左，270°=上）。 */
interface Ornament {
  emoji: string;
  sizeFactor: number;
  angleDeg: number;
}

interface FrameStyle {
  from: string;
  to: string;
  /** 环宽 = diameter × ringFactor */
  ringFactor: number;
  /** 第二道细环（内圈）宽 = diameter × innerFactor；0 表示不画 */
  innerFactor: number;
  /** 外发光强度（0~1），仅已解锁时显示 */
  halo: number;
  ornaments: Ornament[];
}

const FRAME_STYLES: Record<string, FrameStyle> = {
  // 嫩芽：单粗环 + 双叶点缀
  'frame_01': {
    from: '#A5D6A7', to: '#2E7D32', ringFactor: 0.11, innerFactor: 0, halo: 0.22,
    ornaments: [{ emoji: '🌱', sizeFactor: 0.26, angleDeg: 45 }, { emoji: '🍃', sizeFactor: 0.18, angleDeg: 210 }]
  },
  // 藤蔓：双环（外细内粗），藤蔓感
  'frame_02': {
    from: '#DCE775', to: '#33691E', ringFactor: 0.07, innerFactor: 0.03, halo: 0.16,
    ornaments: [{ emoji: '🌿', sizeFactor: 0.24, angleDeg: 135 }]
  },
  // 风车：中环 + 四方位小点（像扇叶）
  'frame_03': {
    from: '#FFCC80', to: '#E64A19', ringFactor: 0.09, innerFactor: 0, halo: 0.24,
    ornaments: [
      { emoji: '🎡', sizeFactor: 0.24, angleDeg: 45 },
      { emoji: '🟠', sizeFactor: 0.11, angleDeg: 135 },
      { emoji: '🟠', sizeFactor: 0.11, angleDeg: 225 },
      { emoji: '🟠', sizeFactor: 0.11, angleDeg: 315 }
    ]
  },
  // 星河：细环 + 星点分布在三个方位
  'frame_04': {
    from: '#9FA8DA', to: '#1A237E', ringFactor: 0.06, innerFactor: 0, halo: 0.30,
    ornaments: [
      { emoji: '✨', sizeFactor: 0.22, angleDeg: 45 },
      { emoji: '⭐', sizeFactor: 0.14, angleDeg: 200 },
      { emoji: '✨', sizeFactor: 0.12, angleDeg: 300 }
    ]
  },
  // 极光：最粗的环 + 强光晕，两枚星
  'frame_05': {
    from: '#80CBC4', to: '#7C4DFF', ringFactor: 0.13, innerFactor: 0, halo: 0.38,
    ornaments: [{ emoji: '🌠', sizeFactor: 0.26, angleDeg: 45 }, { emoji: '✨', sizeFactor: 0.13, angleDeg: 150 }]
  },
  // 墨竹：最细的环（水墨感）+ 竹叶
  'frame_06': {
    from: '#90A4AE', to: '#1C262B', ringFactor: 0.05, innerFactor: 0, halo: 0.12,
    ornaments: [{ emoji: '🎋', sizeFactor: 0.24, angleDeg: 45 }, { emoji: '🍃', sizeFactor: 0.13, angleDeg: 250 }]
  },
  // 鎏金：粗环 + 王冠在正上方
  'frame_07': {
    from: '#FFE082', to: '#F57F17', ringFactor: 0.12, innerFactor: 0, halo: 0.40,
    ornaments: [{ emoji: '👑', sizeFactor: 0.28, angleDeg: 270 }]
  },
  // 年轮：三道同心细环（年轮感）+ 落叶
  'frame_08': {
    from: '#D7CCC8', to: '#4E342E', ringFactor: 0.045, innerFactor: 0.045, halo: 0.14,
    ornaments: [{ emoji: '🍂', sizeFactor: 0.24, angleDeg: 45 }]
  }
};

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

const EMPTY_STYLE: FrameStyle = {
  from: AppTheme.COLOR_DISABLED_BG, to: AppTheme.COLOR_BG, ringFactor: 0.05,
  innerFactor: 0, halo: 0, ornaments: []
};

@Component
export struct AvatarWithFrame {
  @Prop avatarId: string = 'avatar_leaf';
  /** 直接给 emoji 时优先用它（碳小铺用固定示例头像预览框效果）。 */
  @Prop avatarEmoji: string = '';
  @Prop frameId: string = '';
  @Prop diameter: number = AppTheme.AVATAR_SIZE;
  @Prop locked: boolean = false;

  private style(): FrameStyle {
    const s: FrameStyle | undefined = FRAME_STYLES[this.frameId];
    return s === undefined ? EMPTY_STYLE : s;
  }

  private centerEmoji(): string {
    if (this.avatarEmoji.length > 0) {
      return this.avatarEmoji;
    }
    return avatarEmojiOf(this.avatarId);
  }

  private ringOuter(extraInset: number): number {
    return this.diameter - extraInset * 2;
  }

  private ringMask(size: number, width: number): number {
    const inner: number = size - width * 2;
    return inner > 4 ? inner : 4;
  }

  /** 饰物偏移：把极坐标换成 Stack 的 offset（Stack 居中对齐）。 */
  private ornamentOffset(angleDeg: number): number {
    const rad: number = angleDeg * Math.PI / 180;
    return Math.cos(rad) * this.diameter * 0.5;
  }

  private ornamentOffsetY(angleDeg: number): number {
    const rad: number = angleDeg * Math.PI / 180;
    return Math.sin(rad) * this.diameter * 0.5;
  }

  private frameWidth(): number {
    return (this.diameter + this.diameter * 0.34);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // ① 外发光（仅已解锁，营造「戴上去了」的存在感）
      if (!this.locked && this.style().halo > 0) {
        Row()
          .width(this.diameter * 1.14)
          .height(this.diameter * 1.14)
          .borderRadius(this.diameter * 0.57)
          .backgroundColor(this.style().from)
          .opacity(this.style().halo)
          .blur(this.diameter * 0.10)
      }

      // ② 主环：渐变外圆 + 同色遮罩挖空
      Row()
        .width(this.diameter)
        .height(this.diameter)
        .borderRadius(this.diameter / 2)
        .linearGradient({
          angle: 145,
          colors: [[this.style().from, 0.0], [this.style().to, 1.0]]
        })
        .opacity(this.locked ? 0.30 : 1)

      Row()
        .width(this.ringMask(this.diameter, this.diameter * this.style().ringFactor))
        .height(this.ringMask(this.diameter, this.diameter * this.style().ringFactor))
        .borderRadius(this.ringMask(this.diameter, this.diameter * this.style().ringFactor) / 2)
        .backgroundColor(AppTheme.COLOR_BG)

      // ③ 内圈细环（藤蔓 / 年轮 用）
      if (this.style().innerFactor > 0) {
        Row()
          .width(this.ringOuter(this.diameter * this.style().ringFactor))
          .height(this.ringOuter(this.diameter * this.style().ringFactor))
          .borderRadius(this.ringOuter(this.diameter * this.style().ringFactor) / 2)
          .linearGradient({
            angle: 35,
            colors: [[this.style().to, 0.0], [this.style().from, 1.0]]
          })
          .opacity(this.locked ? 0.25 : 0.85)

        Row()
          .width(this.ringMask(this.ringOuter(this.diameter * this.style().ringFactor),
            this.diameter * this.style().innerFactor))
          .height(this.ringMask(this.ringOuter(this.diameter * this.style().ringFactor),
            this.diameter * this.style().innerFactor))
          .borderRadius(this.ringMask(this.ringOuter(this.diameter * this.style().ringFactor),
            this.diameter * this.style().innerFactor) / 2)
          .backgroundColor(AppTheme.COLOR_BG)
      }

      // ④ 头像本体
      Text(this.centerEmoji())
        .fontSize(this.diameter * 0.42)
        .textAlign(TextAlign.Center)
        .opacity(this.locked ? 0.40 : 1)

      // ⑤ 饰物（按角度钉在环上；未解锁不画）
      if (!this.locked && this.style().ornaments.length > 0) {
        ForEach(this.style().ornaments, (o: Ornament) => {
          Text(o.emoji)
            .fontSize(this.diameter * o.sizeFactor)
            .textAlign(TextAlign.Center)
            .offset({ x: this.ornamentOffset(o.angleDeg), y: this.ornamentOffsetY(o.angleDeg) })
        }, (o: Ornament, idx: number) => `${idx}-${o.emoji}-${o.angleDeg}`)
      }

      // ⑥ 未解锁：中心叠锁
      if (this.locked) {
        Text('🔒')
          .fontSize(this.diameter * 0.34)
          .textAlign(TextAlign.Center)
      }
    }
    .width(this.frameWidth())
    .height(this.frameWidth())
  }
}

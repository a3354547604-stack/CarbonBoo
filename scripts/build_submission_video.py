# -*- coding: utf-8 -*-
"""
build_submission_video.py —— 生成参赛「演示视频」（mp4，1920x1080，≤5 分钟，≤100MB）。

做法：把界面实拍截图 + 每段讲解文字合成为关键帧，再用 ffmpeg 拼成带淡入淡出的片子。
时间轴严格按 docs/APPENDIX-E-demo-script.md §2 的 9 个分镜（合计 290 秒）。

运行：
  C:\\Users\\Admin\\.dsh\\dsh-runtimes\\dsh-primary-runtime\\dependencies\\python\\python.exe ^
      scripts\\build_submission_video.py
"""
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(REPO, 'docs', 'screenshots')
OUT_DIR = os.path.join(REPO, 'submit')
FRAME_DIR = os.path.join(OUT_DIR, '_frames')
OUT = os.path.join(OUT_DIR, '02-演示视频-碳小布CarbonBoo.mp4')
FFMPEG = r'C:\Users\Admin\AppData\Local\Programs\Python\Python314\Lib\site-packages\imageio_ffmpeg\binaries\ffmpeg-win-x86_64-v7.1.exe'

W, H = 1920, 1080
GREEN = (46, 125, 91)
LIGHT = (139, 195, 74)
DARK = (31, 42, 36)
GREY = (107, 122, 114)
BG = (245, 247, 246)
WHITE = (255, 255, 255)

FONT_BOLD = r'C:\Windows\Fonts\msyhbd.ttc'
FONT_REG = r'C:\Windows\Fonts\msyh.ttc'


def font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except Exception:
        return ImageFont.load_default()


F_TITLE = font(FONT_BOLD, 54)
F_SUB = font(FONT_REG, 30)
F_BODY = font(FONT_REG, 28)
F_SMALL = font(FONT_REG, 22)
F_BRAND = font(FONT_BOLD, 26)
F_STEP = font(FONT_BOLD, 24)

# (编号, 标题, 副标题, 要点行, 截图, 秒数)
SEGMENTS = [
    ('01', '开场：一句话说清这是什么',
     '记一笔低碳行为，得到减排量、积分与徽章',
     ['我们每天骑车、少开一天车、光盘、卖废纸，',
      '这些行为到底减了多少碳？——没人知道。',
      '碳小布只做一件事：把每一个低碳行为，',
      '变成看得见的数字。'],
     '01-home.png', 22),
    ('02', '记录一笔：两步完成',
     '选行为 → 填数量，实时预览减排量与积分',
     ['录入向导只有两步，不需要懂碳计算。',
      '选「出行 / 地铁」、填 8 km，',
      '实时算出减排 1.2960 kg、应得 130 分，',
      '并显示今日剩余额度。'],
     '14-record-edit.png', 40),
    ('03', '端侧 AI 识图：能识别就用识别',
     '识别只给候选，用户确认后才写入',
     ['选一张照片，本地给出候选行为。',
      '不展示置信度，不冒充精确；',
      '识别不可用时，退化为图标网格录入，',
      '同样两步完成，功能不缺失。'],
     '13-settings.png', 30),
    ('04', '看板：三种图表、四个粒度',
     '折线看趋势、饼图看结构、柱状做对比',
     ['日 / 周 / 月 / 年四种粒度一键切换，',
      '按出行、水电、回收、光盘分类筛选，',
      '点柱子直接下钻到当天记录。',
      '没有数据时也不是白屏，而是给下一步动作。'],
     '02-dashboard.png', 40),
    ('05', '激励：积分、目标、徽章、碳小铺',
     '不是「发个奖」，而是可审计的账本',
     ['积分有账本：余额 = 收入 − 支出，流水只增不删。',
      '11 条目标覆盖行为频次、数量与成果累计。',
      '8 枚徽章只看里程碑，不发积分，避免刷分。',
      '碳小铺只卖虚拟外观，无实物、无提现。'],
     '06-goal.png', 45),
    ('06', '科普与本地数据：离线也完整',
     '12 篇科普内置，备份与导出都在本机',
     ['12 篇科普分政策 / 技巧 / 知识三类，完全离线。',
      '已读判定是「滚动 ≥80% 且停留 ≥3 秒」。',
      '19 张表可整份快照备份、恢复、校验；',
      '导出 3 份 CSV，Excel 双击不乱码。'],
     '04-science.png', 30),
    ('07', '多设备协同与家庭合并（高光）',
     '云通路 + 近场通路，两条路都带降级',
     ['同一账号多端增量同步，冲突按 LWW 合并。',
      '另有一条鸿蒙近场通路：同网络配对，',
      '只交换统计快照，不传明细。',
      '家庭合并只读：合并统计口径，不动任何一方数据。',
      '设备不支持时只显示「未组网」，绝不崩溃。'],
     '11-sync.png', 50),
    ('08', '碳普惠模拟与成果分享',
     '完整闭环，但明确标注「模拟」',
     ['100 积分 = 1 碳币，单向不可逆。',
      '页面常驻声明：模拟演示，不对接真实平台。',
      '分享卡片两种尺寸，不含任何身份信息，',
      '不接第三方 SDK——发到哪里由用户决定。'],
     '10-include.png', 25),
    ('09', '收尾：记录低碳，攒出改变',
     '五项主要功能 + 四项创新，全部落地',
     ['19 张表、18 个页面、31 项因子、14 个 Service。',
      'L1 48 条、L3 243 条测试全部通过，',
      '18 组手算样例零误差。',
      '记录低碳，攒出改变。'],
     '18-about.png', 16),
]


def rounded(draw, box, radius, fill, outline=None, width=0):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def wrap(draw, text, fnt, max_w):
    lines, cur = [], ''
    for ch in text:
        if draw.textlength(cur + ch, font=fnt) <= max_w:
            cur += ch
        else:
            lines.append(cur)
            cur = ch
    if cur:
        lines.append(cur)
    return lines


def make_frame(idx, total_time, seg_index):
    num, title, sub, bullets, shot, dur = SEGMENTS[seg_index]
    start = sum(s[5] for s in SEGMENTS[:seg_index])
    img = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(img)

    # 顶部品牌条
    d.rectangle([0, 0, W, 8], fill=GREEN)
    d.text((80, 54), '碳小布 CarbonBoo', font=F_BRAND, fill=GREEN)
    d.text((80, 96), '赛题二 · 碳足迹·全民绿色生活碳积分与减排指南', font=F_SMALL, fill=GREY)

    # 左侧文字区
    d.text((80, 200), '分镜 %s' % num, font=F_STEP, fill=LIGHT)
    y = 250
    for line in wrap(d, title, F_TITLE, 1000):
        d.text((80, y), line, font=F_TITLE, fill=DARK)
        y += 70
    y += 6
    for line in wrap(d, sub, F_SUB, 980):
        d.text((80, y), line, font=F_SUB, fill=GREEN)
        y += 44
    y += 26
    for b in bullets:
        d.text((80, y), '·', font=F_BODY, fill=LIGHT)
        for i, line in enumerate(wrap(d, b, F_BODY, 940)):
            d.text((112, y), line, font=F_BODY, fill=DARK if i == 0 else DARK)
            y += 42
        y += 4

    # 右侧手机
    phone_x, phone_y, phone_w, phone_h = 1250, 120, 470, 840
    d.rounded_rectangle([phone_x + 6, phone_y + 10, phone_x + phone_w + 6, phone_y + phone_h + 10],
                        radius=48, fill=(225, 230, 227))
    d.rounded_rectangle([phone_x, phone_y, phone_x + phone_w, phone_y + phone_h],
                        radius=48, fill=(20, 24, 22))
    sp = os.path.join(SHOTS, shot)
    if os.path.exists(sp):
        ss = Image.open(sp).convert('RGB')
        inner_w, inner_h = phone_w - 28, phone_h - 28
        scale = min(inner_w / ss.width, inner_h / ss.height)
        nw, nh = int(ss.width * scale), int(ss.height * scale)
        ss = ss.resize((nw, nh), Image.LANCZOS)
        img.paste(ss, (phone_x + (phone_w - nw) // 2, phone_y + (phone_h - nh) // 2))

    # 底部进度条（按全局时间推进）
    bar_y = H - 96
    d.rectangle([80, bar_y, W - 80, bar_y + 6], fill=(216, 224, 219))
    prog = min(1.0, (start + dur * 0.5) / total_time)
    d.rectangle([80, bar_y, 80 + int((W - 160) * prog), bar_y + 6], fill=GREEN)
    t0 = int(start)
    d.text((80, bar_y + 22), '%d:%02d' % (t0 // 60, t0 % 60), font=F_SMALL, fill=GREY)
    tail = '记录低碳，攒出改变　·　碳小布 CarbonBoo'
    tw = d.textlength(tail, font=F_SMALL)
    d.text((W - 80 - tw, bar_y + 22), tail, font=F_SMALL, fill=GREY)
    d.text((W // 2 - 40, bar_y + 22),
           '%s / %d' % (num, len(SEGMENTS)), font=F_SMALL, fill=GREY)

    os.makedirs(FRAME_DIR, exist_ok=True)
    out = os.path.join(FRAME_DIR, 'f%02d.png' % idx)
    img.save(out)
    return out, dur


def build():
    """逐段编码成定长片段再拼接 —— 避免 concat demuxer 用 duration 列表时的时间戳漂移
    （实测漂了 +9 秒，5:07 险超 5 分钟上限）。"""
    os.makedirs(FRAME_DIR, exist_ok=True)
    for f in os.listdir(FRAME_DIR):
        os.remove(os.path.join(FRAME_DIR, f))

    total = sum(s[5] for s in SEGMENTS)
    clip_lines = []
    clips = 0
    for i, seg in enumerate(SEGMENTS):
        path, dur = make_frame(i + 1, total, i)
        clip = os.path.join(FRAME_DIR, 'c%02d.mp4' % (i + 1))
        vf = ('scale=1920:1080,format=yuv420p,'
              'fade=t=in:st=0:d=0.4,fade=t=out:st=%.2f:d=0.4' % (dur - 0.45))
        subprocess.run([
            FFMPEG, '-y', '-loop', '1', '-framerate', '30', '-i', path,
            '-t', str(dur), '-vf', vf, '-r', '30',
            '-c:v', 'libx264', '-preset', 'medium', '-crf', '22',
            '-pix_fmt', 'yuv420p', clip,
        ], check=True)
        clip_lines.append("file '%s'" % clip.replace('\\', '/'))
        clips += 1

    list_path = os.path.join(FRAME_DIR, 'list.txt')
    with open(list_path, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(clip_lines))

    subprocess.run([
        FFMPEG, '-y', '-f', 'concat', '-safe', '0', '-i', list_path,
        '-c', 'copy', '-movflags', '+faststart', OUT,
    ], check=True)
    print('SAVED', OUT, os.path.getsize(OUT), 'bytes; planned duration', total, 's; clips', clips)


if __name__ == '__main__':
    build()

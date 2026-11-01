# -*- coding: utf-8 -*-
"""
build_submission_pptx.py —— 生成参赛「演示文稿」（17 页，16:9）。

设计原则（2026-11-01 重排）：
  ① **一页一屏**：凡「讲某个界面」的页，只放那一屏的截图，图文必须对得上；
  ② **重要的才放**：概念页（痛点 / 全景 / 架构 / 数据 / 质量 / 结尾）不放图，
     图只给「答辩时会指着讲」的界面：首页、记一笔、记录列表、记录明细（因子快照）、
     看板、目标、徽章、碳小铺、更换外观、科普详情、碳普惠、设备协同；
  ③ 每页带演讲备注，整稿按 **7 分钟**讲解设计（17 页，平均每页 24 秒；时间预算写在备注开头）。

运行：
  C:\\Users\\Admin\\.dsh\\dsh-runtimes\\dsh-primary-runtime\\dependencies\\python\\python.exe ^
      scripts\\build_submission_pptx.py
"""
import os

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.util import Inches, Pt

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(REPO, 'docs', 'screenshots')
OUT_DIR = os.path.join(REPO, 'submit')
OUT = os.path.join(OUT_DIR, '03-演示文稿-碳小布CarbonBoo.pptx')

GREEN = RGBColor(0x2E, 0x7D, 0x5B)
DEEP = RGBColor(0x25, 0x64, 0x49)
LIGHT = RGBColor(0x8B, 0xC3, 0x4A)
DARK = RGBColor(0x1F, 0x2A, 0x24)
GREY = RGBColor(0x6B, 0x7A, 0x72)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
SOFT = RGBColor(0xEE, 0xF5, 0xF1)
FONT = '微软雅黑'

W, H = Inches(13.333), Inches(7.5)
TOTAL = 17


def slide_blank(prs):
    return prs.slides.add_slide(prs.slide_layouts[6])


def rect(slide, x, y, w, h, color, line=False):
    shp = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, x, y, w, h)
    shp.fill.solid()
    shp.fill.fore_color.rgb = color
    if not line:
        shp.line.fill.background()
    shp.shadow.inherit = False
    return shp


def textbox(slide, x, y, w, h, align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP):
    tb = slide.shapes.add_textbox(x, y, w, h)
    tf = tb.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    tf.paragraphs[0].alignment = align
    return tf


def set_font(run, size, bold=False, color=DARK, font=FONT):
    from pptx.oxml.ns import qn
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.color.rgb = color
    run.font.name = font
    rpr = run._r.get_or_add_rPr()
    ea = rpr.find(qn('a:ea'))
    if ea is None:
        from lxml import etree
        ea = etree.SubElement(rpr, qn('a:ea'))
    ea.set('typeface', font)


def add_para(tf, text, size=18, bold=False, color=DARK, space_before=6,
             align=PP_ALIGN.LEFT, first=False, bullet=False):
    if first and len(tf.paragraphs) == 1 and tf.paragraphs[0].text == '':
        p = tf.paragraphs[0]
    else:
        p = tf.add_paragraph()
    p.alignment = align
    p.space_before = Pt(space_before)
    run = p.add_run()
    run.text = ('· ' + text) if bullet else text
    set_font(run, size, bold, color)
    return p


def header(slide, title, kicker=None):
    rect(slide, 0, 0, W, Inches(0.14), GREEN)
    tf = textbox(slide, Inches(0.7), Inches(0.40), Inches(11.9), Inches(0.8))
    add_para(tf, title, 28, True, GREEN, first=True)
    if kicker:
        tf2 = textbox(slide, Inches(0.72), Inches(1.08), Inches(11.4), Inches(0.42))
        add_para(tf2, kicker, 14, False, GREY, first=True)


def footer(slide, page):
    tf = textbox(slide, Inches(11.4), Inches(6.95), Inches(1.5), Inches(0.35),
                 align=PP_ALIGN.RIGHT)
    add_para(tf, '%02d / %d' % (page, TOTAL), 11, False, GREY, first=True)
    tf2 = textbox(slide, Inches(0.7), Inches(6.95), Inches(6.0), Inches(0.35))
    add_para(tf2, '碳小布 CarbonBoo　·　赛题二', 11, False, GREY, first=True)


def picture(slide, name, x, y, h):
    path = os.path.join(SHOTS, name)
    if not os.path.exists(path):
        raise SystemExit('缺截图：%s' % path)
    return slide.shapes.add_picture(path, x, y, height=h)


def notes(slide, text):
    slide.notes_slide.notes_text_frame.text = text


def text_slide(prs, page, title, kicker, bullets, note='', tail=None):
    s = slide_blank(prs)
    rect(s, 0, 0, W, H, WHITE)
    header(s, title, kicker)
    tf = textbox(s, Inches(0.75), Inches(1.75), Inches(11.7), Inches(4.6))
    first = True
    for item in bullets:
        add_para(tf, item, 18, True, DARK, first=first, bullet=True,
                 space_before=12 if first else 10)
        first = False
    if tail:
        tf2 = textbox(s, Inches(0.75), Inches(6.05), Inches(11.7), Inches(0.8))
        add_para(tf2, tail, 15, False, GREEN, first=True)
    footer(s, page)
    if note:
        notes(s, note)
    return s


def ui_slide(prs, page, title, kicker, bullets, shot, shot_h=Inches(5.5),
             note='', tail=None):
    s = slide_blank(prs)
    rect(s, 0, 0, W, H, WHITE)
    header(s, title, kicker)
    tf = textbox(s, Inches(0.75), Inches(1.75), Inches(7.0), Inches(4.2))
    first = True
    for item in bullets:
        add_para(tf, item, 18, True, DARK, first=first, bullet=True,
                 space_before=12 if first else 9)
        first = False
    if tail:
        tf2 = textbox(s, Inches(0.75), Inches(6.05), Inches(7.0), Inches(0.8))
        add_para(tf2, tail, 14, False, GREEN, first=True)
    else:
        rect(s, Inches(0.78), Inches(6.15), Inches(2.2), Inches(0.05), LIGHT)
    picture(s, shot, Inches(8.35), Inches(1.5), shot_h)
    footer(s, page)
    if note:
        notes(s, note)
    return s


def build():
    prs = Presentation()
    prs.slide_width = W
    prs.slide_height = H

    # ---------------------------------------------------------- P1 封面
    s = slide_blank(prs)
    rect(s, 0, 0, W, H, GREEN)
    rect(s, 0, Inches(5.9), W, Inches(1.6), DEEP)
    tf = textbox(s, Inches(1.0), Inches(1.45), Inches(7.4), Inches(1.2))
    add_para(tf, '碳小布 CarbonBoo', 50, True, WHITE, first=True)
    tf = textbox(s, Inches(1.0), Inches(2.6), Inches(7.2), Inches(1.5))
    add_para(tf, '记一笔低碳行为，攒出看得见的改变', 22, False, WHITE, first=True, space_before=0)
    add_para(tf, '个人碳足迹记录与低碳行为激励应用', 17, False, RGBColor(0xC8, 0xE6, 0xD5), space_before=10)
    tf = textbox(s, Inches(1.0), Inches(4.2), Inches(7.2), Inches(1.2))
    add_para(tf, '赛题二　碳足迹·全民绿色生活碳积分与减排指南', 16, True, LIGHT, first=True)
    add_para(tf, '纯北向应用　·　OpenHarmony API 12　·　无需任何硬件', 13, False, WHITE, space_before=6)
    picture(s, '01-home.png', Inches(8.55), Inches(1.0), Inches(5.7))
    tf = textbox(s, Inches(1.0), Inches(6.3), Inches(7.2), Inches(0.6))
    add_para(tf, '右图为打开应用的第一屏：一个写着自己碳账的数字', 13, False,
             RGBColor(0xC8, 0xE6, 0xD5), first=True)
    notes(s, '开场（0:00–0:40）：先抛一个问题——我们每天骑车、少开一天车、光盘、卖废纸，'
             '这些行为到底减了多少碳？没人知道。碳小布要回答的就是这个问题。')

    # ---------------------------------------------------------- P2 痛点
    s = slide_blank(prs)
    rect(s, 0, 0, W, H, WHITE)
    header(s, '痛点：低碳行为最大的问题是「看不见」', '三个「没有」，把低碳生活卡在「知道但做不到」')
    stats = [
        ('看不见', '没有数字就没有反馈', '骑车 8 km、光盘一次、卖 2 kg 废纸，\n各减多少碳？用户答不出'),
        ('坚持不了', '没有即时回报', '今天做了明天忘；没有累计与里程碑，\n习惯养不成'),
        ('不会算', '口径既专业又混乱', '电网、出行、回收各说各话，\n普通人无从下手'),
    ]
    x = Inches(0.9)
    for big, label, desc in stats:
        rect(s, x, Inches(2.05), Inches(3.7), Inches(2.6), SOFT)
        tf = textbox(s, x + Inches(0.32), Inches(2.3), Inches(3.1), Inches(0.9))
        add_para(tf, big, 34, True, GREEN, first=True)
        tf = textbox(s, x + Inches(0.32), Inches(3.15), Inches(3.1), Inches(0.45))
        add_para(tf, label, 16, True, DARK, first=True)
        tf = textbox(s, x + Inches(0.32), Inches(3.62), Inches(3.1), Inches(0.9))
        for i, line in enumerate(desc.split('\n')):
            add_para(tf, line, 12, False, GREY, first=(i == 0), space_before=3)
        x += Inches(3.95)
    tf = textbox(s, Inches(0.9), Inches(5.15), Inches(11.5), Inches(1.1))
    add_para(tf, '所以要做的不是「再做一个科普 App」，而是把行为变成数字、把数字变成回报。',
             18, True, DEEP, first=True)
    footer(s, 2)
    notes(s, '这一页不放截图——这是「用户的困境」，不是「我们的界面」。讲完三条再翻页。')

    # ---------------------------------------------------------- P3 功能全景
    s = slide_blank(prs)
    rect(s, 0, 0, W, H, WHITE)
    header(s, '功能全景', '赛题二要求的 5 项主要功能 + 4 项创新，一项不缺')
    rows = [
        ('主要 1', '低碳行为核算', '30 项因子库（20 项可录入）· 单一计算入口 · 因子快照四列'),
        ('主要 2', '数据可视化看板', '折线 / 柱状 / 饼图 × 日周月年 · 分类筛选 · 点柱下钻到当天'),
        ('主要 3', '碳积分激励', '积分账本（日封顶 200）· 10 个周期目标 · 8 枚徽章 · 碳小铺'),
        ('主要 4', '双碳科普专栏', '12 篇离线科普 · 阅读进度 · 收藏 · 本地渲染'),
        ('主要 5', '本地数据管理', '快照备份 / 恢复 / 校验 · 3 份 CSV 导出 · 清空'),
        ('创新 Ⅰ', '多设备协同', '云端 LWW 增量同步 + 鸿蒙近场演示层 + 家庭合并只读'),
        ('创新 Ⅱ', '端侧 AI 识图', '接口层可换引擎 · 只给候选须确认 · 图片不落盘不上传'),
        ('创新 Ⅲ', '碳普惠模拟', '100 积分 = 1 碳币 · 单向不可逆 · 页面常驻「模拟演示」'),
        ('创新 Ⅳ', '智能服务与分享', '4 类任务推送 · 5 条建议规则 · 两种尺寸分享卡片'),
    ]
    y = Inches(1.65)
    for i, (tag, name, desc) in enumerate(rows):
        rect(s, Inches(0.75), y, Inches(11.85), Inches(0.5),
             SOFT if i % 2 == 0 else WHITE)
        tf = textbox(s, Inches(0.9), y + Inches(0.05), Inches(1.2), Inches(0.4))
        add_para(tf, tag, 13, True, LIGHT if tag.startswith('创新') else GREEN, first=True)
        tf = textbox(s, Inches(2.1), y + Inches(0.05), Inches(3.4), Inches(0.4))
        add_para(tf, name, 15, True, DARK, first=True)
        tf = textbox(s, Inches(5.6), y + Inches(0.07), Inches(6.9), Inches(0.4))
        add_para(tf, desc, 12, False, GREY, first=True)
        y += Inches(0.55)
    footer(s, 3)
    notes(s, '这一页是「总账」：不是只做 5 项主要功能，4 项创新也全部落地，'
             '且每项都能在没网、没账号时降级可用。后面每一张截图都对应这里的一行。')

    # ---------------------------------------------------------- P4 记一笔
    ui_slide(
        prs, 4, '记一笔：两步完成', '选行为 → 填数量，实时算出减排量与积分',
        [
            '识图录入：选照片自动推断行为（当前为模拟识别，界面标注清楚）',
            '或从 9 个图标直接选：步行 / 骑行 / 公交 / 地铁 / 拼车 / 节电 / 节水 / 回收 / 光盘',
            '填一个数量（km / kWh / L / kg / 次），单位跟着行为自动切换',
            '实时预览：减排量与本次应得积分当场算出，并显示今日剩余额度',
            '保存后首页、记录、看板三处同源刷新——本机库是唯一真相源',
        ],
        shot='14-record-edit.png',
        tail='右图实拍：上方识图入口、中间 9 个行为、下方数量与发生时间。',
        note='先记一笔，让评委看到「填一个数就出结果」。强调计算全在本机，不联网也能算。')

    # ---------------------------------------------------------- P5 记录列表
    ui_slide(
        prs, 5, '记录列表：按天分组，四类可筛', '每一行都是「行为 + 数量 + 减排量 + 得分」',
        [
            '按天分组（今天 / 昨天 / 具体日期），扫一眼就知道最近做了什么',
            '四类筛选：出行 / 水电 / 回收 / 光盘；支持搜索，含中文因子名（搜「水」能找到「自来水」）',
            '每条右侧是本次净得积分——受日封顶影响时显示的是实入值，不是应得值',
            '点任一条进明细，看「凭什么算出这个数」',
            '记录可改可删，改删走冲正流水，余额永远是流水的聚合',
        ],
        shot='03-records.png',
        tail='右图实拍：252 条演示数据按天分组，右侧为每条实入积分。',
        note='这一页负责「数据密度」：让评委看到这不是玩具，而是真能长期记的账本。')

    # ---------------------------------------------------------- P6 记录明细
    ui_slide(
        prs, 6, '记录明细：每条都能追溯到因子', '一个数字背后要有四行证据',
        [
            '上半屏：行为、数量、减排量，一眼看懂这条记录是什么',
            '积分区：实入 / 应得 / 今日已得（30 / 200），把封顶前后的差额说清楚',
            '因子快照四列：因子值 0.1920 kg/km、版本 CF-2026.2、来源 SRC-DERIVED、可信度 provisional',
            '发生时间与记录时间分开：补记历史时两者不同，但封顶仍按「发生日」算',
            '因子库升级不回写历史——旧记录永远用当时那个因子值',
        ],
        shot='15-record-detail.png',
        tail='右图实拍：这就是答辩时最有说服力的一屏——「凭什么信」的答案在这里。',
        note='这一页最重要。评委问「你的数可信吗」，直接把这一屏放出来：'
             '每条记录都钉住了当时用的因子值、版本、来源、可信度。')

    # ---------------------------------------------------------- P7 看板
    ui_slide(
        prs, 7, '看板：一张图看清趋势与结构', '折线看趋势、饼图看结构、柱状做对比',
        [
            '日 / 周 / 月 / 年四档切换，坐标轴与说明文字同步变化（日按小时 24 点、年按 12 个月）',
            '饼图：四分类占比；柱状：各分类减排量对比',
            '点柱子直接下钻到该分类的记录列表，标出时间区间与合计',
            '空数据不白屏，给「去记一笔」的下一步动作',
            '切换档位时必须真的重画（Canvas 只在首次布局画一次是个坑，已修）',
        ],
        shot='02-dashboard.png',
        tail='右图实拍：「日」档 24 小时折线 + 分类占比 + 分类柱状，三图同屏。',
        note='现场可以切一次档位，让评委看到图跟着变——这是我们专门修过的点。')

    # ---------------------------------------------------------- P8 目标
    ui_slide(
        prs, 8, '目标：把「坚持」拆成可结算的周期', '短期日/周、中长期、长期，三档分别结算',
        [
            '10 个周期目标：零碳出行、省电小标兵、光盘卫士、回收一袋、记录不间断等',
            '日目标按自然日、周目标按自然周（周一 00:00 起算），口径写在页面上',
            '每条显示：当前进度 / 阈值、剩余天数、奖励分值',
            '达标自动结算并入账，奖励不占「记录类日封顶 200」的额度',
            '结算幂等：同一周期只会发一次，重复触发不会重复入账',
        ],
        shot='06-goal.png',
        tail='右图实拍：短目标 5 条，「零碳出行 1/1 条」已达成、「回收一袋 5/3 条」超额完成。',
        note='目标体系是为了解决「坚持不了」：把长期习惯切成一个个能当天结算的小目标。')

    # ---------------------------------------------------------- P9 徽章
    ui_slide(
        prs, 9, '徽章：纯荣誉，不发积分', '为什么故意不给徽章发钱',
        [
            '8 枚徽章：初次碳迹、七日不辍、月度坚持、减排十千克、百千克、循环使者、绿色骑士、种树人',
            '已解锁 / 未解锁分两区，未解锁显示条件与真实进度（如 56/100 kg、10.1/20 kg）',
            '徽章**不发积分、不可消费**——避免「刷徽章换钱」导致数据失真',
            '统一由一个判定引擎算出，界面不各算各的（这里修过一个「两处数字不一致」的缺陷）',
            '「种树人」需要集齐 8 个头像框，把「买」与「荣誉」串成一条线',
        ],
        shot='07-badge.png',
        tail='右图实拍：5/8 已解锁，未解锁的显示真实进度条与阈值。',
        note='这一页讲激励设计的边界：能换钱的东西一定会被刷，所以徽章只给荣誉。')

    # ---------------------------------------------------------- P10 碳小铺
    ui_slide(
        prs, 10, '碳小铺：积分有出口，但出口只有「好看」', '8 个头像框 + 1 套主题，无实物、无提现',
        [
            '价格梯度 1500～15000 分：嫩芽 / 藤蔓 / 风车 / 星河 / 极光 / 墨竹 / 鎏金 / 年轮',
            '每个框是一圈「环 + 饰物」：颜色、环宽、饰物角度都不同，不靠文字也能区分',
            '买框走事务：写购买记录 + 写负额流水，重复点击不会重复扣分',
            '已购显示「使用中」，余额不足显示「还差 N 分」',
            '不提供实物、不提供提现——积分经济闭环但不产生外部价值',
        ],
        shot='08-shop.png',
        tail='右图实拍：嫩芽「使用中」，星河「还差 259 分」，底部「已拥有 1/8」。',
        note='讲「积分通胀」怎么防：出口只有装饰性权益，价格梯度把长期用户和短期用户区分开。')

    # ---------------------------------------------------------- P11 更换外观
    ui_slide(
        prs, 11, '更换外观：头像与头像框是两层', '框是「戴在外面的一圈」，不是第二个图标',
        [
            '上排 8 个头像 emoji（全部免费），下排 8 个头像框（碳小铺购买后可用）',
            '框的画法：渐变外圆 = 环、同色内圆挖空、环上按角度钉饰物（嫩芽 🌱45° + 🍃210°）',
            '未解锁只画淡环 + 🔒，已解锁画满色与光晕，一眼能区分',
            '「无」= 不戴框：不画环、不拦截、不提示购买（这里修过一个把它当商品的缺陷）',
            '改名、选头像、选框、选主题，最后点保存才落库',
        ],
        shot='12-appearance.png',
        tail='右图实拍：嫩芽已选中（绿色标签），未购买的 7 个显示淡环 + 锁。',
        note='这一页可以回应「UI 是不是套模板」：环是参数化画的，八个框参数各不相同。')

    # ---------------------------------------------------------- P12 科普
    ui_slide(
        prs, 12, '科普：12 篇离线内容', '不联网也能读，读完能被记录',
        [
            '12 篇按三类归档：政策 / 低碳技巧 / 知识，全部打包进应用内',
            '正文 Markdown 本地渲染，不请求任何远程资源',
            '阅读页显示「未读 / 已读」状态标签；滚动到底自动判定（≥80% 且停留 ≥3 秒）',
            '底部按钮可显式点击立即标记——刚打开就想标记也生效（修过的缺陷）',
            '收藏、上一篇 / 下一篇、按分类筛选',
        ],
        shot='17-science-detail.png',
        tail='右图实拍：已标记后标签变「已读 ✓」、按钮置灰。',
        note='「已读」这块修过一个缺陷：原来只认滚动门槛，用户刚打开点按钮会静默无反应。')

    # ---------------------------------------------------------- P13 碳普惠
    ui_slide(
        prs, 13, '碳普惠（模拟演示）', '做完整闭环，但把「模拟」写在页面上',
        [
            '汇率固定：100 积分 = 1 碳币，单向不可逆（碳币不能换回积分）',
            '5 条虚拟权益：模拟认养树苗、模拟绿电、模拟低碳证书、模拟公益、模拟勋章',
            '页面常驻声明：不对接任何真实碳普惠平台，权益不可提现、不可退',
            '兑换走事务 + 唯一约束，重复点击不会重复扣分',
            '为什么不接真实通道：真实碳普惠涉及实名、签约与资金合规，不能冒充',
        ],
        shot='10-include.png',
        tail='右图实拍：顶部黄色告警条就是那句「模拟演示，不对接真实平台」。',
        note='这一页体现「诚实」：功能做全，边界写清楚。被问「为什么不做真的」，答案就是合规成本。')

    # ---------------------------------------------------------- P14 协同
    ui_slide(
        prs, 14, '多设备协同', '云通路 + 近场通路，两条路都带降级',
        [
            '云通路（主）：同账号多端，增量拉取 + 幂等推送 + LWW 冲突合并',
            '近场通路（演示层）：鸿蒙分布式 KV，只交换统计快照，不动明细',
            '时钟校正：服务端 offset 必须取反后再比较，否则旧数据会覆盖新数据',
            '软删除会传播：一端删除，另一端不会「复活」那条记录',
            '家庭合并只读；设备不支持或配对失败时显示「未组网」，绝不崩溃',
        ],
        shot='11-sync.png',
        tail='右图实拍：未登录显示「登录后可同步」，近场卡片显示「未组网」——降级也是设计的一部分。',
        note='说清「为什么不是纯云」：赛题二是单机版，云端只是加分项，所以两条通路都可降级。')

    # ---------------------------------------------------------- P15 架构与数据
    text_slide(
        prs, 15, '技术架构与数据口径', '分层是为了「算错也错在一处」',
        [
            '五层：页面（18 页，只取数/渲染/转发）→ 组件（23 个）→ 服务（14 个）→ 数据（19 表 + 12 Dao）→ 基础设施',
            '四条铁律：本地优先 / 单一计算入口 / 因子快照 / 积分单向可追溯',
            '计算：减排量 = 活动量 × 因子值（4 位）；应得 C = round(减排量 × 100)',
            '封顶：实入 A = max(0, min(C, 200 − 今日已得 D))，D 由流水实时聚合，不读缓存',
            '幂等：记录 / 流水 / 目标 / 购买各有唯一键，重复点击在数据库层就被挡住',
        ],
        tail='数值的唯一真相源是 tests/cases/carbon-calc.json：文档与代码都对它。',
        note='重点讲「单一计算入口」：减排量只能由 CarbonService.calculate() 产出，'
             '页面禁止自己乘因子——这是防「同一笔数据两个页面算出两个数」的唯一办法。')

    # ---------------------------------------------------------- P16 质量与合规
    s = slide_blank(prs)
    rect(s, 0, 0, W, H, WHITE)
    header(s, '质量与合规', '只写跑过的命令与真实输出；逐条对齐官方要求')
    left = [
        ('L0 文档与数值一致性', '28 项检查 · 89 个文件 · 0 处不一致'),
        ('L1 客户端单测', '49 条全通过（离线执行器）'),
        ('数值一致性', '18 组手算 + 5 组封顶 + 6 条边界，323 断言零误差'),
        ('L3 服务端接口', '243 条用例全通过'),
        ('设备侧实测', 'hypium 49 条：11 条纯逻辑通过，38 条受 aa test 的 Context 限制'),
    ]
    y = Inches(1.7)
    for a, b in left:
        tf = textbox(s, Inches(0.8), y, Inches(3.6), Inches(0.5))
        add_para(tf, a, 14, True, GREEN, first=True)
        tf = textbox(s, Inches(4.45), y, Inches(3.1), Inches(0.5))
        add_para(tf, b, 12, False, DARK, first=True)
        y += Inches(0.6)
    compat = [
        ('开发环境', 'DevEco + OpenHarmony · API 12', 'compileSdk 12，构建通过'),
        ('应用类型', '纯北向 · 无需硬件', '不依赖外设，单机完成 5 项功能'),
        ('数据存储', '本地离线可用', '本机库为唯一真相源'),
        ('原创要求', '独立完成', '零第三方 npm / HAR'),
        ('匿名要求', '不出现院校 / 团队 / 教师', '三份材料均已匿名'),
    ]
    y = Inches(1.7)
    for a, b, c in compat:
        rect(s, Inches(7.75), y - Inches(0.05), Inches(4.85), Inches(0.55), SOFT)
        tf = textbox(s, Inches(7.88), y, Inches(1.4), Inches(0.45))
        add_para(tf, a, 12, True, GREEN, first=True)
        tf = textbox(s, Inches(9.3), y, Inches(3.2), Inches(0.45))
        add_para(tf, b + '　→　' + c, 10, False, DARK, first=True)
        y += Inches(0.6)
    tf = textbox(s, Inches(0.8), Inches(5.2), Inches(11.8), Inches(1.4))
    add_para(tf, '已修真实缺陷 7 个：压栈崩溃 / 徽章数不一致 / 头像框误画成图标 / 已读按钮无响应 / '
                 '今日已得负数 / 兑换回读失败 / 「无」误判为待购买',
             13, True, DEEP, first=True)
    add_para(tf, '未完成项也写在材料里：真机 API 12 未跑、近场「发现对端」未跑通（受无华为账号限制）',
             12, False, GREY, space_before=8)
    footer(s, 16)
    notes(s, '这一页的关键是「不吹」：哪些跑过、哪些没跑过，写清楚。'
             '主动交代未完成项，比被评委问出来强。')

    # ---------------------------------------------------------- P17 结尾
    s = slide_blank(prs)
    rect(s, 0, 0, W, H, GREEN)
    tf = textbox(s, Inches(1.0), Inches(2.35), Inches(11.3), Inches(1.6),
                 align=PP_ALIGN.CENTER)
    add_para(tf, '记录低碳，攒出改变', 50, True, WHITE, first=True, align=PP_ALIGN.CENTER)
    tf = textbox(s, Inches(1.0), Inches(3.95), Inches(11.3), Inches(1.0),
                 align=PP_ALIGN.CENTER)
    add_para(tf, '碳小布 CarbonBoo　·　赛题二', 22, False, LIGHT, first=True, align=PP_ALIGN.CENTER)
    tf = textbox(s, Inches(1.0), Inches(4.75), Inches(11.3), Inches(1.0),
                 align=PP_ALIGN.CENTER)
    add_para(tf, '谢谢，欢迎提问', 18, False, RGBColor(0xC8, 0xE6, 0xD5), first=True, align=PP_ALIGN.CENTER)
    notes(s, '结尾（9:30–10:00）：一句 slogan 收住，然后停下等提问，不要再补充介绍。')

    # ── 7 分钟版演讲备注（覆盖上面按 10 分钟写的初稿）──────────────────────────
    # 比赛要求「汇报时长控制在 7 分钟以内」：17 页 → 共 420 秒，时间预算写在每条开头。
    # 原则：一页只讲一件事；数字优先于形容；不念页面上的字，讲页面背后的话。
    NOTES_7MIN = {
        1: '0:00–0:15（15s）开场一句话：碳小布是一个把低碳行为变成数字、再把数字变成回报的碳账本。',
        2: '0:15–0:45（30s）三个「没有」：看不见、坚持不了、不会算。一句话收口：所以不是再做一个科普 App。',
        3: '0:45–1:15（30s）五加四，九项官方要求全落地；每一行都能在没网、没账号时降级可用。',
        4: '1:15–1:45（30s）现场记一笔：选行为、填数量，减排量和积分当场出来，点击保存。',
        5: '1:45–2:10（25s）252 条按天分组，四类可筛，搜索认中文名（搜「水」能搜到「自来水」）。',
        6: '2:10–2:40（30s）最关键的一屏：每条记录钉住当时用的因子值、版本、来源、可信度。',
        7: '2:40–3:05（25s）切一次档位让评委看到图跟着变；点柱子能下钻到当天记录。',
        8: '3:05–3:30（25s）目标解决「坚持不了」：长期习惯切成当天能结算的小目标。',
        9: '3:30–3:50（20s）徽章只给荣誉、不发积分——这是激励设计的边界。',
        10: '3:50–4:15（25s）积分唯一的出口是「好看」：八个框价格梯度，长期用户和短期用户自然分层。',
        11: '4:15–4:35（20s）框是「戴在头像外面的一圈」，不是第二个图标；八个框参数各不相同。',
        12: '4:35–4:55（20s）12 篇离线内容，本地渲染；「已读」是显式点击，不靠滚动门槛。',
        13: '4:55–5:15（20s）碳普惠是模拟：100 积分 = 1 碳币，单向不可逆，界面常驻声明。',
        14: '5:15–5:45（30s）两条协同通路都带降级：云通路为主，近场只交换统计快照；时钟偏移必须取反。',
        15: '5:45–6:20（35s）四条铁律 + 计算与封顶公式：减排量只有一个出口，积分只增不删、可冲正。',
        16: '6:20–6:50（30s）门禁数字 + 已修 7 个真实缺陷；未完成项也写在材料里，不吹。',
        17: '6:50–7:00（10s）一句 slogan 收住，停下等提问，不要再补充介绍。',
    }
    for _i, _s in enumerate(prs.slides, 1):
        if _i in NOTES_7MIN:
            notes(_s, NOTES_7MIN[_i])
    print('notes: 7 分钟版已覆盖', len(NOTES_7MIN), '页')

    os.makedirs(OUT_DIR, exist_ok=True)
    prs.save(OUT)
    print('SAVED', OUT, os.path.getsize(OUT), 'bytes', len(prs.slides._sldIdLst), 'slides')


if __name__ == '__main__':
    build()

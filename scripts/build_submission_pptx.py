# -*- coding: utf-8 -*-
"""
build_submission_pptx.py —— 生成参赛「演示文稿」（16 页，16:9，图文并茂）。

页面结构按 docs/APPENDIX-E-demo-script.md §4 的 PPT 大纲逐页实现，
每页带演讲备注（对应 §3 的 10 分钟路演逐字稿要点），整稿讲解时长按 10 分钟设计。

运行：
  C:\\Users\\Admin\\.dsh\\dsh-runtimes\\dsh-primary-runtime\\dependencies\\python\\python.exe ^
      scripts\\build_submission_pptx.py
"""
import os

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.util import Emu, Inches, Pt

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(REPO, 'docs', 'screenshots')
OUT_DIR = os.path.join(REPO, 'submit')
OUT = os.path.join(OUT_DIR, '03-演示文稿-碳小布CarbonBoo.pptx')

GREEN = RGBColor(0x2E, 0x7D, 0x5B)
LIGHT = RGBColor(0x8B, 0xC3, 0x4A)
DARK = RGBColor(0x1F, 0x2A, 0x24)
GREY = RGBColor(0x6B, 0x7A, 0x72)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
BG = RGBColor(0xF5, 0xF7, 0xF6)
FONT = '微软雅黑'

W, H = Inches(13.333), Inches(7.5)


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
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.color.rgb = color
    run.font.name = font
    r = run._r
    rpr = r.get_or_add_rPr()
    from pptx.oxml.ns import qn
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
    tf = textbox(slide, Inches(0.7), Inches(0.42), Inches(9.4), Inches(0.8))
    add_para(tf, title, 30, True, GREEN, first=True)
    if kicker:
        tf2 = textbox(slide, Inches(0.72), Inches(1.12), Inches(9.0), Inches(0.42))
        add_para(tf2, kicker, 14, False, GREY, first=True)


def footer(slide, page):
    tf = textbox(slide, Inches(11.4), Inches(6.95), Inches(1.4), Inches(0.35),
                 align=PP_ALIGN.RIGHT)
    add_para(tf, '%02d / 16' % page, 11, False, GREY, first=True)
    tf2 = textbox(slide, Inches(0.7), Inches(6.95), Inches(6.0), Inches(0.35))
    add_para(tf2, '碳小布 CarbonBoo　·　赛题二', 11, False, GREY, first=True)


def picture(slide, name, x, y, h):
    path = os.path.join(SHOTS, name)
    if not os.path.exists(path):
        return None
    return slide.shapes.add_picture(path, x, y, height=h)


def notes(slide, text):
    slide.notes_slide.notes_text_frame.text = text


def content_slide(prs, page, title, kicker, bullets, shot=None,
                  shot_h=Inches(5.6), note='', two_col=None):
    s = slide_blank(prs)
    rect(s, 0, 0, W, H, WHITE)
    header(s, title, kicker)
    text_w = Inches(7.4) if shot else Inches(11.6)
    tf = textbox(s, Inches(0.75), Inches(1.75), text_w, Inches(4.9))
    first = True
    for item in bullets:
        if isinstance(item, tuple):
            txt, lvl = item
        else:
            txt, lvl = item, 0
        add_para(tf, txt, 19 if lvl == 0 else 16,
                 lvl == 0, DARK if lvl == 0 else GREY,
                 first=first, bullet=True, space_before=10 if lvl == 0 else 4)
        first = False
    if two_col:
        tf2 = textbox(s, Inches(0.75), Inches(5.35), Inches(7.2), Inches(1.3))
        add_para(tf2, two_col, 15, False, GREEN, first=True)
    if shot:
        picture(s, shot, Inches(8.55), Inches(1.6), shot_h)
    footer(s, page)
    if note:
        notes(s, note)
    return s


def build():
    prs = Presentation()
    prs.slide_width = W
    prs.slide_height = H

    # ---------------------------------------------------------------- P1 封面
    s = slide_blank(prs)
    rect(s, 0, 0, W, H, GREEN)
    rect(s, 0, Inches(5.9), W, Inches(1.6), RGBColor(0x25, 0x64, 0x49))
    tf = textbox(s, Inches(1.0), Inches(1.5), Inches(7.6), Inches(1.4))
    add_para(tf, '碳小布 CarbonBoo', 54, True, WHITE, first=True)
    tf = textbox(s, Inches(1.0), Inches(2.75), Inches(7.4), Inches(1.6))
    add_para(tf, '记一笔低碳行为，攒出看得见的改变', 24, False, WHITE, first=True, space_before=0)
    add_para(tf, '个人碳足迹记录与低碳行为激励应用', 18, False, RGBColor(0xC8, 0xE6, 0xD5), space_before=10)
    tf = textbox(s, Inches(1.0), Inches(4.35), Inches(7.2), Inches(1.0))
    add_para(tf, '赛题二　碳足迹·全民绿色生活碳积分与减排指南', 17, True, LIGHT, first=True)
    add_para(tf, '纯北向应用　·　OpenHarmony API 12　·　无需任何硬件', 14, False, WHITE, space_before=6)
    picture(s, '01-home.png', Inches(8.7), Inches(1.15), Inches(5.3))
    tf = textbox(s, Inches(1.0), Inches(6.25), Inches(11.0), Inches(0.6))
    add_para(tf, '设计方案 · 演示文稿 · 演示视频', 14, False, RGBColor(0xC8, 0xE6, 0xD5), first=True)
    notes(s, '开场（0:00–0:40）：先抛一个问题——我们每天骑车、少开一天车、光盘、卖废纸，'
             '这些行为到底减了多少碳？没人知道。碳小布要回答的就是这个问题。')

    # ---------------------------------------------------------------- P2 痛点
    s = content_slide(
        prs, 2, '痛点与机会', '低碳行为最大的问题是「看不见」',
        [
            ('看不见：骑车、光盘、卖废纸，减了多少碳？没有数字就没有反馈', 0),
            ('坚持不了：没有即时回报，很难长期坚持', 0),
            ('不知怎么做：知道要低碳，但不知道做什么、做多少才有意义', 0),
            ('政策背景：2030 碳达峰、2060 碳中和，全民参与需要「可量化的抓手」', 0),
            ('机会：把行为变成数字 → 把数字变成回报 → 把回报变成习惯', 0),
        ],
        shot='02-dashboard.png',
        note='用一句话概括：这个应用解决的不是「知不知道要低碳」，而是「不知道自己做得怎么样」。')

    # ---------------------------------------------------------------- P3 功能全景
    s = slide_blank(prs)
    rect(s, 0, 0, W, H, WHITE)
    header(s, '功能全景', '九项官方要求，一项不缺')
    rows = [
        ('主要 1', '低碳行为核算', '30 项因子库（20 项可录入）· 单一计算入口 · 因子快照'),
        ('主要 2', '数据可视化看板', '折线 / 柱状 / 饼图 × 日周月年 · 分类筛选'),
        ('主要 3', '碳积分激励', '积分账本（日封顶 200）· 11 目标 · 8 徽章 · 碳小铺'),
        ('主要 4', '双碳科普专栏', '12 篇离线科普 · 阅读进度 · 收藏'),
        ('主要 5', '本地数据管理', '快照备份 / 恢复 / 校验 · 3 份 CSV 导出'),
        ('创新 Ⅰ', '多设备同步 + 家庭合并', '云端 LWW 增量同步 + 鸿蒙近场演示层'),
        ('创新 Ⅱ', '端侧 AI 识图', '接口层可换引擎 · 只给候选 · 图片不落盘'),
        ('创新 Ⅲ', '碳普惠模拟', '100 积分 = 1 碳币 · 单向不可逆 · 常驻模拟声明'),
        ('创新 Ⅳ', '智能服务与分享', '任务推送 · 5 条建议规则 · 两种尺寸分享卡片'),
    ]
    y = Inches(1.7)
    for i, (tag, name, desc) in enumerate(rows):
        rect(s, Inches(0.75), y, Inches(11.85), Inches(0.5),
             RGBColor(0xEE, 0xF5, 0xF1) if i % 2 == 0 else WHITE)
        tf = textbox(s, Inches(0.9), y + Inches(0.05), Inches(1.2), Inches(0.4))
        add_para(tf, tag, 13, True, LIGHT if tag.startswith('创新') else GREEN, first=True)
        tf = textbox(s, Inches(2.1), y + Inches(0.05), Inches(3.4), Inches(0.4))
        add_para(tf, name, 15, True, DARK, first=True)
        tf = textbox(s, Inches(5.6), y + Inches(0.07), Inches(6.9), Inches(0.4))
        add_para(tf, desc, 12, False, GREY, first=True)
        y += Inches(0.55)
    footer(s, 3)
    notes(s, '这一页要讲清楚：不是只做了 5 项主要功能，4 项创新也全部落地，且每一项都能在没有'
             '网络、没有账号的情况下降级可用。')

    # ---------------------------------------------------------------- P4 现场演示
    s = content_slide(
        prs, 4, '现场演示路径', '从记一笔到得到反馈，全程 40 秒',
        [
            ('① 首页 → ＋ 记一笔 → 选「出行 / 地铁」→ 填 8 km', 0),
            ('② 实时预览：减排 1.2960 kg、本次应得 130 分、今日剩余额度', 0),
            ('③ 保存 → 首页累计减排、积分、今日记录三处同步刷新', 0),
            ('④ 目标与徽章自动结算（达标即弹庆祝）', 0),
            ('⑤ 看板看趋势 → 科普读一篇 → 我的导出 CSV', 0),
            ('⑥ 双设备登录同账号 → 协同页增量同步 → 家庭合并视图', 0),
        ],
        shot='14-record-edit.png',
        note='演示顺序与 5 分钟分镜一致：记录 → 反馈 → 看板 → 激励 → 留存 → 协同。'
             '现场若网络不通，直接走单机流程，除「协同 / 登录 / 取价」外全部功能可用。')

    # ---------------------------------------------------------------- P5 架构
    s = content_slide(
        prs, 5, '技术架构', '五层结构 + 四条铁律',
        [
            ('页面层：18 个页面，只做「取数 / 渲染 / 转发」，不写计算、不碰数据库', 0),
            ('组件层：23 个可复用组件（PageHeader / ChartCanvas / ScienceReader…）', 0),
            ('服务层：14 个 Service，业务编排与事务边界都在这层', 0),
            ('数据层：19 张表 + 12 个 Dao + 种子与因子仓库', 0),
            ('基础设施：定点小数（1e6）、防御式 JSON 解析、格式化、常量', 0),
            ('铁律 ①本地优先 ②单一计算入口 ③因子快照 ④积分单向可追溯', 0),
        ],
        shot='03-records.png',
        note='四条铁律是答辩重点：任何一行代码与它们冲突都要改代码。'
             '特别是「单一计算入口」——减排量只能由 CarbonService.calculate() 产出。')

    # ---------------------------------------------------------------- P6 数据设计
    s = content_slide(
        prs, 6, '数据设计', '19 张表，按「是否参与同步」组织',
        [
            ('业务账本 6 张：记录 / 积分流水 / 目标 / 徽章 / 购买 / 外观（参与同步）', 0),
            ('业务附属 3 张：阅读进度 / 碳币账户 / 用户档案（参与同步）', 0),
            ('本机专属 4 张：设备 / 同步日志 / 本地配置 / 分享记录（不参与）', 0),
            ('静态字典 5 张：目标 / 徽章 / 商品 / 科普 / 因子元数据（首次启动播种）', 0),
            ('派生缓存 1 张：日汇总（仅展示加速，可随时由流水重建）', 0),
            ('关键约束：软删除、幂等唯一键、因子快照四列、封顶从流水实时聚合', 0),
        ],
        shot='09-point-log.png',
        note='重点讲两个建模决定：一是幂等唯一键让「重复点击不重复发分」成为数据库层面的保证；'
             '二是日封顶不读缓存，避免缓存不同步导致多发或漏发。')

    # ---------------------------------------------------------------- P7 同步
    s = content_slide(
        prs, 7, '多设备协同', '云通路 + 近场通路，两条路都带降级',
        [
            ('云通路（主）：同账号多端，增量拉取 + 幂等推送 + LWW 冲突合并', 0),
            ('近场通路（演示层）：鸿蒙分布式 KV，同网络配对、只交换统计快照', 0),
            ('时钟校正：服务端 offset 必须取反后再比较，否则旧数据会覆盖新数据', 0),
            ('软删除传播：一端删除，另一端不会复活那条记录', 0),
            ('家庭合并只读：合并人数 / 记录数 / 减排 / 积分，不动任何一方明细', 0),
            ('可整体关闭：设备不支持或配对失败 → 界面显示「未组网」，绝不崩溃', 0),
        ],
        shot='11-sync.png',
        note='这一页是创新项的核心。要说清楚「为什么不是纯云」：赛题要求单机版，'
             '云端是加分项；所以两条通路都设计成可降级，网络或设备不可用时单机功能 100% 可用。')

    # ---------------------------------------------------------------- P8 协同实拍
    s = content_slide(
        prs, 8, '协同页实拍与状态机', '账号态、进度、冲突、家庭合并一屏可见',
        [
            ('未登录：显示「登录后可同步」提示，所有入口仍可点开查看说明', 0),
            ('已登录：显示账号、待同步条数、最后同步时间', 0),
            ('同步中：三段进度 ①发现设备 ②合并数据 ③写回本机', 0),
            ('冲突：只显示计数（丢弃 N 条 / 覆盖 M 条），不在界面里操作数据', 0),
            ('状态机：idle → discovering → merging → writingBack → done / failed', 0),
        ],
        shot='05-mine.png',
        note='如果现场没有第二台设备，就展示这一屏的降级状态机——说明「失败也是设计的一部分」。')

    # ---------------------------------------------------------------- P9 因子
    s = content_slide(
        prs, 9, '碳因子来源与可信度', '30 项因子（20 项可录入），逐项标来源，估算值不冒充权威值',
        [
            ('电力 0.5703 kgCO₂e/kWh：生态环境部《2024 年全国电力碳足迹因子》', 0),
            ('出行因子：GB/T 51366 转引 + 项目推算（provisional）', 0),
            ('旧物回收 8 项：团体标准附录（verified）', 0),
            ('光盘行动 3 项：按餐次估算（provisional，界面显示「参考值」角标）', 0),
            ('因子快照：每条记录存 factor_value / version / source / confidence', 0),
            ('升级规则：只有数值变化才升版本号；升级永不回写历史记录', 0),
        ],
        shot='04-science.png',
        note='答辩时要主动说明：哪些是权威值、哪些是估算值。评委最容易问「你的因子哪来的」，'
             '这一页就是答案。')

    # ---------------------------------------------------------------- P10 识图
    s = content_slide(
        prs, 10, '端侧 AI 识图', '把「识别」做成可替换、可降级的输入手段',
        [
            ('接口层：AiEngine 抽象，当前 engine=mock（本地启发式），换真模型只换实现', 0),
            ('只给候选、不替用户决定：识别结果必须经确认才写入记录', 0),
            ('不展示置信度数字或准确率，界面统一写「模拟识别」', 0),
            ('图片不落盘、不上传：只在内存里读一次像素', 0),
            ('3 秒超时 → 降级为「图标网格快速录入」，两步完成录入', 0),
        ],
        shot='13-settings.png',
        note='我们不把 AI 当卖点吹准确率，而是把它做成一个输入手段：能识别就用识别，不能就点图标。'
             '这样评审问「准确率多少」时，答案是「不承诺准确率，只承诺一定能录进去」。')

    # ---------------------------------------------------------------- P11 碳普惠
    s = content_slide(
        prs, 11, '碳普惠模拟', '完整闭环 + 明确边界',
        [
            ('规则：100 积分 = 1 碳币，单向不可逆（碳币不能换回积分）', 0),
            ('权益：5 条虚拟权益（模拟），无实物、不可提现、不可转让', 0),
            ('页面常驻声明：「模拟演示，不对接任何真实碳普惠平台」', 0),
            ('为什么这么做：真实碳普惠涉及实名、签约与资金合规，不冒充真实通道', 0),
            ('技术：兑换走事务 + 唯一约束，重复点击不会重复扣分', 0),
        ],
        shot='10-include.png',
        note='这一页体现的是「诚实」：做一个完整可用的兑换闭环，但把「模拟」两个字写在页面上。')

    # ---------------------------------------------------------------- P12 合规
    s = slide_blank(prs)
    rect(s, 0, 0, W, H, WHITE)
    header(s, '合规对照', '逐条对齐赛题要求')
    items = [
        ('开发环境', 'OpenHarmony + DevEco Studio，API 12 及以上', 'compileSdkVersion 12，构建通过'),
        ('应用类型', '纯北向应用，无需硬件', '不依赖任何外设，单机完成五项功能'),
        ('数据存储', '本地离线可用；云端与多设备同步为加分项', '本机库为唯一真相源，云端为增强'),
        ('功能定位', '基础功能为核心，创新为加分', '5 项主要 + 4 项创新全部实现'),
        ('原创要求', '独立完成，严禁抄袭', '零第三方 npm / HAR 包，图表与渲染自研'),
        ('费用', '不收取任何费用', '无内购、无广告、无付费入口'),
        ('匿名', '材料不出现院校 / 团队 / 指导教师', '三份材料均匿名'),
    ]
    y = Inches(1.75)
    tf = textbox(s, Inches(0.8), y - Inches(0.42), Inches(11.8), Inches(0.4))
    add_para(tf, '官方要求　　　　　　　　　　　　　　　　　　本作品', 13, True, GREEN, first=True)
    for a, b, c in items:
        rect(s, Inches(0.75), y, Inches(11.85), Inches(0.62), RGBColor(0xF7, 0xFA, 0xF8))
        tf = textbox(s, Inches(0.9), y + Inches(0.05), Inches(1.7), Inches(0.5))
        add_para(tf, a, 13, True, GREEN, first=True)
        tf = textbox(s, Inches(2.7), y + Inches(0.05), Inches(4.4), Inches(0.5))
        add_para(tf, b, 12, False, DARK, first=True)
        tf = textbox(s, Inches(7.3), y + Inches(0.05), Inches(5.2), Inches(0.5))
        add_para(tf, c, 12, True, RGBColor(0x25, 0x64, 0x49), first=True)
        y += Inches(0.66)
    footer(s, 12)
    notes(s, '合规这一页不讲技术，讲「我们逐条对过要求」。评委关心的是你有没有读懂赛题。')

    # ---------------------------------------------------------------- P13 质量
    s = content_slide(
        prs, 13, '质量与验收', '只写跑过的命令与真实输出',
        [
            ('L0 文档与数值一致性：28 项检查、89 个文件、0 处不一致（通过）', 0),
            ('L1 客户端单测：49 条全部通过（离线执行器，无需真机）', 0),
            ('数值一致性：18 组手算样例 + 5 组封顶 + 6 条边界，323 个断言点零误差', 0),
            ('L3 服务端接口：243 条用例全部通过', 0),
            ('编译门禁：真实生效（故意写错一处类型 → 必须 BUILD FAILED）', 0),
            ('设备侧实测：hypium 在模拟器上跑通 49 条（11 条纯逻辑通过，38 条受 aa test 的 Context 限制）', 0),
            ('已修缺陷 7 个：压栈崩溃、徽章数不一致、头像框误画成图标、已读按钮无响应、今日已得负数、兑换回读失败、「无」误判为待购买', 0),
        ],
        shot='02-dashboard.png',
        note='这一页的关键是「不吹」：写清楚哪些跑过、哪些没跑过。没跑过的在下一页如实说明。')

    # ---------------------------------------------------------------- P14 智能服务
    s = content_slide(
        prs, 14, '智能服务与分享', '把「回报」做成可传播的东西',
        [
            ('任务推送：4 类条件（今日未记 / 连续记录将断 / 目标差一点 / 新科普）', 0),
            ('生活建议：5 条优先级规则，首页最多显示 1 条，避免打扰', 0),
            ('分享卡片：1080×1440 与 1080×1080 两种尺寸', 0),
            ('不含姓名、院校、团队、头像；不接第三方社交 SDK', 0),
            ('生成的是图片，用户自己决定发到哪里', 0),
        ],
        shot='08-shop.png',
        note='分享这一块刻意做得「不自传播」：不接 SDK、不含身份信息，等于把传播的主动权交回用户。')

    # ---------------------------------------------------------------- P15 展望
    s = content_slide(
        prs, 15, '后续计划', '已经准备好的接口与下一步',
        [
            ('端侧真模型：替换 AiEngine 实现，上层不动', 0),
            ('真机与双设备实测：产出带数据的完整截图与演示视频', 0),
            ('真实碳普惠对接：需实名与地方平台签约', 0),
            ('更多外观主题与家庭账户体系', 0),
            ('可选服务端公网部署：域名 + 备案 + TLS', 0),
        ],
        shot='07-badge.png',
        note='展望要克制：只讲已经有接口支撑的，不讲画大饼的。')

    # ---------------------------------------------------------------- P16 结尾
    s = slide_blank(prs)
    rect(s, 0, 0, W, H, GREEN)
    tf = textbox(s, Inches(1.0), Inches(2.3), Inches(11.3), Inches(1.6),
                 align=PP_ALIGN.CENTER)
    add_para(tf, '记录低碳，攒出改变', 52, True, WHITE, first=True, align=PP_ALIGN.CENTER)
    tf = textbox(s, Inches(1.0), Inches(3.9), Inches(11.3), Inches(1.2),
                 align=PP_ALIGN.CENTER)
    add_para(tf, '碳小布 CarbonBoo　·　赛题二', 22, False, LIGHT, first=True, align=PP_ALIGN.CENTER)
    tf = textbox(s, Inches(1.0), Inches(4.7), Inches(11.3), Inches(1.2),
                 align=PP_ALIGN.CENTER)
    add_para(tf, '谢谢，欢迎提问', 18, False, RGBColor(0xC8, 0xE6, 0xD5), first=True, align=PP_ALIGN.CENTER)
    notes(s, '结尾（9:30–10:00）：一句 slogan 收住，然后停下等提问，不要再补充介绍。')

    os.makedirs(OUT_DIR, exist_ok=True)
    prs.save(OUT)
    print('SAVED', OUT, os.path.getsize(OUT), 'bytes', len(prs.slides.__iter__.__self__._sldIdLst), 'slides')


if __name__ == '__main__':
    build()

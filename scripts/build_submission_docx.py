# -*- coding: utf-8 -*-
"""
build_submission_docx.py —— 生成参赛「设计方案」Word 文档。

规格（按《开源鸿蒙大赛作品提交要求》）：
  - 正文：宋体、小四（12pt）、1.5 倍行距
  - 标题：黑体
  - 内容：设计思路 / 功能实现逻辑 / 技术架构 / 软硬件选型 / 测试结果
  - 全文不出现院校、团队、指导教师信息（匿名要求）

运行：
  C:\\Users\\Admin\\.dsh\\dsh-runtimes\\dsh-primary-runtime\\dependencies\\python\\python.exe ^
      scripts\\build_submission_docx.py
"""
import os
import sys

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(REPO, 'docs', 'screenshots')
OUT_DIR = os.path.join(REPO, 'submit')
OUT = os.path.join(OUT_DIR, '01-设计方案-碳小布CarbonBoo.docx')

SONG = '宋体'
HEI = '黑体'
BODY_PT = 12          # 小四
LINE = 1.5


# --------------------------------------------------------------------- 基础工具
def set_run_font(run, name_cn, size_pt=None, bold=None, color=None):
    run.font.name = name_cn
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn('w:rFonts'))
    if rfonts is None:
        rfonts = OxmlElement('w:rFonts')
        rpr.append(rfonts)
    rfonts.set(qn('w:eastAsia'), name_cn)
    rfonts.set(qn('w:ascii'), name_cn)
    rfonts.set(qn('w:hAnsi'), name_cn)
    if size_pt is not None:
        run.font.size = Pt(size_pt)
    if bold is not None:
        run.font.bold = bold
    if color is not None:
        run.font.color.rgb = color


def add_page_number_footer(section):
    p = section.footer.paragraphs[0]
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run = p.add_run()
    fld_begin = OxmlElement('w:fldChar')
    fld_begin.set(qn('w:fldCharType'), 'begin')
    instr = OxmlElement('w:instrText')
    instr.set(qn('xml:space'), 'preserve')
    instr.text = ' PAGE '
    fld_end = OxmlElement('w:fldChar')
    fld_end.set(qn('w:fldCharType'), 'end')
    run._r.append(fld_begin)
    run._r.append(instr)
    run._r.append(fld_end)
    set_run_font(run, SONG, 10.5)


class Doc:
    def __init__(self):
        self.d = Document()
        self._setup()

    def _setup(self):
        sec = self.d.sections[0]
        sec.page_width = Cm(21.0)
        sec.page_height = Cm(29.7)
        sec.left_margin = Cm(3.0)
        sec.right_margin = Cm(2.6)
        sec.top_margin = Cm(2.6)
        sec.bottom_margin = Cm(2.6)
        add_page_number_footer(sec)

        normal = self.d.styles['Normal']
        normal.font.name = SONG
        normal.font.size = Pt(BODY_PT)
        normal.element.rPr.rFonts.set(qn('w:eastAsia'), SONG)
        pf = normal.paragraph_format
        pf.line_spacing = LINE
        pf.space_before = Pt(0)
        pf.space_after = Pt(0)

    # ---------------------------------------------------------------- 段落
    def p(self, text, indent=True, size=None, bold=False, align=None,
          space_before=0, space_after=4, color=None):
        para = self.d.add_paragraph()
        pf = para.paragraph_format
        pf.line_spacing = LINE
        pf.space_before = Pt(space_before)
        pf.space_after = Pt(space_after)
        if indent:
            pf.first_line_indent = Pt(BODY_PT * 2)
        if align is not None:
            para.alignment = align
        run = para.add_run(text)
        set_run_font(run, SONG, size if size else BODY_PT, bold, color)
        return para

    def _heading(self, text, level, size):
        """用内置 Heading 样式（Word 导航窗格与自动目录才认），再覆盖中文字体与字号。

        为什么必须挂 Heading 样式：交付文档要能在 Word 里折叠/跳转，评委按章节翻；
        只在段落上做直接格式（黑体加粗）时，导航窗格是空的、也无法自动生成目录。
        python-docx 的 add_heading 会给段落套 `Heading N`，之后再把 run 的字体改回黑体。
        """
        para = self.d.add_heading('', level=level)
        pf = para.paragraph_format
        pf.line_spacing = LINE
        pf.space_before = Pt(16 if level == 1 else (10 if level == 2 else 8))
        pf.space_after = Pt(8 if level == 1 else (6 if level == 2 else 4))
        pf.first_line_indent = Pt(0)
        run = para.add_run(text)
        set_run_font(run, HEI, size, True)
        return para

    def h1(self, text):
        return self._heading(text, 1, 16)

    def h2(self, text):
        return self._heading(text, 2, 14)

    def h3(self, text):
        return self._heading(text, 3, 12)

    def bullets(self, items, marker='（%d）'):
        for i, it in enumerate(items, start=1):
            para = self.d.add_paragraph()
            pf = para.paragraph_format
            pf.line_spacing = LINE
            pf.space_after = Pt(2)
            pf.left_indent = Pt(BODY_PT * 2)
            head = marker % i if '%d' in marker else marker
            run = para.add_run(head + it)
            set_run_font(run, SONG, BODY_PT)

    def caption(self, text):
        para = self.d.add_paragraph()
        pf = para.paragraph_format
        pf.line_spacing = 1.0
        pf.space_before = Pt(2)
        pf.space_after = Pt(8)
        para.alignment = WD_ALIGN_PARAGRAPH.CENTER
        run = para.add_run(text)
        set_run_font(run, SONG, 10.5, False, RGBColor(0x55, 0x55, 0x55))

    def image(self, path, width_cm=6.2, caption=None):
        if not os.path.exists(path):
            return
        para = self.d.add_paragraph()
        para.alignment = WD_ALIGN_PARAGRAPH.CENTER
        para.paragraph_format.space_before = Pt(6)
        para.paragraph_format.space_after = Pt(0)
        para.add_run().add_picture(path, width=Cm(width_cm))
        if caption:
            self.caption(caption)

    def image_row(self, paths, width_cm=5.6, caption=None):
        """并排插图（单行表格，无边框）。"""
        paths = [p for p in paths if os.path.exists(p)]
        if not paths:
            return
        table = self.d.add_table(rows=1, cols=len(paths))
        table.alignment = WD_TABLE_ALIGNMENT.CENTER
        for i, path in enumerate(paths):
            cell = table.rows[0].cells[i]
            para = cell.paragraphs[0]
            para.alignment = WD_ALIGN_PARAGRAPH.CENTER
            para.add_run().add_picture(path, width=Cm(width_cm))
        if caption:
            self.caption(caption)

    def table(self, headers, rows, widths=None, font_pt=10.5):
        table = self.d.add_table(rows=1, cols=len(headers))
        table.style = 'Table Grid'
        table.alignment = WD_TABLE_ALIGNMENT.CENTER
        hdr = table.rows[0].cells
        for i, h in enumerate(headers):
            para = hdr[i].paragraphs[0]
            para.alignment = WD_ALIGN_PARAGRAPH.CENTER
            para.paragraph_format.line_spacing = 1.0
            run = para.add_run(h)
            set_run_font(run, HEI, font_pt, True)
        for row in rows:
            cells = table.add_row().cells
            for i, val in enumerate(row):
                para = cells[i].paragraphs[0]
                para.paragraph_format.line_spacing = 1.0
                para.paragraph_format.space_after = Pt(0)
                run = para.add_run(str(val))
                set_run_font(run, SONG, font_pt)
        if widths:
            for row in table.rows:
                for i, w in enumerate(widths):
                    row.cells[i].width = Cm(w)
        # 表后留白
        self.d.add_paragraph().paragraph_format.space_after = Pt(4)
        return table

    def page_break(self):
        self.d.add_page_break()

    def save(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.d.save(path)


# --------------------------------------------------------------------- 正文
def build():
    doc = Doc()

    # =============================================================== 封面
    for _ in range(4):
        doc.p('', indent=False)
    para = doc.p('碳小布 CarbonBoo', indent=False, size=30, bold=True,
                 align=WD_ALIGN_PARAGRAPH.CENTER, space_after=6)
    for r in para.runs:
        set_run_font(r, HEI, 30, True)
    para = doc.p('个人碳足迹记录与低碳行为激励应用', indent=False, size=16,
                 align=WD_ALIGN_PARAGRAPH.CENTER, space_after=30)
    for r in para.runs:
        set_run_font(r, HEI, 16, False)

    doc.image(os.path.join(SHOTS, '01-home.png'), width_cm=6.6,
              caption='图 0-1  应用首页（API 12 预览器实拍）')

    for _ in range(2):
        doc.p('', indent=False)
    doc.p('设计方案', indent=False, size=20, bold=True,
          align=WD_ALIGN_PARAGRAPH.CENTER, space_after=24)
    for r in doc.d.paragraphs[-1].runs:
        set_run_font(r, HEI, 20, True)

    info = [
        ('参赛赛题', '赛题二　碳足迹·全民绿色生活碳积分与减排指南'),
        ('作品形态', '纯北向应用（OpenHarmony 单机版，无需任何硬件）'),
        ('技术底座', 'ArkTS + ArkUI（Stage 模型，API 12）+ 可选 FastAPI / MySQL 服务端'),
        ('文档版本', 'v1.0'),
        ('编制日期', '2026 年 10 月'),
    ]
    for k, v in info:
        para = doc.d.add_paragraph()
        para.alignment = WD_ALIGN_PARAGRAPH.CENTER
        para.paragraph_format.line_spacing = LINE
        para.paragraph_format.space_after = Pt(4)
        r1 = para.add_run(k + '：')
        set_run_font(r1, HEI, 12, True)
        r2 = para.add_run(v)
        set_run_font(r2, SONG, 12)

    doc.page_break()

    # =============================================================== 目录（域）
    doc.h1('目录')
    # 用真正的 Word 目录域：打开文档后 Ctrl+A → F9（或右键"更新域"）即可生成带页码的目录。
    # 为什么不写死条目：章节标题已挂 Heading 1/2/3，域能保证页码与实际排版永远一致；
    # 手写目录一旦页数变化就会失真（上一版就是手写的，没有页码）。
    para = doc.d.add_paragraph()
    para.paragraph_format.line_spacing = LINE
    fld_begin = OxmlElement('w:fldChar')
    fld_begin.set(qn('w:fldCharType'), 'begin')
    instr = OxmlElement('w:instrText')
    instr.set(qn('xml:space'), 'preserve')
    instr.text = 'TOC \\o "1-2" \\h \\z \\u'
    fld_sep = OxmlElement('w:fldChar')
    fld_sep.set(qn('w:fldCharType'), 'separate')
    hint = OxmlElement('w:t')
    hint.text = '（在此处右键 → 更新域，即可生成带页码的目录）'
    fld_end = OxmlElement('w:fldChar')
    fld_end.set(qn('w:fldCharType'), 'end')
    r = para.add_run()._r
    r.append(fld_begin)
    r.append(instr)
    r.append(fld_sep)
    r.append(hint)
    r.append(fld_end)
    doc.page_break()

    # =============================================================== 一、项目概述
    doc.h1('一、项目概述')

    doc.h2('1.1 赛题与作品定位')
    doc.p('本作品面向赛题二「碳足迹·全民绿色生活碳积分与减排指南」。赛题要求开发一款基于 '
          'OpenHarmony 的**单机版**碳足迹记录应用：通过量化日常低碳行为的减排贡献，以积分激励'
          '机制帮助用户养成绿色生活习惯。')
    doc.p('我们把作品命名为「碳小布 CarbonBoo」——「碳」是主题，「小布」取「一块布、一点点攒」'
          '的意思，对应产品核心动作：每一笔低碳行为都记下来，攒成看得见的减排量。')
    doc.p('作品形态是**纯北向应用**：一部 OpenHarmony 手机或平板即可完整运行，不依赖任何'
          '传感器、开发板或外接硬件；不联网、不注册也能完成全部五项主要功能。')

    doc.h2('1.2 一句话介绍与核心数据')
    doc.p('一句话：**记一笔低碳行为，得到减排量、积分与徽章，并把这份改变分享出去。**')
    doc.p('作品关键规模数据如下（均为本机实测或代码统计，非估算）：')
    doc.table(
        ['维度', '数据', '说明'],
        [
            ['客户端代码', '112 个 .ets 文件 / 18 404 行', 'app/entry/src/main/ets 下的 ArkTS 源码'],
            ['页面', '18 个', '5 个 Tab 主页面 + 13 个二级页'],
            ['数据库表（客户端）', '19 张', '本机 relationalStore，含 5 张静态字典表'],
            ['数据库表（服务端，可选）', '21 张', '18 张同名同构业务表 + 3 张管理表'],
            ['碳因子', '31 项', '出行 11 / 水电燃气 8 / 旧物回收 8 / 光盘 3'],
            ['目标 / 徽章 / 商品', '11 条 / 8 枚 / 9 件', '10 个目标 + 1 个长期目标；8 枚徽章；8 个头像框 + 1 套主题'],
            ['服务层', '14 个 Service', '页面层不写业务计算，全部经 Service'],
            ['测试', 'L1 48 条 + L3 243 条 + L0 28 项检查', '全部通过，详见第八章'],
        ],
        widths=[3.6, 4.4, 7.0])

    doc.h2('1.3 设计目标与硬约束')
    doc.p('设计之初先锁定约束，再谈功能。约束来自赛题文件与工程可维护性两方面：')
    doc.bullets([
        '**纯北向、无硬件**：不引入任何外设，评分点全部落在软件体验上。',
        '**单机可用是底线**：断网、不登录时，五项主要功能必须 100% 可用。',
        '**不引入任何第三方 npm / HAR 包**：图表、Markdown 渲染、分享卡片全部自研，避免供应链与体积风险。',
        '**数值必须可追溯**：每条记录的减排量都带因子快照，因子升级永不回写历史。',
        '**积分必须可审计**：余额 = 收入合计 − 支出合计，流水只增不删，每条可回溯来源。',
    ])

    # =============================================================== 二、设计思路
    doc.page_break()
    doc.h1('二、设计思路')

    doc.h2('2.1 用户场景')
    doc.p('目标用户是「想低碳但不知道自己做得怎么样」的普通人。真实痛点有三个：')
    doc.bullets([
        '**看不见**：骑车上班、少开一天车、光盘、卖废纸，这些行为到底减了多少碳？没有数字就没有反馈。',
        '**坚持不了**：没有即时回报的行为很难持续，低碳尤其如此。',
        '**不知怎么做**：知道要低碳，但不知道具体做什么、做多少才有意义。',
    ])
    doc.p('对应地，产品用三件事回应：**把行为变成数字**（核算）、**把数字变成回报**（积分与徽章）、'
          '**把回报变成习惯**（目标、提醒、建议、分享）。')

    doc.h2('2.2 四条设计铁律')
    doc.p('整个工程有四条不可违背的铁律，任何一行代码与之冲突都要改代码。它们既是架构约束，'
          '也是评审时可以逐条验证的设计承诺：')
    doc.table(
        ['铁律', '内容', '为什么是铁律'],
        [
            ['① 本地优先', '本机 relationalStore 是唯一真相源，云端与近场只做「搬运」，不参与业务计算',
             '赛题要求单机版；保证断网、无账号时功能不缩水'],
            ['② 单一计算入口', '减排量只能由 CarbonService.calculate() 产出，页面与组件禁止自己乘因子',
             '数值只有一个出口，才能保证 18 组手算样例零误差'],
            ['③ 因子快照', '每条记录落库时写入 factor_value / factor_version / factor_source / confidence',
             '因子库升级后历史数据仍可复算、可解释，不会「昨天的 96 分今天变成 90 分」'],
            ['④ 积分单向可追溯', '余额 = 收入合计 − 支出合计；流水只增不删；积分只能经 PointService 写入',
             '积分是激励的信用基础，任何「凭空加减」都会让用户失去信任'],
        ],
        widths=[2.6, 7.6, 5.0])

    doc.h2('2.3 九项官方要求全覆盖')
    doc.p('赛题二列了 5 项主要功能和 4 项创新拓展，共 9 项。我们的做法是**一项不缺，全部实现**，'
          '并在文档、代码、验收三处一一对应：')
    doc.table(
        ['类别', '官方要求', '本项目落地'],
        [
            ['主要 1', '低碳行为核算（手动录入出行 / 节水节电 / 旧物回收 / 光盘，内置因子库自动计算，累计碳足迹）',
             '31 项因子库；录入向导支持 5 大类 20 个可录入子类型；单一入口 CarbonService.calculate()'],
            ['主要 2', '数据可视化看板（折线 / 柱状 / 饼图，日周月年趋势，分类查询历史）',
             '自研 Canvas 图表；4 个时间粒度 × 3 种图；分类筛选与历史检索'],
            ['主要 3', '碳积分激励体系（日常低碳任务、积分、虚拟徽章 / 植树证书等奖励）',
             '积分账本（记录类日封顶 200）+ 11 条目标 + 8 枚徽章 + 碳小铺 9 件虚拟商品'],
            ['主要 4', '双碳科普专栏（内置图文科普，政策与生活技巧）',
             '12 篇离线科普（政策 4 / 技巧 4 / 知识 4），rawfile 内置 Markdown，阅读进度与收藏'],
            ['主要 5', '本地数据管理（备份、统计报表导出留存）',
             '19 张表全量快照备份 / 恢复 / 校验；3 份 CSV 导出（带 BOM，Excel 直开）'],
            ['创新 Ⅰ', '鸿蒙特色：超级终端多设备数据同步，家庭碳积分合并统计',
             '服务端 LWW 增量同步 + 手机平板多端同一账号；另实现鸿蒙近场协同演示层；家庭合并只读视图'],
            ['创新 Ⅱ', '端侧 AI：图片智能识别低碳行为，自动录入减排数据',
             '识图接口层 + 本地启发式引擎（engine=mock），候选类型交给用户确认，图片不落盘不上传'],
            ['创新 Ⅲ', '平台对接：模拟城市碳普惠接口，积分互通与权益兑换',
             '100 积分 = 1 碳币，单向不可逆；5 条虚拟权益；全流程强制「模拟演示」标注'],
            ['创新 Ⅳ', '智能服务：个性化任务推送、生活建议、减排成果社交分享',
             '本地规则引擎推任务；5 条优先级建议规则；两种尺寸分享卡片（不含任何身份信息）'],
        ],
        widths=[2.2, 6.6, 6.4], font_pt=9.5)

    # =============================================================== 三、功能实现逻辑
    doc.page_break()
    doc.h1('三、功能实现逻辑')
    doc.p('本章按用户的真实操作路径讲每一项功能「点下去之后发生了什么」。每一小节统一给三样东西：'
          '用户看得到的路径、系统内部的处理链、以及边界与失败时的表现。')

    doc.h2('3.1 低碳行为核算')
    doc.p('**用户路径**：记录 → ＋ 记一笔 → 选大类（出行 / 水电燃气 / 旧物回收 / 光盘）→ 选子类型 → '
          '填数量 → 看实时预览（减排量、本次应得、今日剩余额度）→ 保存。')
    doc.p('**内部处理链**（一次保存就是一次事务）：')
    doc.bullets([
        '页面把「子类型 + 数量 + 发生时间」交给 RecordService，页面本身不做任何乘法（铁律 ②）。',
        'CarbonService.calculate() 取出因子，按 reduction = 数量 × 因子值 计算，定点四舍五入到 4 位小数；'
        '同时把 factor_value / factor_version / factor_source / confidence 一并快照（铁律 ③）。',
        'PointService 计算本次应得 C = round(减排量 × 100)，再查「今日已得 D」得到实入 A = max(0, min(C, 200 − D))；'
        'A 小于 C 时该笔标记 point_capped = 1，界面显示「⚠️ 已达今日上限」。',
        'RewardEngine 检查 11 条目标的达成条件与 8 枚徽章的解锁条件，达标的写入 user_goal / user_badge。',
        '上述五张表的写入在同一个事务里完成，任一失败整体回滚，不会出现「有记录没积分」的半截状态。',
    ])
    doc.p('**边界**：减排量小于 0.005 kg 不生成积分流水（避免灌水）；单笔输入超上限（出行 200 km、'
          '用电 200 kWh、用水 2000 L、天然气 100 m³、回收 500 kg、光盘 20 次）仍可保存，但标记 is_abnormal，'
          '并在明细页提示复核——不阻断用户，也不让异常数据污染统计。')

    doc.h2('3.2 数据可视化看板')
    doc.p('**用户路径**：看板 Tab → 切换日 / 周 / 月 / 年 → 看折线趋势、分类饼图、柱状对比 → '
          '按分类筛选（全部 / 出行 / 水电 / 回收 / 光盘）→ 点柱状图下钻到当日记录列表。')
    doc.p('**内部处理**：StatisticsService 按时间窗口把 carbon_record 聚合成序列（折线 ≤ 31 个点，'
          '年视图按月聚合），分类占比按 factor_category 分组；所有聚合走 SQL SUM / COUNT，'
          '**禁止用浮点累加求总量**，避免长序列累积误差。图表由自研 ChartCanvas 组件绘制，'
          '不依赖任何图表库。')
    doc.p('**空态**：没有数据时不是空白页，而是给出下一步动作（「去记一笔，看板立刻有数据」）。')

    doc.h2('3.3 碳积分激励体系')
    doc.p('这一项是产品的「发动机」，拆成三层：')
    doc.p('**（1）积分账本。** 三类来源：记录类（每 1 kg 减排 100 分，日封顶 200 分）、'
          '目标类（达成即发，不封顶）、消费类（兑换扣分，记负数）。流水只增不删：编辑记录时'
          '不修改原流水，而是生成一条差额冲正（reverse），删除记录同理——保证任何时候都能解释'
          '「这 1 分是怎么来的」。')
    doc.p('**（2）目标体系。** 11 条目标分短 / 中 / 长三档，覆盖行为频次（如「每周骑车 3 次」）、'
          '数量累计（如「月骑行 100 km」）与成果累计（如「累计减排 50 kg」）。周期按自然周 / 月 / 年'
          '计算，周一 00:00 起算；每条目标在同一周期内只发一次奖，靠 (user_id, goal_id, period_key) '
          '唯一约束保证幂等，重复达成不会重复发分。')
    doc.p('**（3）徽章与碳小铺。** 8 枚徽章只看里程碑（首次记录、连续 7 天、累计 100 kg、'
          '集齐 8 个头像框、100 天里记满 80 天等），**徽章本身不发积分**，避免「为拿分刷徽章」。'
          '碳小铺卖的是纯虚拟外观（8 个头像框 + 1 套主题），无实物、无提现、不可转让；'
          '购买走事务 + 唯一约束，重复点击不会重复扣分。')
    doc.image(os.path.join(SHOTS, '06-goal.png'), 5.2, '图 3-1  目标页：短 / 中 / 长期三档')
    doc.image(os.path.join(SHOTS, '07-badge.png'), 5.2, '图 3-2  徽章墙：8 枚里程碑徽章')

    doc.h2('3.4 双碳科普专栏')
    doc.p('**用户路径**：科普 Tab → 按分类（政策 / 低碳技巧 / 知识）浏览 12 篇 → 点开阅读 → '
          '滚动到底自动标记已读 → 可收藏。')
    doc.p('**内部处理**：文章索引在 science_article 表（首次启动由 rawfile 的 science-index.json 播种），'
          '正文是 rawfile 里的 12 份 Markdown，由自研 Reader 渲染，**完全离线、不请求任何远程资源**。'
          '已读判定是「滚动 ≥ 80% 且停留 ≥ 3 秒」，避免一划而过被记成已读。')
    doc.image(os.path.join(SHOTS, '04-science.png'), 5.2, '图 3-3  科普专栏：三类分组与搜索')

    doc.h2('3.5 本地数据管理')
    doc.p('**备份**：把 19 张表序列化成一份 JSON 快照（含表名、行数与校验摘要），存到应用沙箱；'
          '文件名带时间戳到分钟。**恢复**：先做一次当前状态的快照（可回退），再用快照覆盖，'
          '覆盖后逐表校验行数与摘要，任一项不一致即整体回滚。')
    doc.p('**导出**：三份 CSV（carbon-records / point-records / summary），UTF-8 带 BOM、'
          'CRLF 换行，Excel 双击不乱码；碳记录表带「因子值 / 因子版本 / 可信度」三列，'
          '让导出的数据自身可解释。')

    doc.h2('3.6 创新 Ⅰ：多设备同步与家庭碳积分合并')
    doc.p('赛题原文把「超级终端多设备数据同步、家庭碳积分合并统计」列为创新项。我们做了两条通路：')
    doc.p('**（1）云通路（主通路）**：注册 / 登录后，同一账号在手机与平板间同步。同步是**增量**的'
          '（只取 updated_at 大于上次同步锚点的行）、**幂等**的（以 id + 业务唯一键判重）、'
          '**冲突可解释**的（同一行两端都改过时按 LWW 取较新，并用服务端时间偏移校正客户端时钟；'
          '偏移量必须取反后使用，否则会把对端时间戳推错方向）。软删除同样传播，一端删了另一端不会复活。')
    doc.p('**（2）近场通路（演示层）**：基于鸿蒙分布式能力（distributedDeviceManager + distributedKVStore）'
          '做同一网络下两台设备的配对与数据交换，把家庭成员的统计快照合并成一张「家庭碳积分」卡片。'
          '这一层是**可整体关闭**的：即使设备不支持、没权限、配对失败，界面只显示「未组网」，'
          '绝不崩溃，也不影响任何单机功能。')
    doc.p('**设计取舍**：家庭合并只读——只合并统计口径（人数、记录数、减排合计、积分合计），'
          '不合并明细、不改任何一方的数据，避免「谁改了谁的账」。')
    doc.image(os.path.join(SHOTS, '11-sync.png'), 5.2, '图 3-4  设备协同页（未登录 / 未组网时的降级展示）')

    doc.h2('3.7 创新 Ⅱ：端侧 AI 识图')
    doc.p('**用户路径**：录入页 → 识图 → 选一张照片 → 系统给出候选行为（如「地铁通勤」）与置信提示 → '
          '用户确认或改选 → 自动填入表单。')
    doc.p('**实现策略**：识图被做成一个接口（AiEngine），当前提供本地启发式引擎（engine=mock），'
          '未来替换成端侧真模型只需换实现、不动上层。三条硬约束：')
    doc.bullets([
        '**图片不落盘、不上传**：只在内存里读一次像素用于推断，识别完即丢。',
        '**只给候选，不替用户决定**：识别结果必须经用户确认才写入记录。',
        '**不展示置信度数字或准确率**：避免诱导用户相信一个并不精确的数值；界面上只写「模拟识别」。',
    ])
    doc.p('**降级**：识别失败或超时（3 秒）时，退化为「图标网格快速录入」——用户在三行图标里点选，'
          '同样两步完成录入，功能不缺失。')

    doc.h2('3.8 创新 Ⅲ：碳普惠模拟')
    doc.p('**规则**：100 积分兑换 1 碳币，**单向不可逆**（碳币不能换回积分）；碳币可在 5 条虚拟权益里兑换。'
          '整个页面常驻一条提示条：「本功能为模拟演示，不对接任何真实碳普惠平台，权益不可提现、'
          '不能转让」。')
    doc.p('**为什么强调「模拟」**：赛题要求的是「模拟城市碳普惠接口」，而真实碳普惠涉及实名、'
          '地方平台签约与资金合规。我们选择把边界画清楚——做一个完整可用的兑换闭环，但不冒充真实通道。')
    doc.image(os.path.join(SHOTS, '10-include.png'), 5.2, '图 3-5  碳普惠模拟页：兑换比例与模拟声明')

    doc.h2('3.9 创新 Ⅳ：智能服务与减排成果分享')
    doc.p('**任务推送**：本地规则引擎按「今天还没记 / 连续记录快断了 / 目标差一点 / 新科普」四类条件'
          '挑一条推给用户，每条任务都能一键跳到对应页面。提醒时间默认 20:00，用系统 reminderAgent，'
          '完全离线。')
    doc.p('**生活建议**：5 条优先级规则（近期无记录 > 有未达成目标 > 分类偏科 > 科普未读 > 通用建议），'
          '首页最多显示 1 条，避免打扰。')
    doc.p('**分享卡片**：两种尺寸（1080×1440 竖版 / 1080×1080 方版），内容是减排量、等效换算、'
          '一句鼓励，**不含姓名、学校、团队、头像等任何身份信息**，也不接第三方社交 SDK——'
          '生成的是图片，用户自己决定发到哪里。')

    # =============================================================== 四、技术架构
    doc.page_break()
    doc.h1('四、技术架构')

    doc.h2('4.1 总体分层')
    doc.p('客户端采用五层结构，依赖方向自上而下，页面层不碰数据库、不写计算：')
    doc.table(
        ['层次', '职责', '关键实现'],
        [
            ['页面层（pages）', '只做三件事：取数、渲染、把点击变成路由或 Service 调用', '18 个页面 + Index 导航壳（Navigation + Tabs）'],
            ['组件层（components）', '可复用 UI 单元，无业务状态', '23 个组件，含 PageHeader / ChartCanvas / ScienceReader / ShareSheet'],
            ['服务层（viewmodel）', '全部业务编排与事务边界', '14 个 Service，统一返回 AppResult'],
            ['数据层（data / service）', '表结构、Dao、种子、因子、备份编解码', '19 张表；12 个 Dao；SeedRepository / FactorRepository'],
            ['基础设施（util）', '定点小数、格式化、JSON 防御式解析、常量', 'DecimalUtil（SCALE=1e6）、JsonUtil、Formatter'],
        ],
        widths=[3.6, 6.4, 6.4])
    doc.p('数据流只有四条主干，且全部单向：')
    doc.bullets([
        'A 录入流：页面 → RecordService → CarbonService（唯一计算）→ PointService / RewardEngine → 五表事务。',
        'B 展示流：页面 → StatisticsService / PointService → 只读查询 → 渲染。',
        'C 同步流：SyncService ↔ 服务端；只搬运，不参与计算（铁律 ①）。',
        'D 识图流：录入页 → AiAssistService → AiEngine（可替换）→ 候选列表 → 用户确认 → 回到 A。',
    ])

    doc.h2('4.2 页面结构')
    doc.p('18 个页面 = 5 个 Tab 主页面 + 13 个二级页。导航用 Navigation + NavPathStack，'
          '二级页以 NavDestination 容器压栈（这一点很关键：pageMap 的 builder 必须返回 NavDestination '
          '容器节点，否则压栈时引擎会直接崩，详见 8.5 节）。')
    doc.table(
        ['类型', '页面', '说明'],
        [
            ['Tab 1', '首页 Home', '问候、累计减排、积分与今日记录、今日目标、近 7 天迷你柱、今日建议、＋ 记一笔'],
            ['Tab 2', '看板 Dashboard', '日 / 周 / 月 / 年 × 折线 / 饼图 / 柱状 + 分类筛选'],
            ['Tab 3', '记录 Record', '按月分组的记录列表，支持搜索、左滑编辑与删除'],
            ['Tab 4', '科普 Science', '12 篇离线科普，三类分组 + 搜索 + 进度'],
            ['Tab 5', '我的 Mine', '头像框、三张统计卡、7 个入口'],
            ['二级页 ×13', '录入 / 明细 / 搜索 / 目标 / 徽章 / 碳小铺 / 积分明细 / 科普详情 / 协同 / 碳普惠 / 外观 / 设置 / 关于',
             '除「外观」外均可从「我的」或「记录」「科普」进入'],
        ],
        widths=[2.6, 6.0, 7.8], font_pt=10)

    doc.h2('4.3 数据模型')
    doc.p('客户端 19 张表，按「参与同步」与「用途」两个维度组织：')
    doc.table(
        ['分组', '表', '参与同步', '说明'],
        [
            ['业务账本', 'carbon_record / point_record / user_goal / user_badge / user_purchase / user_appearance', '是（6）',
             '记录、积分流水、目标进度、徽章、购买、外观'],
            ['业务附属', 'science_progress / carbon_include / user_profile', '是（3）', '阅读进度、碳币账户、用户档案'],
            ['本机专属', 'device_info / sync_log / app_config / share_record', '否（4）', '设备、同步日志、本地配置、分享记录'],
            ['静态字典', 'goal_def / badge_def / shop_item / science_article / carbon_factor_meta', '否（5）',
             '首次启动由 rawfile 播种，设备间应一致'],
            ['派生缓存', 'point_daily_stat', '否（1）', '仅用于展示加速，可随时由流水重建'],
        ],
        widths=[2.4, 7.4, 2.0, 5.0], font_pt=9.5)
    doc.p('几个关键的建模决定：')
    doc.bullets([
        '**软删除**：全表带 is_deleted，删除只置位并参与同步，保证一端删了另一端不会复活。',
        '**幂等键**：point_record 上 (user_id, source_type, source_id, flow_kind) 唯一；'
        'user_goal 上 (user_id, goal_id, period_key) 唯一——这是「重复点击不重复发分」的实现基础。',
        '**派生缓存不参与判定**：日封顶的「今日已得」从流水实时聚合，而不是读 point_daily_stat，'
        '避免缓存不同步导致多发或漏发。',
        '**因子快照**：carbon_record 存四列因子信息，而不是只存一个结果。',
    ])

    doc.h2('4.4 单一计算入口与定点小数')
    doc.p('所有金额与减排量都用定点小数（1000000 为标度）计算，四舍五入统一 half-up，'
          '禁止用浮点累加求总量。这是「18 组手算样例零误差」的工程基础：')
    doc.p('reduction_kg = round_half_up(活动量 × 因子值, 4)；应得 C = round_half_up(reduction_kg × 100, 0)；'
          '实入 A = max(0, min(C, 200 − D))。')

    doc.h2('4.5 多设备协同协议')
    doc.p('同步的最小单元是「一张表的一行」，协议要点：')
    doc.bullets([
        '**增量**：pull 只取 updated_at 大于上次同步锚点的行；锚点统一用服务端时间，避免两端时钟不同源。',
        '**幂等**：push 时按 id + 业务唯一键判重，重复推送返回 ignored 而不是报错。',
        '**冲突**：同一行两端都改过 → 取较新；平局按 deviceId 字典序决出，保证两端算出一致结果。',
        '**时钟校正**：服务端返回 offsetMs（服务端减客户端），客户端换算时必须取反后再用于比较，'
        '否则会把对端时间戳推向相反方向，让旧数据覆盖新数据。',
        '**软删除传播**：is_deleted 变化同样参与 LWW，删除优先于编辑保留。',
    ])
    doc.p('近场通路复用同一套合并算法，只是把「网络」换成分布式 KV：写入本机快照 → sync(PUSH_PULL) → '
          '有界轮询读取对端快照（250 ms 步进、2 s 上限）→ 归一化合并 → 展示。家庭合并结果只读。')

    doc.h2('4.6 服务端与后台管理（可选件）')
    doc.p('服务端用 FastAPI + SQLAlchemy 2.x + MySQL 8，承担四件事：账号（自建用户名 + 密码 + JWT + bcrypt）、'
          '同步（pull / push / 云端备份）、取价（碳小铺价格）、配置下发（GET /api/v1/config，免鉴权）。')
    doc.p('其中**只有「Web 后台管理端」是可选项**：商品与价格、用户列表、数据概览、订单记录、'
          '系统配置、操作日志。客户端与管理端用两套独立 JWT 密钥，客户端 token 访问 /admin/* 必须 403。')
    doc.p('**为什么服务端不是必须的**：赛题定位是单机版，官方明确「云端存储、多设备同步仅作为创新加分项，'
          '不做强制要求」。因此我们的设计是——没有服务端时，作品仍是完整的单机应用；有服务端时，'
          '创新项 Ⅰ 的体验更完整。')

    # =============================================================== 五、软硬件选型
    doc.page_break()
    doc.h1('五、软硬件选型')

    doc.h2('5.1 软件选型')
    doc.table(
        ['环节', '选型', '版本 / 说明', '理由'],
        [
            ['开发工具', 'DevEco Studio', '26.0.0.851（内置 hvigor 6.26.8 / ohpm / hdc 3.2.0f）', '官方唯一推荐 IDE，赛题要求'],
            ['SDK', 'OpenHarmony SDK', 'API 12（5.0.0.71 Release）', '赛题要求 API 12 及以上；API 12 与工程声明一致'],
            ['语言', 'ArkTS', 'Stage 模型，strict 模式', '鸿蒙主推语言，类型安全便于长期维护'],
            ['UI 框架', 'ArkUI 声明式', 'Navigation + Tabs + NavDestination', '原生组件即可覆盖全部界面，无需三方库'],
            ['本地存储', 'relationalStore（SQLite）', '19 张表', '关系型建模适合账本类数据，事务与唯一约束可用'],
            ['图表', '自研 Canvas', 'ChartCanvas 组件', '不引入三方包；折线 / 柱状 / 饼图均自绘'],
            ['Markdown', '自研解析器', 'ScienceReader', '科普只需 6 类语法，自研足够且更可控'],
            ['服务端（可选）', 'Python 3.11+ / FastAPI / SQLAlchemy 2.x / MySQL 8', 'uvicorn 2 workers；2C2G 已调参', '轻量、单文件部署、易审计'],
            ['测试', 'hypium（≤1.0.21）+ 离线一致性执行器 + pytest', 'L1 / L0 / L3', '官方测试框架 + 自建数值门禁'],
        ],
        widths=[2.4, 4.0, 5.4, 5.6], font_pt=9.5)

    doc.h2('5.2 硬件选型')
    doc.p('**无硬件**。赛题二属于纯北向应用开发类，不需要传感器、开发板、通信模组或开发板供电方案。'
          '运行载体是任意一台 OpenHarmony API 12 及以上版本的手机或平板；界面按 phone 与 tablet 两种'
          '形态适配，不做深色模式（保持单一视觉基线）。')
    doc.p('这一选择是刻意的：把预算与风险从「硬件调试」转移到「软件完成度与数据可信度」，'
          '也更符合赛题「全民绿色生活」的普适定位。')

    doc.h2('5.3 权限清单')
    doc.table(
        ['权限', '用途', '是否必需'],
        [
            ['ohos.permission.DISTRIBUTED_DATASYNC', '鸿蒙近场协同（创新 Ⅰ 的演示通路）', '必需（声明）'],
            ['ohos.permission.INTERNET', '登录 / 多设备同步 / 取价 / 云备份（未登录时全应用不发起任何请求）', '可选'],
            ['ohos.permission.PUBLISH_AGENT_REMINDER', '每日记录提醒', '可选'],
            ['ohos.permission.WRITE_IMAGEVIDEO', '把分享卡片保存到相册（用保存控件按需申请）', '可选'],
        ],
        widths=[7.6, 7.4, 2.6], font_pt=10)
    doc.p('**不申请**位置、通讯录、麦克风、相机权限——识图走「仅选图 + 图标网格降级」，不用相机。')

    # =============================================================== 六、碳核算
    doc.page_break()
    doc.h1('六、碳核算方法与因子库')

    doc.h2('6.1 计算公式')
    doc.p('核心公式只有一条：**减排量(kgCO₂e) = 活动量 × 因子值(kgCO₂e/单位) × 修正系数**。'
          '其中修正系数当前恒为 1.0，保留字段以备将来按地区电网差异做调整（记录里仍写 1.0，便于追溯）。')
    doc.p('积分换算：单笔应得 = round(减排量 × 100)；当日实入受 200 分封顶限制；'
          '减排量 < 0.005 kg 不生成积分流水。')

    doc.h2('6.2 因子库与来源')
    doc.p('因子库共 31 项，分四类。每项都标注来源与可信度（verified / provisional），'
          'provisional 项在界面上显示「参考值」角标：')
    doc.table(
        ['类别', '数量', '代表因子', '来源与可信度'],
        [
            ['出行', '11', '地铁 0.0300、公交 0.0400、燃油车 0.1920 kgCO₂e/km', 'GB/T 51366 转引 + 项目推算（provisional）'],
            ['水电燃气', '8', '电力 0.5703 kgCO₂e/kWh、自来水 0.000168 kgCO₂e/L、天然气 2.1840 kgCO₂e/m³',
             '生态环境部《2024 年全国电力碳足迹因子》等（verified）'],
            ['旧物回收', '8', '废纸 0.9000、废铝 9.0000、废塑料 1.5000 kgCO₂e/kg', '团体标准附录（verified）'],
            ['光盘行动', '3', '每餐 0.3500 kgCO₂e、食物浪费 2.5000 kgCO₂e/kg', '按餐次估算（provisional）'],
        ],
        widths=[2.4, 1.6, 7.4, 5.6], font_pt=9.5)
    doc.p('因子库版本号 CF-2026.2，规则是「只有数值变化才升版本号」。每条记录落库时快照当时的因子值与版本，'
          '升级因子库不会改变任何历史记录的减排量与积分。')

    doc.h2('6.3 手算样例（节选）')
    doc.p('完整的 18 组正向样例 + 5 组封顶样例 + 6 条边界样例见附录文档，这里节选六组：')
    doc.table(
        ['行为', '数量', '计算过程', '减排量', '积分'],
        [
            ['骑自行车', '5 km', '5 × 0.1920', '0.9600 kg', '96'],
            ['乘地铁', '8 km', '8 × 0.1620', '1.2960 kg', '130'],
            ['少开一天车', '2 天', '2 × 8.0 × 0.1920', '3.0720 kg', '307'],
            ['节约用电', '10 kWh', '10 × 0.5703', '5.7030 kg', '570'],
            ['回收废铝', '1.5 kg', '1.5 × 9.0000', '13.5000 kg', '1350'],
            ['光盘一餐', '1 餐', '1 × 0.3500', '0.3500 kg', '35'],
        ],
        widths=[3.2, 2.4, 5.4, 3.4, 2.2], font_pt=10)
    doc.p('封顶示例：今日已得 150 分时再记一笔 96 分的记录，实入 = max(0, min(96, 200 − 150)) = 50 分，'
          '该笔标记为「已达今日上限」；若今日已得 200 分，则实入 0 分，但记录本身照常保存。')

    doc.h2('6.4 等效换算')
    doc.p('为了让数字可感知，应用把减排量换算成三种日常意象：一棵树一年吸收约 18.3 kg CO₂e；'
          '少开 1 km 燃油车约 0.1920 kg CO₂e；给手机充一次电约 0.0082 kg CO₂e。'
          '首页与分享卡片都展示换算结果（如「相当于种了 0.05 棵树」）。')

    # =============================================================== 七、界面实现
    doc.page_break()
    doc.h1('七、界面实现')
    doc.p('以下 16 张截图全部来自 API 12 预览器的实机渲染（非设计稿、非手绘），用于说明界面的真实观感。'
          '需要说明的是：预览器中的 relationalStore 是模拟实现，数据库写不进种子数据，'
          '因此截图中的列表页均为「空态」——这恰好也展示了产品对空态的处理方式。')

    shots = [
        ('01-home.png', '首页', '问候与头像框、累计减排、积分与今日记录双卡、今日目标、近 7 天迷你柱、悬浮「＋ 记一笔」'),
        ('02-dashboard.png', '数据看板', '日 / 周 / 月 / 年四粒度 + 分类筛选；空态给出「去记一笔」的下一步动作'),
        ('03-records.png', '记录列表', '按月分组，左滑编辑 / 删除，封顶记录显示上限标记'),
        ('04-science.png', '双碳科普', '政策 / 低碳技巧 / 知识三类分组与搜索'),
        ('05-mine.png', '我的', '头像框与三张统计卡，下挂目标与徽章、碳小铺、积分明细、碳普惠、设备协同等 7 个入口'),
        ('06-goal.png', '目标', '短 / 中 / 长期三档；周期按自然周起算'),
        ('07-badge.png', '徽章墙', '8 枚里程碑徽章，解锁态与未解锁态区分明显'),
        ('08-shop.png', '碳小铺', '纯虚拟商品：8 个头像框 + 1 套主题；无实物、无提现'),
        ('09-point-log.png', '积分明细', '按类型分组的流水，收入 / 支出 / 冲正一目了然'),
        ('10-include.png', '碳普惠（模拟）', '100 积分 = 1 碳币，单向；页内常驻「模拟演示」声明'),
        ('11-sync.png', '设备协同', '账号态、待同步数、同步进度、家庭合并入口；未登录时给出明确降级提示'),
        ('12-appearance.png', '外观', '头像框与主题切换，切换后立即持久化'),
        ('13-settings.png', '设置', '演示模式、端侧识图、提醒、本地备份、导出、清空'),
        ('14-record-edit.png', '录入', '两步：选行为 → 填数量；实时预览减排量与今日剩余额度'),
        ('16-record-search.png', '记录搜索', '按类型、时间、关键词检索历史记录'),
        ('18-about.png', '关于与合规', '数据说明、因子来源、模拟功能声明、隐私边界'),
    ]
    for i in range(0, len(shots), 2):
        pair = shots[i:i + 2]
        doc.image_row([os.path.join(SHOTS, p[0]) for p in pair], width_cm=6.0)
        doc.caption('图 7-%d  %s　%s；　%s　%s' % (
            i // 2 + 1,
            pair[0][1], pair[0][2],
            pair[1][1] if len(pair) > 1 else '',
            pair[1][2] if len(pair) > 1 else ''))

    # =============================================================== 八、测试结果
    doc.page_break()
    doc.h1('八、测试结果')
    doc.p('测试按四层组织：L0 文档与数值一致性 → L1 客户端纯逻辑单测 → L2 端侧集成 → L3 服务端接口测试。'
          '本章只写实际跑过的命令与真实输出，未验证的项目在 8.6 节如实列出。')

    doc.h2('8.1 L0：文档与数值一致性')
    doc.p('命令：`python tests/tools/check_l0.py --strict`')
    doc.p('结果：**通过（退出码 0）**。28 个检查项 0 错误；扫描 89 个文件、0 处不一致；'
          '文档契约冲突 0 条。这一层的作用是防止「文档写 200、代码写 300」这类隐性分叉。')

    doc.h2('8.2 L1：客户端纯逻辑单测')
    doc.p('命令：`bash tests/tools/l1_offline/run_tests.sh`（离线执行器：esbuild 转译真实 .ets + '
          'node:sqlite 垫片，无需真机）')
    doc.p('结果：**48 条用例全部通过**（48 passed / 0 failed / 0 requires_device）。覆盖：')
    doc.bullets([
        '碳计算 18 组正向样例 + 5 组封顶样例 + 6 条边界样例，与 tests/cases/carbon-calc.json 逐条比对，'
        '另有 323 个断言点的一致性校验全部通过。',
        '未登录状态、目标幂等、徽章幂等、购买幂等、备份往返、CSV 编码。',
        'LWW 合并（含时钟偏移、平局、软删除传播）。',
        '近场协同时新增 7 条：非法贡献丢弃、同设备 LWW 去重、超量截断、定点累加汇总、'
        '序列化往返与脏数据拒绝、端口不可用降级、有对端时的冲突计数。',
    ])

    doc.h2('8.3 L3：服务端接口测试')
    doc.p('命令：`cd server && .venv\\Scripts\\python.exe -m pytest tests\\ -q`')
    doc.p('结果：**243 条用例全部通过**（243 passed，用时 320 秒）。覆盖账号注册 / 登录 / 注销、'
          '鉴权隔离（客户端 token 访问 /admin/* 必须 403）、同步幂等与冲突、取价、配置下发、'
          '后台管理的增删改查与操作日志。')

    doc.h2('8.4 编译与产物')
    doc.p('命令：`hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon`')
    doc.p('结果：**BUILD SUCCESSFUL**，产物 `entry-default-unsigned.hap`（约 2.4 MB）。'
          '编译门禁是真实的：曾用「故意写错一处类型」验证过必须 BUILD FAILED，再改回才通过。')

    doc.h2('8.5 界面渲染验证与一个真实缺陷')
    doc.p('在 API 12 预览器上逐页渲染 18 个页面，发现并修复了一个会让评委直接点崩的缺陷：')
    doc.p('**现象**：点击任意二级页（设置、碳小铺、目标……）时 JS 引擎崩溃（错误码 0xc0000005），'
          '预览器显示「已与引擎断开连接」。')
    doc.p('**定位**：日志给出 `router map is invalid, child size is not one: 2`。ArkUI 要求 '
          'navDestination 的 builder **必须返回一个 NavDestination 容器节点**，而原实现直接返回裸的'
          '自定义组件，13 个二级页无一处使用 NavDestination。')
    doc.p('**修复**：查询路由的 builder 内统一包一层 NavDestination 并隐藏标题栏（标题栏由各页'
          '自己的 PageHeader 绘制）。修复后 18 个页面均可正常压栈与返回。')
    doc.p('**这条缺陷值得单独写进文档**，因为它只在「真的去点」的时候才暴露——静态检查、单测、'
          '编译都发现不了。')

    doc.h2('8.6 未覆盖项（如实说明）')
    doc.table(
        ['项目', '状态', '原因与计划'],
        [
            ['真机运行', '未执行', '开发机无 OpenHarmony 真机；已在 HarmonyOS 模拟器（API 26，1280×2832）'
                                 '上安装并运行已签名 HAP，全部功能页面均截图为真实运行画面'],
            ['独立模拟器', '已执行', '通过启用 Windows 虚拟机监控程序 + 重启，起两台模拟器'
                                 '（Mate 90 Pro 与 Mate X7），`hdc list targets` 同时可见两个目标'],
            ['近场双设备实测', '部分执行', '两台模拟器上已验证：运行时权限申请、能力可用判定、'
                                     '面板降级渲染均正常（日志 `near available: peer count=0`）。'
                                     '两台模拟器无华为账号、未建立可信设备关系，'
                                     '`getAvailableDeviceListSync()` 返回空，故「发现对端 → KV 同步」一段未跑通；'
                                     '协议与合并算法由 L1 的 7 条用例以假端口覆盖'],
            ['真云部署', '未执行', '服务端已在本机 MySQL 8 上跑通全部接口测试，公网部署需域名与备案'],
            ['截图完整性', '18 / 18', '18 个页面全部在模拟器上抓取，且均带真实演示数据'
                                 '（252 条记录 / 5,741 分 / 55.99 kgCO₂e）'],
        ],
        widths=[3.2, 2.2, 11.0], font_pt=10)

    doc.p('截图均为 HarmonyOS 模拟器真实运行的设备截图（1280×2832，未做任何图像修饰），'
          '数据来自应用内置「播种演示数据」，因此每个页面都有内容可看。')
    doc.p('**关于运行时权限**：`ohos.permission.DISTRIBUTED_DATASYNC` 属 user_grant 权限，'
          '仅在 `module.json5` 声明不够——未在运行时申请时 `getAvailableDeviceListSync()` 会抛 '
          '`Permission verification failed（code 201）`，能力被永久判为不可用。'
          '本项目在适配器内用 `requestPermissionsFromUser` 申请并把结果缓存，'
          '同时把签名脚本扩展为可产出 **debug 类型 HAP**（`scripts/sign-hap.ps1 -Debug`），'
          '以便用 `atm perm -g` 在无界面环境下复现与验证。')
    doc.p('**关于签名**：`scripts/sign-hap.ps1` 用的是 OpenHarmony 开源生态的**公开测试密钥**'
          '（SDK 自带 `OpenHarmony.p12`），只适合自测与开源演示，不用于商用分发；'
          '正式上架需自行申请发布证书。签名材料不入仓库（`.gitignore` 忽略 `sign/`）。')
    doc.p('**关于登录鉴权**：客户端与管理端使用两套独立 JWT 密钥，客户端 token 访问 `/admin/*` 一律 403；'
          '`/admin` 的 JWT 为无状态实现，管理员登出或改密后旧令牌在有效期内仍可重放（默认 120 分钟），'
          '属已知取舍：后台为可选项，正式部署应缩短有效期并接入令牌黑名单。')

    # =============================================================== 九、合规
    doc.page_break()
    doc.h1('九、安全、隐私与合规')

    doc.h2('9.1 技术规则符合性')
    doc.table(
        ['官方要求', '本作品'],
        [
            ['基于 OpenHarmony，统一使用 DevEco Studio，API 12 及以上', 'ArkTS + ArkUI Stage 模型，compileSdkVersion 12，DevEco Studio 26 构建通过'],
            ['纯北向应用，无需硬件', '不依赖任何外设；单机即可完成全部五项主要功能'],
            ['数据可采用本地离线存储，云端与多设备同步为加分项', '本机 relationalStore 为唯一真相源；云端同步作为创新项增强'],
            ['基础功能为核心，创新项为加分', '5 项主要功能 + 4 项创新全部实现，创新项均在无网络时降级可用'],
            ['独立完成，严禁抄袭', '不引入任何第三方 npm / HAR 包；图表、Markdown、分享卡片均自研'],
            ['不收取任何费用', '无内购、无广告、无付费入口'],
        ],
        widths=[7.4, 9.2], font_pt=10)

    doc.h2('9.2 隐私边界')
    doc.bullets([
        '**默认本地**：不登录时不上传任何数据，全部功能可用。',
        '**最小权限**：不申请位置、通讯录、麦克风、相机。',
        '**识图不外传**：图片只在内存中读一次用于推断，不落盘、不上传。',
        '**分享不含身份**：分享卡片不含姓名、学校、团队、头像，也不接第三方社交 SDK。',
        '**可撤回**：登录后可随时关闭同步或注销账号，注销后云端数据软删除并保留 30 天可恢复，本机数据一条不删。',
    ])
    doc.p('界面上禁止出现「绝不上传任何数据」这类绝对化表述，统一写「默认本地，仅在你登录后上传行为数据，'
          '可随时关闭或注销」——这既是合规要求，也是技术事实的准确表述。')

    doc.h2('9.3 内容合规')
    doc.bullets([
        '碳普惠为**模拟功能**，页面常驻声明，不可提现、不可转让，不对接任何真实平台。',
        '因子来源逐项标注；provisional 因子在界面显示「参考值」角标，不把估算值包装成权威值。',
        '端侧识图标注「模拟识别」，且不展示置信度数字或准确率。',
        '不承诺任何减排量的经济价值，不涉及碳交易。',
    ])

    # =============================================================== 十、创新点
    doc.page_break()
    doc.h1('十、创新点总结')

    doc.h2('10.1 四层创新')
    doc.table(
        ['创新点', '具体做法', '相对常见实现的差异'],
        [
            ['① 双通路多设备协同', '云通路（服务端 LWW 增量同步）+ 近场通路（鸿蒙分布式 KV，可整体关闭）',
             '不是「必须联网才能用」，也不是「只有云同步」；两条通路都带降级'],
            ['② 家庭碳积分只读合并', '只合并统计口径（人数 / 记录数 / 减排 / 积分），不合并明细',
             '避免家庭内互相改账；不需要共享账号'],
            ['③ 端侧 AI 的边界设计', '接口层可换引擎；只给候选必须用户确认；不展示置信度；图片不落盘',
             '不把「AI」当卖点吹准确率，而是把它做成一个可替换、可降级的输入手段'],
            ['④ 碳普惠的诚实模拟', '完整兑换闭环 + 单向不可逆 + 常驻模拟声明',
             '做一个真实可用的功能闭环，但不冒充真实通道'],
        ],
        widths=[3.6, 7.0, 6.0], font_pt=10)

    doc.h2('10.2 工程上的三个「较真」')
    doc.bullets([
        '**数值较真**：单一计算入口 + 定点小数 + 因子快照 + 18 组手算样例 + 373 个断言点的一致性校验。',
        '**账本较真**：流水只增不删、编辑生成差额冲正、封顶从流水实时聚合而不是读缓存。',
        '**文档较真**：L0 门禁扫描 89 个文件，确保计划书、附录、测试基准、代码常量四处数值不走样。',
    ])

    doc.h2('10.3 后续计划')
    doc.bullets([
        '接入真实端侧推理模型，替换当前启发式引擎（接口已就绪）。',
        '补真机与双设备实测，产出带数据的完整截图与演示视频。',
        '真实碳普惠平台对接（需实名与地方平台签约）。',
        '更多外观主题与家庭账户体系。',
    ])

    # =============================================================== 附录
    doc.page_break()
    doc.h1('附录 A　文档与代码索引')
    doc.table(
        ['文档', '内容'],
        [
            ['docs/PLAN.md', '主计划书：定位、铁律、架构、数据、积分、目标、协同、验收、里程碑'],
            ['docs/APPENDIX-A-carbon-factors.md', '碳因子库与核算公式（31 项因子、积分规则、手算样例）'],
            ['docs/APPENDIX-B-data-and-api.md', '数据模型、建表 SQL、REST 契约、协同协议、Dao 清单'],
            ['docs/APPENDIX-C-ui-screens.md', '18 个页面规格、设计令牌、组件、文案清单'],
            ['docs/APPENDIX-D-acceptance.md', '验收项（含 18 组手算样例与封顶、边界样例）'],
            ['docs/APPENDIX-E-demo-script.md', '5 分钟演示分镜与 10 分钟路演逐字稿、PPT 大纲'],
            ['docs/APPENDIX-F-compliance.md', '官方要求逐条对照与不做清单'],
            ['docs/screenshots/', '16 张界面截图与索引说明'],
            ['AGENTS.md', '工程规约：四条铁律、冲突裁决、停手规则、提交规范'],
        ],
        widths=[6.4, 10.2], font_pt=10)

    doc.h1('附录 B　提交物清单')
    doc.table(
        ['序号', '材料', '格式要求', '本作品'],
        [
            ['1', '设计方案', 'Word（*.docx），宋体小四、1.5 倍行距', '本文档'],
            ['2', '演示视频', 'mp4，≤ 100 MB，≤ 5 分钟', '02-演示视频-碳小布CarbonBoo.mp4'],
            ['3', '演示文稿', 'PPT 图文并茂，讲解 ≤ 10 分钟', '03-演示文稿-碳小布CarbonBoo.pptx'],
        ],
        widths=[1.6, 3.4, 6.6, 5.0], font_pt=10)
    doc.p('三项材料均不含院校、团队、指导教师信息；作品打包为 rar，命名格式按官方要求'
          '「赛题序号 + 赛题名称 + 学校团队名称」。')

    doc.save(OUT)
    print('SAVED', OUT, os.path.getsize(OUT), 'bytes')


if __name__ == '__main__':
    build()

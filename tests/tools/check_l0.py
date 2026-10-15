#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L0 检查器：碳计算数值自检 + 文档已知冲突扫描。

用途（AGENTS.md §5）：
  1. 用 tests/cases/carbon-calc.json 里的样例，独立重算一遍
     减排量 / 应得积分 C / 实入积分 A，确认这个"测试基准"本身没算错；
  2. 扫描 docs/ 里已知的错误数值与错误名字，输出待修清单。

运行：
  python3 tests/tools/check_l0.py            # 报告模式：列出问题，退出码 0
  python3 tests/tools/check_l0.py --strict   # 门禁模式：有问题即退出码 1

退出码：0 通过；1 文档仍存在待修项（仅 --strict）；2 基准文件自身算错（任何时候都是错误）
"""

from __future__ import annotations

import argparse
import json
import sys
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CASES_PATH = REPO / "tests" / "cases" / "carbon-calc.json"
DOCS = REPO / "docs"


# ---------------------------------------------------------------- 数值工具
def dec(x) -> Decimal:
    return Decimal(str(x))


def round_half_up(x: Decimal, places: int) -> Decimal:
    return x.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)


# ---------------------------------------------------------------- 文档扫描规则
# 每条：在 path 指向的文件里搜索 pattern，命中即报告。
DOC_SCAN = [
    {
        "id": "B8",
        "glob": "APPENDIX-C-ui-screens.md",
        "pattern": r"0\.5777|5\.7770|\+578|应得 578",
        "fix": "电网因子统一 0.5703（10 kWh → 5.7030 kg → 570 分）",
    },
    {
        "id": "B9",
        "glob": "*.md",
        "pattern": r"10 个目标|目标体系（10|目标总表（10|目标（10 个",
        "fix": "目标数统一为 11（5 短期 + 5 中长期 + 1 长期）",
    },
    {
        "id": "B10",
        "glob": "APPENDIX-C-ui-screens.md",
        "pattern": r"数据来源\s+GB/T 51366|可信度\s+verified",
        "fix": "骑行/步行的因子快照应为 SRC-DERIVED / provisional",
    },
    {
        "id": "B12",
        "glob": "*.md",
        "pattern": r"ohos\.permission\.REMINDER_AGENT",
        "fix": "改为 ohos.permission.PUBLISH_AGENT_REMINDER",
    },
    {
        "id": "B13",
        "glob": "APPENDIX-C-ui-screens.md",
        "pattern": r"时间\s+19:00",
        "fix": "提醒时间统一 20:00",
    },
    {
        "id": "B14",
        "glob": "*.md",
        "pattern": r"rawfile/science/index\.json",
        "fix": "统一为 rawfile/science/science-index.json",
    },
    {
        "id": "B15",
        "glob": "APPENDIX-C-ui-screens.md",
        "pattern": r"carbonboo-backup-YYYYMMDD\.json",
        "fix": "备份文件名需带 HHmm",
    },
    {
        "id": "B7",
        "glob": "APPENDIX-D-acceptance.md",
        "pattern": r"\+600 分",
        "fix": "改为「应得 600 分 / 实入 200 分（触发日封顶）」",
    },
    {
        "id": "B19",
        "glob": "*.md",
        "pattern": r"_tmp_notice\.txt|_tmp_train\.txt",
        "fix": "补齐取证文本或删除该引用（当前无法在仓库内复核官方原文）",
    },
    {
        "id": "B1",
        "glob": "*.md",
        "pattern": r"AND source_type IN \('record'",
        "fix": "封顶聚合必须过滤 source_type = 'carbon_record'（record/record_capped 是 type 的枚举值，用错列会让封顶永不生效）",
    },
    {
        "id": "B2",
        "glob": "*.md",
        "pattern": r"封顶聚合排除已删流水",
        "fix": "冲正（reverse）必须计入当日已得 D，否则删记录不释放额度",
    },
    {
        "id": "B4",
        "glob": "*.md",
        "pattern": r"^\s*day_key\s+TEXT PRIMARY KEY",
        "fix": "point_daily_stat 主键必须是 (user_id, day_key)，否则演示数据与真实用户同日互相覆盖",
    },
]


def run_fixture_checks(data: dict) -> tuple[list[str], int]:
    """重算 fixture 自身。返回 (错误列表, 检查项数量)。"""
    errors: list[str] = []
    checks = 0

    cap = dec(data["meta"]["dailyRecordCap"])
    factors = {f["key"]: dec(f["value"]) for f in data["factors"]}

    # 1) 换算
    for conv in data.get("conversions", []):
        checks += 1
        inp, exp = conv["input"], conv["expect"]
        if conv["id"] == "car-free-days":
            got = dec(inp["days"]) * dec(inp["kmPerDay"])
        elif conv["id"] == "recycle-by-piece":
            got = dec(inp["pieces"]) * dec(inp["kgPerPiece"])
        else:
            errors.append(f"未知换算 id：{conv['id']}")
            continue
        if got != dec(exp["amount"]):
            errors.append(
                f"换算 {conv['id']}：算得 {got}，期望 {exp['amount']}"
            )

    # 2) 18 组正向样例
    for s in data["samples"]:
        checks += 1
        fk = s["factorKey"]
        if fk not in factors:
            errors.append(f"样例 {s['id']}：因子 {fk} 不在 factors 表中")
            continue
        reduction = round_half_up(dec(s["amount"]) * factors[fk], 4)
        point_c = int(round_half_up(reduction * 100, 0))
        if reduction != dec(s["expectedReductionKg"]):
            errors.append(
                f"样例 {s['id']}（{s['behavior']}）：减排量算得 {reduction}，"
                f"期望 {s['expectedReductionKg']}"
            )
        if point_c != s["expectedPointC"]:
            errors.append(
                f"样例 {s['id']}（{s['behavior']}）：应得积分算得 {point_c}，"
                f"期望 {s['expectedPointC']}"
            )

    # 3) 封顶样例
    for s in data["capSamples"]:
        checks += 1
        d, c = dec(s["todayEarnedD"]), dec(s["expectedC"])
        a = max(Decimal(0), min(c, cap - d)) if s.get("countsTowardCap", True) else c
        if a != dec(s["expectedActualA"]):
            errors.append(
                f"封顶样例 {s['id']}：实入算得 {a}，期望 {s['expectedActualA']}"
            )
        if s["capped"] != (1 if a < c else 0):
            errors.append(
                f"封顶样例 {s['id']}：capped 应为 {1 if a < c else 0}，"
                f"期望 {s['capped']}"
            )

    # 4) 边界样例（带数值的那些）
    for s in data["boundarySamples"]:
        if "reductionKg" in s:
            checks += 1
            got = int(round_half_up(dec(s["reductionKg"]) * 100, 0))
            if got != s["expectedPointC"]:
                errors.append(
                    f"边界样例 {s['id']}：应得积分算得 {got}，期望 {s['expectedPointC']}"
                )
        if "factorKey" in s and "expectedReductionKg" in s:
            checks += 1
            reduction = round_half_up(
                dec(s["amount"]) * factors[s["factorKey"]], 4
            )
            if reduction != dec(s["expectedReductionKg"]):
                errors.append(
                    f"边界样例 {s['id']}：减排量算得 {reduction}，"
                    f"期望 {s['expectedReductionKg']}"
                )
            if "todayEarnedD" in s:
                expected_a = max(
                    Decimal(0),
                    min(dec(s["expectedPointC"]), cap - dec(s["todayEarnedD"])),
                )
                if expected_a != dec(s["expectedActualA"]):
                    errors.append(
                        f"边界样例 {s['id']}：实入算得 {expected_a}，"
                        f"期望 {s['expectedActualA']}"
                    )

    return errors, checks


def doc_targets() -> list[Path]:
    """被扫描的文档：docs/*.md（排除决策记录与规约本身）+ 仓库根 README.md。"""
    targets: list[Path] = []
    if DOCS.is_dir():
        for path in sorted(DOCS.glob("*.md")):
            if path.name.startswith("DECISION-") or path.name == "AGENTS.md":
                continue  # 决策记录/规约里会引用旧值，不算冲突
            targets.append(path)
    root_readme = REPO / "README.md"
    if root_readme.is_file():
        targets.append(root_readme)
    return targets


def run_doc_scan() -> tuple[list[tuple[str, str, int, str, str]], int]:
    """扫描文档。返回 (命中列表, 扫描文件数)。"""
    import re

    hits: list[tuple[str, str, int, str, str]] = []
    scanned = 0
    targets = doc_targets()
    if not targets:
        return hits, scanned

    for rule in DOC_SCAN:
        rx = re.compile(rule["pattern"])
        for path in targets:
            if rule["glob"] != "*.md" and path.name != rule["glob"]:
                continue
            scanned += 1
            for lineno, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(), start=1
            ):
                if rx.search(line):
                    try:
                        shown = str(path.relative_to(REPO))
                    except ValueError:
                        shown = str(path)
                    hits.append(
                        (rule["id"], shown, lineno, line.strip()[:90], rule["fix"])
                    )
    return hits, scanned


def main() -> int:
    ap = argparse.ArgumentParser(description="CarbonBoo L0 检查")
    ap.add_argument("--strict", action="store_true", help="有任何问题则退出码 1")
    args = ap.parse_args()

    if not CASES_PATH.is_file():
        print(f"[FATAL] 找不到基准文件：{CASES_PATH}")
        return 2

    data = json.loads(CASES_PATH.read_text(encoding="utf-8"))

    print("=" * 72)
    print("L0-1 数值基准自检（tests/cases/carbon-calc.json）")
    print("=" * 72)
    errors, checks = run_fixture_checks(data)
    print(f"检查项：{checks}    错误：{len(errors)}")
    for e in errors:
        print(f"  [ERROR] {e}")
    if not errors:
        print("  OK：18 组正向样例 / 5 组封顶 / 边界样例全部自洽")

    print()
    print("=" * 72)
    print("L0-2 文档已知冲突扫描（docs/）")
    print("=" * 72)
    hits, scanned = run_doc_scan()
    print(f"扫描文件：{scanned}    命中：{len(hits)}")
    for rule_id, name, lineno, text, fix in hits:
        print(f"  [{rule_id}] {name}:{lineno}  {text}")
        print(f"          应改为：{fix}")

    open_conflicts = [c for c in data.get("docConflicts", []) if c["status"] == "open"]
    print()
    print(f"L0-3 人工待修清单（tests/cases/carbon-calc.json → docConflicts）：{len(open_conflicts)} 条")
    for c in open_conflicts:
        print(f"  [{c['id']}] {c['file']} {c['locator']}")
        print(f"       现状：{c['bad']}")
        print(f"       期望：{c['correct']}")

    print()
    print("=" * 72)
    if errors:
        print("结论：FAIL —— 数值基准自身有问题，必须先修基准文件（退出码 2）")
        return 2
    if hits or open_conflicts:
        print(
            f"结论：基准 OK；文档仍有 {len(hits)} 处自动命中 + "
            f"{len(open_conflicts)} 条待修项（AGENTS.md §1.4 清零前不得声称对应验收通过）"
        )
        return 1 if args.strict else 0
    print("结论：PASS —— 基准自洽，文档无已知冲突")
    return 0


if __name__ == "__main__":
    sys.exit(main())

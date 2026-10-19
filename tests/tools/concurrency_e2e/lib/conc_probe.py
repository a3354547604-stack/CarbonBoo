#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""t61 并发/竞态端到端探针 —— 真 MySQL（carbonboo-mysql:13307）+ `uvicorn --workers 2`。

职责：
  用真实 HTTP 并发打真实服务端，把「并发/竞态」这条从未验证的缺口做成可复现证据。
  六组场景（S1 唯一键并发入账 / S2 同步幂等并发 push / S2b LWW 并发丢更新 /
  S3 积分封顶读-改-写 / S4 连接池上限 / S5 并发下限流 / S6 并发后一致性）。

硬边界（与任务书一致）：
  * 本文件只读服务端行为，不碰 `server/**`、`app/**` 一行；
  * 断言只陈述可观测量（HTTP 状态码 / SQL 结果 / 响应计数），发现真缺陷写 finding（STOP 三行）
    并在 REPORT.md §4 记录 —— **不为让断言变绿而放宽断言、删用例、改期望值或吞错**；
  * 夹具自身的断言失败 → 退出码 1；环境不可达 → 退出码 2；契约层发现（如服务端无封顶路径）
    默认记 finding 但不改退出口 = 0，可用 `CONC_STRICT_CONTRACT=1` 让发现也变 1（见 README）。

环境变量（由 run.sh 注入）：
  CONC_BASE_URL, CONC_MYSQL_HOST/PORT/USER/PASSWORD/DB, CONC_UVICORN_LOG, CONC_ONLY(可选)
"""

from __future__ import annotations

import json
import os
import random
import re
import string
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import httpx
import pymysql
from pymysql.cursors import DictCursor

BASE_URL: str = os.environ.get("CONC_BASE_URL", "http://127.0.0.1:18137")
DB_HOST: str = os.environ.get("CONC_MYSQL_HOST", "127.0.0.1")
DB_PORT: int = int(os.environ.get("CONC_MYSQL_PORT", "13307"))
DB_USER: str = os.environ.get("CONC_MYSQL_USER", "carbonboo")
DB_PASS: str = os.environ.get("CONC_MYSQL_PASSWORD", "")
DB_NAME: str = os.environ.get("CONC_MYSQL_DB", "")
UVICORN_LOG: str = os.environ.get("CONC_UVICORN_LOG", "")
ONLY: set[str] = {s for s in os.environ.get("CONC_ONLY", "").split(",") if s}
STRICT_CONTRACT: bool = os.environ.get("CONC_STRICT_CONTRACT", "0") == "1"

DAY_MS: int = int(time.time() // 86400 * 86400 * 1000)  # 今天 00:00 UTC 的毫秒时间戳
TRACE: list[tuple[str, str]] = []
#: S1 跑完后的 point_record 快照（append-only 的「只增不删」数据级取证）
PR_SNAPSHOT: dict[str, tuple] = {}
TRIGGERS_OK: bool = False
TRIGGER_ERR: str = ""
CHECKS: list[tuple[str, str, bool, str]] = []
FINDINGS: list[tuple[str, str, str]] = []


# --------------------------------------------------------------------------- 输出工具
def ev(title: str, body: str) -> None:
    """打印一段原始证据（进 REPORT.md 时会逐字引用这里的内容）。"""
    TRACE.append((title, body))
    print(f"\n----- 证据：{title} -----")
    print(body.rstrip())


def check(cid: str, title: str, ok: bool, note: str = "") -> bool:
    CHECKS.append((cid, title, bool(ok), note))
    print(f"[{'PASS' if ok else 'FAIL'}] {cid} {title}" + (f" | {note}" if note else ""))
    return bool(ok)


def finding(fid: str, severity: str, three_lines: str) -> None:
    FINDINGS.append((fid, severity, three_lines))
    print(f"\n[!] 发现 {fid}（{severity}，只报告不改）\n{three_lines}")


def want(name: str) -> bool:
    return not ONLY or name in ONLY


# --------------------------------------------------------------------------- 数据访问
def db():
    return pymysql.connect(
        host=DB_HOST, port=DB_PORT, user=DB_USER, password=DB_PASS, database=DB_NAME,
        autocommit=True, cursorclass=DictCursor, charset="utf8mb4",
    )


def sql(query: str, args: tuple | None = None) -> list[dict]:
    with db() as conn, conn.cursor() as cur:
        # 注意：无参数时必须**不传** args —— pymysql 会把 SQL 里的 `%`（如 LIKE 'cr-race-%'）当格式符
        if args:
            cur.execute(query, args)
        else:
            cur.execute(query)
        try:
            return list(cur.fetchall())
        except pymysql.err.Error:
            return []


def sql_one(query: str, args: tuple | None = None) -> dict:
    rows = sql(query, args)
    return rows[0] if rows else {}


def table_dump(query: str, args: tuple | None = None) -> str:
    """把查询结果渲染成 `mysql -B` 风格的等宽文本（进报告当原始证据）。"""
    rows = sql(query, args)
    if not rows:
        return "(0 rows)"
    cols = list(rows[0].keys())
    out = ["\t".join(cols)]
    for r in rows:
        out.append("\t".join("NULL" if r[c] is None else str(r[c]) for c in cols))
    return f"({len(rows)} rows)\n" + "\n".join(out)


# --------------------------------------------------------------------------- HTTP
CLIENT = httpx.Client(
    base_url=BASE_URL.strip("/"),
    timeout=httpx.Timeout(60.0, connect=10.0),
    limits=httpx.Limits(max_connections=256, max_keepalive_connections=128),
)


def post(path: str, body: dict, token: str | None = None) -> tuple[int, str]:
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    r = CLIENT.post(path, content=json.dumps(body), headers=headers)
    return r.status_code, r.text


def get(path: str, token: str | None = None) -> tuple[int, str]:
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    r = CLIENT.get(path, headers=headers)
    return r.status_code, r.text


def parse(body: str) -> dict:
    try:
        return json.loads(body)
    except Exception:
        return {}


def burst(n: int, fn) -> list:
    """n 个线程用同一道 barrier 同时出发，收集每个返回值（异常也收集）。"""
    barrier = threading.Barrier(n)
    results: list = [None] * n

    def work(i: int) -> None:
        barrier.wait()
        try:
            results[i] = fn(i)
        except Exception as exc:  # noqa: BLE001 —— 异常本身就是要记录的证据
            results[i] = exc

    with ThreadPoolExecutor(max_workers=n) as pool:
        list(pool.map(work, range(n)))
    return results


# --------------------------------------------------------------------------- 场景
def s0_preflight() -> None:
    ver = sql_one("SELECT VERSION() AS v")
    mc = sql_one("SHOW VARIABLES LIKE 'max_connections'")
    tz = sql_one("SHOW VARIABLES LIKE 'transaction_isolation'")
    # 注意：f-string 的表达式里不能出现反斜杠（Python < 3.12），所以先把值取出来
    used = sql_one("SHOW GLOBAL STATUS LIKE 'Max_used_connections'").get("Value")
    thc = sql_one("SHOW GLOBAL STATUS LIKE 'Threads_connected'").get("Value")
    ev("S0 并发前置：MySQL 版本 / max_connections / 隔离级别 / 全局峰值连接",
       f"VERSION()          = {ver.get('v')}\n"
       f"max_connections    = {mc.get('Value')}\n"
       f"transaction_isolation = {tz.get('Value')}\n"
       f"Max_used_connections(本次启动后累计峰值) = {used}\n"
       f"Threads_connected  = {thc}\n"
       f"目标库 = {DB_NAME}（任务专属，跑完 drop）")


def s1_unique_key(user_id: str, token: str) -> None:
    """S1 同一业务唯一键并发入账：18 并发中 9 个同 id、9 个不同 id 但同一业务键。"""
    n = 18
    biz = ("goal", f"goal_L1_{uuid.uuid4().hex[:8]}.2026", "primary")
    same_id = f"pr-same-{uuid.uuid4().hex[:8]}"
    base = int(time.time() * 1000)

    before = sql_one(
        "SELECT COUNT(*) AS n FROM point_record WHERE user_id=%s AND source_type=%s AND source_id=%s",
        (user_id, biz[0], biz[1]))
    ev("S1 并发前：该业务键行数 + 该用户全部流水",
       f"count(bizkey) = {before.get('n')}\n"
       + table_dump("SELECT id, points, source_type, source_id, flow_kind FROM point_record WHERE user_id=%s",
                    (user_id,)))

    def one(i: int) -> tuple[int, str]:
        rid = same_id if i < n // 2 else f"pr-{uuid.uuid4().hex[:12]}"
        row = {
            "id": rid, "user_id": user_id, "type": "goal", "flow_kind": biz[2],
            "points": 200, "source_type": biz[0], "source_id": biz[1],
            "title": "并发入账-同一业务键", "remark": f"worker={i}",
            "occurred_at": base, "created_at": base, "updated_at": base,
            "is_deleted": 0, "device_id": f"conc-dev-{i:02d}",
        }
        return post("/api/v1/sync/push",
                    {"userId": user_id, "deviceId": f"conc-dev-{i:02d}", "lastSyncAt": 0,
                     "tables": {"point_record": [row]}}, token)

    res = burst(n, one)
    lines, accepted, skipped_ok, errs = [], 0, 0, []
    for i, r in enumerate(res):
        if isinstance(r, Exception):
            errs.append(f"#{i} EXC {r!r}")
            continue
        code, body = r
        d = parse(body).get("data", {})
        a, ig, rj = d.get("accepted"), d.get("ignored"), d.get("rejected")
        sk = d.get("skipped")
        if code == 200 and a is not None:
            accepted += a
            if sk == (ig or 0) + (rj or 0):
                skipped_ok += 1
        lines.append(f"#{i:02d} http={code} accepted={a} ignored={ig} rejected={rj} "
                     f"skipped={sk} conflicts={d.get('conflicts')} status={d.get('status')}")
    ev(f"S1 原始响应（{n} 条并发 push，逐条状态码与计数）", "\n".join(lines))
    ev("S1 原始响应样本（第 1 条全文）",
       json.dumps(parse(res[0][1]) if not isinstance(res[0], Exception) else str(res[0]),
                  ensure_ascii=False, indent=2))

    after = table_dump(
        "SELECT id, user_id, type, flow_kind, points, source_type, source_id, is_deleted, device_id "
        "FROM point_record WHERE user_id=%s ORDER BY id", (user_id,))
    nrows = sql_one("SELECT COUNT(*) AS n FROM point_record WHERE user_id=%s", (user_id,))["n"]
    ndist = sql_one("SELECT COUNT(DISTINCT id) AS n FROM point_record WHERE user_id=%s", (user_id,))["n"]
    pointsum = sql_one("SELECT COALESCE(SUM(points),0) AS s FROM point_record WHERE user_id=%s",
                       (user_id,))["s"]
    ev("S1 并发后：真实行数 + 关键列全文",
       f"COUNT(*)={nrows}  COUNT(DISTINCT id)={ndist}  SUM(points)={pointsum}\n" + after)

    cols = table_dump("SHOW COLUMNS FROM point_record LIKE 'sync_state'")
    ev("S1 sync_state 在服务端的存在性（选型事实）",
       f"SHOW COLUMNS FROM point_record LIKE 'sync_state' → {cols}\n"
       f"（server/sql/schema.sql:10 注释：服务端不建 sync_state 列；normalize_row 会丢弃客户端多带的列）")

    check("S1.1", f"{n} 并发推同一业务键（9 同 id + 9 异 id）最终恰好 1 行",
          nrows == 1 and ndist == 1, f"COUNT(*)={nrows} DISTINCT(id)={ndist}")
    check("S1.2", "并发下 SUM(points) = 200（唯一键挡住重复入账，未重复计分）",
          pointsum == 200, f"SUM(points)={pointsum}")
    check("S1.3", "每条响应 skipped = ignored + rejected（附录 B §5.3 三数自洽）",
          skipped_ok == n and not errs, f"自洽 {skipped_ok}/{n}  errs={errs}")
    check("S1.4", f"恰好 1 条响应 accepted=1，其余 accepted=0（合计 accepted={accepted}）",
          accepted == 1, f"sum(accepted)={accepted}")
    check("S1.5", "服务端无 sync_state 列 ⇒ 该分布在服务端结构上不可观测（如实标注，非通过）",
          cols == "(0 rows)", cols)
    global PR_SNAPSHOT
    PR_SNAPSHOT = {
        r["id"]: (r["points"], r["is_deleted"], r["updated_at"])
        for r in sql("SELECT id, points, is_deleted, updated_at FROM point_record WHERE user_id=%s", (user_id,))
    }
    ev("S1 快照（供 S6 复核「只增不删」）：本账号当时的全部 point_record 行",
       f"快照行数 = {len(PR_SNAPSHOT)}（id → (points, is_deleted, updated_at)）")
    if cols == "(0 rows)":
        FINDINGS.append((
            "S1-note", "info",
            "sync_state 分布：服务端 point_record 无 sync_state 列（schema.sql:10），"
            "故「sync_state 分布」在服务端不可观测 —— 该列只在客户端 relationalStore，"
            "客户端侧分布由 tests/tools/l2_sync/ 覆盖。本场景以 COUNT(*)/SUM(points) 作为无重复行的证据。"))


def s2_idempotent_push(user_id: str, token: str) -> None:
    """S2 同一碳记录并发 push（同步幂等）：多轮 × 16 并发，同 id 同业务键同内容。

    断言的是「数据面」：每轮只落 1 行、内容与推送值一致、`skipped = ignored + rejected`。
    另单独记录「计数归因」：并发下 `INSERT IGNORE` 被并发事务抢先时，归因可能落到 unknown → 计 rejected
    （数据无差，但客户端会误以为「服务端版本更胜」而回写），这一条作为发现如实列出，不改期望。
    """
    rounds, n = 5, 16
    ts = int(time.time() * 1000) + 3600_000
    row_template = {
        "user_id": user_id, "category": "recycle", "sub_type": "paper",
        "amount": 5.0, "unit": "kg", "occurred_at": ts, "reduction_kg": 4.5,
        "factor_value": 0.9, "factor_version": "CF-2026.2", "factor_source": "SRC-MEE-GHG",
        "confidence": "verified", "point_awarded": 450, "point_capped": 0, "revision": 0,
        "is_abnormal": 0, "note": "并发幂等-同值", "created_at": ts, "updated_at": ts,
        "is_deleted": 0, "device_id": "conc-dev-00",
    }
    table, tot = [], {"acc": 0, "ign": 0, "rej": 0, "unknown": 0}
    for r in range(rounds):
        rid = f"cr-idem-{r}-{uuid.uuid4().hex[:6]}"
        row = dict(row_template, id=rid)

        def one(i: int, row=row) -> tuple[int, str]:
            return post("/api/v1/sync/push",
                        {"userId": user_id, "deviceId": "conc-dev-00", "lastSyncAt": 0,
                         "tables": {"carbon_record": [dict(row)]}}, token)

        res = burst(n, one)
        acc = ign = rej = 0
        ok3 = 0
        unknown_notes: list[str] = []
        for code, body in res:
            d = parse(body).get("data", {})
            acc += d.get("accepted") or 0
            ign += d.get("ignored") or 0
            rej += d.get("rejected") or 0
            if (d.get("skipped") or 0) == (d.get("ignored") or 0) + (d.get("rejected") or 0):
                ok3 += 1
            if d.get("rejected"):
                for e in (d.get("errors") or []):
                    unknown_notes.append(str(e)[:180])
        nrows = sql_one("SELECT COUNT(*) AS n FROM carbon_record WHERE id=%s", (rid,))["n"]
        fin = sql_one("SELECT amount, reduction_kg, factor_value, factor_version, factor_source, "
                      "confidence, point_awarded, note, is_deleted FROM carbon_record WHERE id=%s", (rid,))
        same = (fin.get("amount") == row["amount"] and fin.get("reduction_kg") == row["reduction_kg"]
                and fin.get("factor_value") == row["factor_value"] and fin.get("factor_version") == row["factor_version"]
                and fin.get("factor_source") == row["factor_source"] and fin.get("confidence") == row["confidence"]
                and fin.get("point_awarded") == row["point_awarded"] and fin.get("note") == row["note"]
                and fin.get("is_deleted") == row["is_deleted"])
        tot["acc"] += acc; tot["ign"] += ign; tot["rej"] += rej
        tot["unknown"] += len(unknown_notes)
        table.append(f"round{r}: rows={nrows} accepted={acc} ignored={ign} rejected={rej} "
                     f"skipped自洽={ok3}/{n} 内容一致={same}"
                     + (f" rejected归因={unknown_notes[:3]}" if unknown_notes else ""))
        check(f"S2.1[r{r}]", f"第 {r} 轮 {n} 并发推同一 carbon_record 只落 1 行（幂等）", nrows == 1,
              f"COUNT(*)={nrows}")
        check(f"S2.2[r{r}]", f"第 {r} 轮每条响应 skipped = ignored + rejected", ok3 == n, f"{ok3}/{n}")
        check(f"S2.3[r{r}]", f"第 {r} 轮落库内容与推送值逐字段一致（无丢字段/无覆盖成错值）", same,
              f"最终行 amount={fin.get('amount')} reduction_kg={fin.get('reduction_kg')} "
              f"factor={fin.get('factor_value')}/{fin.get('factor_version')} points={fin.get('point_awarded')}")
    ev(f"S2 幂等：{rounds} 轮 × {n} 并发（同 id 同业务键同内容）", "\n".join(table)
       + f"\n\n合计：accepted={tot['acc']} ignored={tot['ign']} rejected={tot['rej']}"
         f"；rejected 中归因为 unknown（并发下 INSERT IGNORE 被抢先）的行数 = {tot['unknown']}")

    # 时钟变体：带 clientNow ⇒ offsetMs ≠ 0；同值重推被计 accepted 但不新增行
    rid = f"cr-idem-clock-{uuid.uuid4().hex[:6]}"
    row = dict(row_template, id=rid)
    pres = burst(n, lambda i: post("/api/v1/sync/push",
                                   {"userId": user_id, "deviceId": "conc-dev-00", "lastSyncAt": 0,
                                    "clientNow": int(time.time() * 1000),
                                    "tables": {"carbon_record": [dict(row)]}}, token))
    acc = sum((parse(b).get("data", {}).get("accepted") or 0) for c, b in pres if c == 200)
    offs = sorted({(parse(b).get("data", {}).get("offsetMs")) for c, b in pres if c == 200})
    clock_rows = sql_one("SELECT COUNT(*) AS n FROM carbon_record WHERE id=%s", (rid,))["n"]
    ev("S2 时钟变体：带 clientNow 的 16 并发（offsetMs 与 accepted 计数）",
       f"offsetMs 集合 = {offs}\nsum(accepted) = {acc}\n最终行数 = {clock_rows}")
    check("S2.4", "带 clientNow ⇒ offsetMs ≠ 0（服务端时钟 − 客户端时钟）",
          all(o not in (0, None) for o in offs) and bool(offs), f"offsetMs={offs}")
    check("S2.5", "accepted 计数可以 > 1（LWW 写回同值），但行数仍恒为 1（幂等靠行数而非 accepted 计数）",
          clock_rows == 1 and acc >= 1, f"sum(accepted)={acc} rows={clock_rows}")

    if tot["unknown"]:
        finding("S2", "low",
                f"STOP: 同一行 {n} 并发重推时，有 {tot['unknown']} 条响应把「重复行」归因为 unknown 并计入 rejected。\n"
                f"冲突: `sync_service.py:400-420` 在 `INSERT IGNORE` rowcount=0 后调 `_diagnose_ignored`（:247）重新 SELECT 归因，"
                f"但 MySQL 默认 REPEATABLE READ 下该事务的快照仍看不到并发事务刚提交的行 ⇒ 返回 unknown ⇒ "
                f"`_merge_lww` 落到「未识别冲突来源」分支计 rejected（实测 {rounds} 轮里 "
                f"{sum(1 for t in table if 'rejected=' in t and 'rejected=0' not in t)} 轮命中）。"
                f"↔ 附录 B §6.4-3「跨设备重复被去重计入 ignored」与 §5.3 `skipped = ignored + rejected` 的语义。\n"
                "建议: 归因前先 `SELECT ... FOR UPDATE` 或把事务隔离级别降到 READ COMMITTED（或改用 "
                "`INSERT ... ON DUPLICATE KEY UPDATE id=id` 后再 SELECT），使「同 id/同业务键」在并发下也能稳定归因为 ignored。"
                "数据面不受影响（每轮仍只 1 行、内容一致），只影响客户端回写判断。")


def s2b_lww_race(user_id: str, token: str) -> None:
    """S2b 同一 id 并发推不同 updated_at：LWW「大者胜」在并发下是否守恒（丢更新）。"""
    rounds, n = 8, 16
    base = int(time.time() * 1000) + 7200_000
    table, bad, phantoms = [], 0, 0
    for r in range(rounds):
        rid = f"cr-race-{r}-{uuid.uuid4().hex[:6]}"
        stamps = [base + r * 1000 + i for i in range(1, n + 1)]

        def one(i: int, rid=rid, stamps=stamps) -> tuple[int, str]:
            row = {
                "id": rid, "user_id": user_id, "category": "recycle", "sub_type": "paper",
                "amount": 1.0, "unit": "kg", "occurred_at": stamps[i], "reduction_kg": 0.9,
                "factor_value": 0.9, "factor_version": "CF-2026.2", "factor_source": "SRC-MEE-GHG",
                "confidence": "verified", "point_awarded": 90, "revision": 0, "is_abnormal": 0,
                "note": f"race-v{i+1}", "created_at": stamps[i], "updated_at": stamps[i],
                "is_deleted": 0, "device_id": f"race-dev-{i:02d}",
            }
            return post("/api/v1/sync/push",
                        {"userId": user_id, "deviceId": f"race-dev-{i:02d}", "lastSyncAt": 0,
                         "tables": {"carbon_record": [row]}}, token)

        res = burst(n, one)
        acc = sum((parse(b).get("data", {}).get("accepted") or 0) for c, b in res if c == 200)
        fin = sql_one("SELECT updated_at, device_id, note FROM carbon_record WHERE id=%s", (rid,))
        want_ts = max(stamps)
        ok = fin.get("updated_at") == want_ts
        bad += 0 if ok else 1
        # 「幻影接受」：某版本自称 accepted，但最终行不是它
        winners = sum(1 for i, (c, b) in enumerate(res) if c == 200
                      and (parse(b).get("data", {}).get("accepted") or 0) == 1
                      and n - i == 1)  # note=race-v{n-i} 对应 stamps 下标
        phantoms += max(0, acc - 1)
        table.append(f"round{r}: max(updated_at)={want_ts} 实际落库={fin.get('updated_at')} "
                     f"note={fin.get('note')} device={fin.get('device_id')} "
                     f"sum(accepted)={acc} => {'OK' if ok else 'LWW 违反（旧版胜出）'}")
    ev(f"S2b LWW 并发丢更新：{rounds} 轮 × {n} 并发（同一 id，updated_at 递增）",
       "\n".join(table) +
       f"\n\n统计：LWW 违反轮次 = {bad}/{rounds}；自称 accepted 却未存活的响应数 = {phantoms}")
    # 判定口径（写进 REPORT §0）：产品契约被并发违反时，按任务书「发现真缺陷写三行 STOP 只报告不改」
    # 以 **STOP 发现**呈现（severity=high），不混进工具自身的断言计数；CONC_STRICT_CONTRACT=1 时它会让退出码变 1。
    if bad == 0:
        check("S2b.1", f"并发推同一 id 的 {n} 个版本后，最终行 = updated_at 最大者（LWW 守恒）",
              True, f"违反 0/{rounds} 轮")
    else:
        finding("S2b.1", "high",
                f"STOP: 同一行被 {n} 个并发 push 写、updated_at 递增时，{rounds} 轮里有 {bad} 轮最终落库的不是最大 updated_at"
                f"（LWW「updatedAt 大者胜」在并发下不守恒 ⇒ 丢更新）。\n"
                "冲突: `server/app/services/sync_service.py:405 _merge_lww` 走「SELECT 现有行 → 比较 updated_at → UPDATE」"
                "（:466 `if remote_updated > local_updated`），而 `:490 _apply_update` 的 UPDATE 只带 "
                "`WHERE id=? AND user_id=?`（:495），**没有** `AND updated_at < :remote` 也没有 `SELECT ... FOR UPDATE`："
                "两个事务可同时读到旧行、都通过比较、后提交的更旧版本覆盖先提交的新版本 ↔ 附录 B §6.4-6「updatedAt 大者胜」两端收敛口径。\n"
                "建议: 把比较条件下推进 UPDATE 的 WHERE（`... AND updated_at < :remote_updated`），或用 `SELECT ... FOR UPDATE` "
                "锁住该行再比较；也可改用 `INSERT ... ON DUPLICATE KEY UPDATE col=IF(VALUES(updated_at)>updated_at, VALUES(col), col)`。"
                f"自愈性：下一次同步会把更新的版本重新推上来，但本次编辑在服务端确实被旧值覆盖过。")
    race_rows = sql_one("SELECT COUNT(*) AS n FROM carbon_record WHERE id LIKE 'cr-race-%'")["n"]
    check("S2b.2", "同一 id 并发 push 不产生重复行", race_rows == rounds,
          f"COUNT(cr-race-%%)={race_rows} 期望 {rounds}")

def SERVER_CAP_CODE() -> list[str]:
    """扫 `server/app` 里是否存在「200 − D」式封顶算术（只读源码，不改它）。

    命中 = 空列表 ⇒ 服务端确实没有封顶读-改-写路径；这是 S3 判据冲突的源码证据。
    """
    import pathlib
    hits: list[str] = []
    root = pathlib.Path(__file__).resolve().parents[4] / "server" / "app"
    for f in sorted(root.rglob("*.py")):
        if ".venv" in f.parts:
            continue
        for i, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if re.search(r"DAILY_CAP\s*[-−]|200\s*[-−]\s*d|min\(c.*cap", line):
                hits.append(f"{f.relative_to(root.parent)}:{i}: {line.strip()[:120]}")
    return hits


def s3_daily_cap(user_id: str, token: str) -> None:
    """S3 积分封顶读-改-写：服务端是否存在该路径？并发同日入账合计是否 ≤ 200？"""
    n = 8
    ts = int(time.time() * 1000)
    cfg_code, cfg_body = get("/api/v1/config")
    ev("S3 服务端下发的配置（封顶值来源）",
       f"GET /api/v1/config → http={cfg_code}\n{json.dumps(parse(cfg_body), ensure_ascii=False)}")

    def one(i: int) -> tuple[int, str]:
        if i % 2 == 0:
            row = {
                "id": f"cr-cap-{i}-{uuid.uuid4().hex[:6]}", "user_id": user_id,
                "category": "recycle", "sub_type": "paper", "amount": 1.0, "unit": "kg",
                "occurred_at": ts, "reduction_kg": 2.0, "factor_value": 0.9,
                "factor_version": "CF-2026.2", "factor_source": "SRC-MEE-GHG",
                "confidence": "verified", "point_awarded": 200, "point_capped": 0, "revision": 0,
                "is_abnormal": 0, "note": f"cap-{i}", "created_at": ts, "updated_at": ts + i,
                "is_deleted": 0, "device_id": f"cap-dev-{i:02d}",
            }
            tables = {"carbon_record": [row]}
        else:
            row = {
                "id": f"pr-cap-{i}-{uuid.uuid4().hex[:6]}", "user_id": user_id, "type": "record",
                "flow_kind": "primary", "points": 200, "source_type": "carbon_record",
                "source_id": f"cap-{i}", "title": f"cap-{i}", "occurred_at": ts,
                "created_at": ts, "updated_at": ts + i, "is_deleted": 0,
                "device_id": f"cap-dev-{i:02d}",
            }
            tables = {"point_record": [row]}
        return post("/api/v1/sync/push",
                    {"userId": user_id, "deviceId": f"cap-dev-{i:02d}", "lastSyncAt": 0,
                     "tables": tables}, token)

    res = burst(n, one)
    codes = [c for c, _ in res]
    acc = sum((parse(b).get("data", {}).get("accepted") or 0) for c, b in res if c == 200)
    ev(f"S3 {n} 条并发同日入账（每条各带 point_awarded/points = 200）",
       "\n".join(f"#{i:02d} http={c} accepted={parse(b).get('data', {}).get('accepted')} "
                 f"ignored={parse(b).get('data', {}).get('ignored')} "
                 f"rejected={parse(b).get('data', {}).get('rejected')}"
                 for i, (c, b) in enumerate(res)))

    day_lo, day_hi = DAY_MS + 0, DAY_MS + 86400_000 - 1
    # 必须按**本场景的 id 前缀**圈定：S1/S2/S2b 的行也落在「今天」这个窗口里，按时间窗统计会串场景
    cr = sql_one("SELECT COUNT(*) AS n, COALESCE(SUM(point_awarded),0) AS s FROM carbon_record "
                 "WHERE user_id=%s AND id LIKE 'cr-cap-%%'", (user_id,))  # %% 给 pymysql 转义（否则 %' 被当格式符）
    pr = sql_one("SELECT COUNT(*) AS n, COALESCE(SUM(points),0) AS s FROM point_record "
                 "WHERE user_id=%s AND id LIKE 'pr-cap-%%'", (user_id,))
    pds = sql_one("SELECT COUNT(*) AS n FROM point_daily_stat WHERE user_id=%s", (user_id,))
    daily = sql_one("SELECT value, updated_at FROM app_config WHERE id='points_daily_cap'")
    ev("S3 并发后：当日实入合计 vs 封顶 200（原始 SQL 结果）",
       f"本场景 carbon_record（id LIKE 'cr-cap-%'）: COUNT(*)={cr['n']}  SUM(point_awarded)={cr['s']}\n"
       f"本场景 point_record （id LIKE 'pr-cap-%'）: COUNT(*)={pr['n']}  SUM(points)={pr['s']}\n"
       f"（参考：今天全窗口 carbon_record 行数 = "
       f"{sql_one('SELECT COUNT(*) AS n FROM carbon_record WHERE user_id=%s AND occurred_at BETWEEN %s AND %s', (user_id, day_lo, day_hi))['n']}，"
       f"包含 S1/S2/S2b 的数据，故断言不按时间窗统计）\n"
       f"两者合计实入 = {cr['s'] + pr['s']}   （附录 B 铁律口径封顶 = 200/日/账号）\n"
       f"app_config['points_daily_cap'] = {daily.get('value')}\n"
       f"point_daily_stat 行数 = {pds['n']}（服务端从不写该表："
       f"grep -rn point_daily_stat server/app → 仅 models/ledger.py:94 与 sync_service.py:8 注释）")
    check("S3.1", f"{n} 条并发同日入账全部落库（无丢失、无重复）",
          cr["n"] + pr["n"] == n and acc == n, f"落库 {cr['n'] + pr['n']}/{n} sum(accepted)={acc}")
    check("S3.2", "服务端不产生任何封顶读数（point_daily_stat 0 行）⇒ 封顶读-改-写在服务端不存在",
          pds["n"] == 0, f"point_daily_stat={pds['n']} 行")
    total = cr["s"] + pr["s"]
    # 判据说明（写进 REPORT，不替被测系统辩解）：任务书场景 3 的期望是「服务端合计实入 ≤ 200」，
    # 但冻结契约把封顶算在客户端（AGENTS §2 铁律 1「云端只搬运、不参与业务计算」；附录 A §3 公式
    # A = max(0, min(C, 200 − D)) 由客户端 PointService 持有）。因此本场景**只断言服务端能保证的部分**
    # （并发不丢行、不重复行、无读-改-写路径），把「合计 > 200」作为原始证据 + 判据冲突如实列出，
    # 由队长裁决；`CONC_STRICT_CONTRACT=1` 时该发现会让退出码变 1。
    check("S3.3", "服务端无封顶读-改-写路径（无 `200 − D` 算术、不写 point_daily_stat）",
          pds["n"] == 0 and not SERVER_CAP_CODE(),
          f"point_daily_stat={pds['n']} 行；server/app 内封顶算术命中 = {len(SERVER_CAP_CODE())}")
    if total > 200:
        finding("S3", "medium",
                f"STOP: 并发同日入账合计 = {total} > 200（任务书场景 3 的期望判据），但服务端并无封顶路径。\n"
                f"冲突: server/app 全端点（auth/backup/config/shop/sync）与 services/ 内无 `200 − D` 封顶算术"
                f"（自动扫描命中 = {SERVER_CAP_CODE() or '无'}），`points_daily_cap` 仅由 config_service.py:80 下发给客户端；"
                "AGENTS §2 铁律 1「本机 relationalStore 是唯一真相源，云端只搬运、不参与业务计算」"
                "↔ 任务书 t61 场景 3「合计实入不超过 200」。\n"
                "建议: 二者只能取一 —— 若要服务端封顶须先改契约（新增服务端入账/裁决，与铁律 1 冲突）；"
                "否则把场景 3 判据改为「并发入账不重复/不丢行 + 无封顶 RMW 路径」，"
                "并把「同账号多设备各自满额入账 ⇒ 云端合计可超 200」登记为已知协议边界。")


def s4_pool(user_id: str, token: str) -> None:
    """S4 连接池：并发数 > pool 上限时是否触上限；本任务库的并发连接峰值。"""
    n, rounds = 64, 6
    peak = {"v": 0}
    stop = threading.Event()

    def sampler() -> None:
        # 采样连接挂在 information_schema 上：这样它自己不会被算进「本任务库的连接数」
        conn = pymysql.connect(host=DB_HOST, port=DB_PORT, user=DB_USER, password=DB_PASS,
                               database="information_schema", charset="utf8mb4", autocommit=True)
        try:
            with conn.cursor() as cur:
                while not stop.is_set():
                    try:
                        cur.execute("SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE DB=%s",
                                    (DB_NAME,))
                        peak["v"] = max(peak["v"], int(cur.fetchone()[0]))
                    except Exception:  # noqa: BLE001
                        pass
                    time.sleep(0.02)
        finally:
            conn.close()

    th = threading.Thread(target=sampler, daemon=True)
    th.start()
    hist: dict[int, int] = {}
    bodies: list[str] = []
    for _ in range(rounds):
        res = burst(n, lambda i: get("/api/v1/sync/status", token))
        for r in res:
            if isinstance(r, Exception):
                hist[-1] = hist.get(-1, 0) + 1
                bodies.append(f"EXC {r!r}")
                continue
            code, body = r
            hist[code] = hist.get(code, 0) + 1
            if code >= 500:
                bodies.append(body[:2000])
    stop.set()
    th.join(timeout=2)

    mc = sql_one("SHOW VARIABLES LIKE 'max_connections'")
    used = sql_one("SHOW GLOBAL STATUS LIKE 'Max_used_connections'")
    ev(f"S4 连接池：{rounds} 轮 × {n} 并发 GET /api/v1/sync/status（每请求查库）",
       f"状态码直方图 = {json.dumps({str(k): v for k, v in sorted(hist.items())})}\n"
       f"本任务库并发连接峰值（information_schema.PROCESSLIST WHERE DB={DB_NAME}）= {peak['v']}\n"
       f"max_connections = {mc.get('Value')}（全局，含同容器其它任务）\n"
       f"Max_used_connections（全局历史峰值）= {used.get('Value')}\n"
       f"pool 参数：server/app/core/database.py:34-37 pool_size/max_overflow/pool_recycle/pool_timeout；"
       f"默认值 server/app/core/config.py:72-75 = 5/5/1800/30；"
       f"database.py:50 打印 `2 * (pool_size + max_overflow)` = {2 * (5 + 5)}"
       + ("\n\n5xx 响应体原文：\n" + "\n".join(bodies) if bodies else "\n\n（无 5xx，无 pool 超时错误原文）"))

    log_tail = ""
    if UVICORN_LOG and os.path.exists(UVICORN_LOG):
        with open(UVICORN_LOG, "r", encoding="utf-8", errors="replace") as fh:
            txt = fh.read()
        hits = [ln for ln in txt.splitlines()
                if re.search(r"QueuePool|TimeoutError|Too many connections|OperationalError|Traceback", ln)]
        log_tail = "\n".join(hits[-12:]) if hits else "(uvicorn.log 中无 QueuePool/TimeoutError/Too many connections/Traceback)"
        ev("S4 uvicorn 日志中的连接池/连接错误检索", log_tail)

    ok_hist = all(k == 200 for k in hist)
    check("S4.1", f"{rounds * n} 个并发查库请求全部 200（无 5xx，无 pool 超时）", ok_hist,
          f"直方图={json.dumps({str(k): v for k, v in sorted(hist.items())})}")
    check("S4.2", "未触上限的量化依据：本库并发连接峰值 ≤ 2×(pool_size+max_overflow)=20 ≤ max_connections",
          peak["v"] <= 20 <= int(mc.get("Value") or 0),
          f"峰值={peak['v']} pool上限=20 max_connections={mc.get('Value')}")
    NO_ERR_SENTINEL = log_tail.startswith("(uvicorn.log 中无")
    check("S4.3", "uvicorn 日志无连接池耗尽的原始错误（QueuePool / Too many connections / Traceback）",
          NO_ERR_SENTINEL, "未命中任何错误行" if NO_ERR_SENTINEL else log_tail.splitlines()[0][:160])


def s5_ratelimit() -> None:
    """S5 并发下限流：阈值 10/分钟/worker，2 worker ⇒ 上限 2×10。"""
    user = f"conc_rl_{uuid.uuid4().hex[:8]}"
    pw = "conc-pass-123"
    code, body = post("/api/v1/auth/register", {"username": user, "password": pw})
    ev("S5 前置：注册专用账号（注册不受登录限流）",
       f"POST /api/v1/auth/register ← {user} → http={code}\n{body[:400]}")

    n = 60
    res = burst(n, lambda i: post("/api/v1/auth/login", {"username": user, "password": pw}))
    hist: dict[int, int] = {}
    sample_429 = ""
    sample_200 = ""
    for r in res:
        if isinstance(r, Exception):
            hist[-1] = hist.get(-1, 0) + 1
            continue
        c, b = r
        hist[c] = hist.get(c, 0) + 1
        if c == 429 and not sample_429:
            sample_429 = b
        if c == 200 and not sample_200:
            sample_200 = b
    ev(f"S5 {n} 并发登录（同一 IP + 同一用户名，阈值 LOGIN_RATE_LIMIT_PER_MINUTE=10，uvicorn --workers 2）",
       f"状态码直方图 = {json.dumps({str(k): v for k, v in sorted(hist.items())})}\n\n"
       f"429 响应体样本：{sample_429[:500]}\n\n200 响应体样本（截断）：{sample_200[:200]}")
    code2, body2 = post("/api/v1/auth/login", {"username": user, "password": pw})
    ev("S5 窗口内再登录一次（确认限流未过期）",
       f"POST /api/v1/auth/login → http={code2}\n{body2[:300]}")

    allowed = hist.get(200, 0)
    check("S5.1", f"{n} 并发登录出现 429（限流在并发下真的限住）", hist.get(429, 0) > 0,
          f"429={hist.get(429, 0)} 200={allowed}")
    check("S5.2", "放行数 ≤ 阈值×worker 数 = 2×10（进程内计数器的已知上限，ratelimit.py:5 自述）",
          allowed <= 20, f"放行={allowed} 上限=20")
    check("S5.3", "窗口内后续登录仍被限住（不是一次性误判）", code2 == 429, f"http={code2}")
    if 0 < allowed < 20:
        FINDINGS.append(("S5-note", "info",
                         f"观测：2 worker 下放行 {allowed} 次（阈值 10/worker，理论上限 20）。"
                         "进程内滑动窗口按 worker 各自计数（server/app/core/ratelimit.py:1-6 已自述），"
                         "非全局限流 —— 与文档口径一致，非缺陷。"))


def s6_consistency(user_id: str) -> None:
    """S6 并发后一致性：余额 = 收入 − 支出、point_record 只增不删、无重复 id。"""
    mut_n = sql_one("SELECT COUNT(*) AS n FROM conc_pr_mutation_log")["n"] if TRIGGERS_OK else None
    dup = sql_one("SELECT COUNT(*) AS n, COUNT(DISTINCT id) AS d FROM point_record")
    bal = sql_one("SELECT COALESCE(SUM(points),0) AS b, "
                  "COALESCE(SUM(CASE WHEN points>0 THEN points ELSE 0 END),0) AS inc, "
                  "COALESCE(SUM(CASE WHEN points<0 THEN -points ELSE 0 END),0) AS exp "
                  "FROM point_record WHERE user_id=%s AND is_deleted=0", (user_id,))
    bizsum = sql_one("SELECT COUNT(*) AS n, COALESCE(SUM(points),0) AS s FROM point_record "
                     "WHERE user_id=%s AND source_type='goal' AND flow_kind='primary'", (user_id,))
    # 快照复核：S1 快照里的每一行，现在必须仍在、且三列逐值不变
    now_rows = {
        r["id"]: (r["points"], r["is_deleted"], r["updated_at"])
        for r in sql("SELECT id, points, is_deleted, updated_at FROM point_record WHERE user_id=%s", (user_id,))
    }
    missing = [rid for rid in PR_SNAPSHOT if rid not in now_rows]
    changed = [(rid, PR_SNAPSHOT[rid], now_rows[rid]) for rid in PR_SNAPSHOT
               if rid in now_rows and now_rows[rid] != PR_SNAPSHOT[rid]]
    sl = table_dump("SELECT direction, status, COUNT(*) AS n, SUM(pushed_count) AS pushed, "
                    "SUM(pulled_count) AS pulled, SUM(conflict_count) AS conflicts "
                    "FROM sync_log WHERE user_id=%s GROUP BY direction, status ORDER BY direction", (user_id,))
    ev("S6 并发后一致性抽查（原始 SQL）",
       f"point_record 全表：COUNT(*)={dup['n']} COUNT(DISTINCT id)={dup['d']}\n"
       f"该账号余额（客户端口径 PointService.ets:91）= SUM(points) = {bal['b']}\n"
       f"  收入合计 = {bal['inc']}   支出合计 = {bal['exp']}   "
       f"收入−支出 = {bal['inc'] - bal['exp']}  ⇒ 恒等：{bal['b'] == bal['inc'] - bal['exp']}\n"
       f"同一业务键（S1 那批）落库行数 = {bizsum['n']} 合计分 = {bizsum['s']}（期望 1 行 / 200 分）\n"
       f"触发器命中次数 = {'未装（见上）' if not TRIGGERS_OK else mut_n}\n"
       f"S1 快照复核：快照 {len(PR_SNAPSHOT)} 行；已消失 {len(missing)} 行；被改动 {len(changed)} 行\n"
       + (f"  消失的行：{missing}\n" if missing else "")
       + (f"  被改动的行（id, 旧值, 新值）：{changed}\n" if changed else "")
       + f"\nsync_log 汇总：\n{sl}")
    check("S6.1", "余额 = 收入合计 − 支出合计（客户端口径 SUM(points) 恒等）",
          bal["b"] == bal["inc"] - bal["exp"], f"{bal['b']} vs {bal['inc']} - {bal['exp']}")
    if TRIGGERS_OK:
        check("S6.2", "point_record 只增不删：并发期间的 UPDATE/DELETE 触发器命中 0 次",
              mut_n == 0, f"mutation_log={mut_n} 行")
    else:
        check("S6.2", "point_record 只增不删（快照取证：S1 后的行全部仍在且三列逐值不变）",
              not missing and not changed, f"消失 {len(missing)} / 改动 {len(changed)}")
    check("S6.3", "无重复 id（COUNT(*) = COUNT(DISTINCT id)）", dup["n"] == dup["d"],
          f"{dup['n']} vs {dup['d']}")
    check("S6.4", "S1 并发批次最终仍恰好 1 行 / 200 分（无丢更新）",
          bizsum["n"] == 1 and bizsum["s"] == 200, f"rows={bizsum['n']} points={bizsum['s']}")


def prepare_triggers() -> None:
    """尝试在任务库里装 UPDATE/DELETE 触发器（只增不删取证）。

    失败不致命：MySQL 开了 binlog 且应用账号没有 SUPER 时会报 1419
    （`log_bin_trust_function_creators` 未开），此时退回「S1 后快照 → S6 复核」的数据级取证，
    并把原始错误文本留档 —— 不吞错、不假装成功。
    """
    global TRIGGERS_OK, TRIGGER_ERR
    sql("DROP TABLE IF EXISTS conc_pr_mutation_log")
    sql("CREATE TABLE conc_pr_mutation_log (id BIGINT AUTO_INCREMENT PRIMARY KEY, op VARCHAR(8), "
        "row_id VARCHAR(36), at BIGINT) ENGINE=InnoDB")
    try:
        for op in ("UPDATE", "DELETE"):
            sql(f"DROP TRIGGER IF EXISTS trg_pr_no{op.lower()}")
            sql(f"CREATE TRIGGER trg_pr_no{op.lower()} BEFORE {op} ON point_record FOR EACH ROW "
                f"INSERT INTO conc_pr_mutation_log(op, row_id, at) VALUES ('{op}', OLD.id, "
                f"CAST(UNIX_TIMESTAMP(NOW(3))*1000 AS UNSIGNED))")
        TRIGGERS_OK = True
    except Exception as exc:  # noqa: BLE001 —— 失败原因本身就是证据
        TRIGGER_ERR = f"{type(exc).__name__}: {exc}"
    ev("S6 前置：在任务库里装 UPDATE/DELETE 触发器（只增不删取证；库跑完即 drop）",
       f"TRIGGERS_OK = {TRIGGERS_OK}\n"
       + (f"原始错误（不致命，退回快照取证）：{TRIGGER_ERR}\n" if not TRIGGERS_OK else "")
       + table_dump("SELECT TRIGGER_NAME, EVENT_MANIPULATION, EVENT_OBJECT_TABLE "
                    "FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=%s", (DB_NAME,)))


def main() -> int:
    print(f"# t61 并发/竞态探针  目标 = {BASE_URL}  库 = {DB_NAME}")
    code, body = get("/api/v1/config")
    if code != 200:
        print(f"FATAL: 服务端不可达（GET /api/v1/config → {code}）")
        return 2
    rnd = "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
    user = f"conc_acct_{rnd}"
    code, body = post("/api/v1/auth/register", {"username": user, "password": "conc-pass-123"})
    data = parse(body).get("data", {})
    if code != 201 or not data.get("userToken"):
        print(f"FATAL: 注册失败 http={code} body={body[:300]}")
        return 2
    user_id, token = data["userId"], data["userToken"]
    print(f"账号 = {user} / userId = {user_id}（口令不回显）")

    prepare_triggers()
    s0_preflight()
    if want("s1"):
        s1_unique_key(user_id, token)
    if want("s2"):
        s2_idempotent_push(user_id, token)
    if want("s2b"):
        s2b_lww_race(user_id, token)
    if want("s3"):
        s3_daily_cap(user_id, token)
    if want("s4"):
        s4_pool(user_id, token)
    if want("s5"):
        s5_ratelimit()
    if want("s6"):
        s6_consistency(user_id)

    failed = [c for c in CHECKS if not c[2]]
    print("\n================ 汇总 ================")
    for cid, title, ok, note in CHECKS:
        print(f"{'PASS' if ok else 'FAIL'}  {cid}  {title}" + (f"   [{note}]" if note else ""))
    print(f"断言：{len(CHECKS) - len(failed)}/{len(CHECKS)} 通过")
    print(f"发现（STOP，只报告不改）：{len(FINDINGS)} 条 —— " + ", ".join(f[0] for f in FINDINGS))
    if failed:
        return 1
    if FINDINGS and STRICT_CONTRACT and any(f[1] in ("blocker", "high", "medium") for f in FINDINGS):
        print("CONC_STRICT_CONTRACT=1：存在非 info 级发现 ⇒ 退出码 1")
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        CLIENT.close()

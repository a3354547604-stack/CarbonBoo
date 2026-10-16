"""ORM 基类。

所有模型都直接对应 `server/sql/schema.sql` 里的表（该脚本自 docs/APPENDIX-B-data-and-api.md §1.2/§3 程序化生成，
是数据库结构的唯一真相源）。ORM 只做**读写映射**，不承担建表职责：
建表一律执行 `server/sql/schema.sql`（幂等，可重复执行），避免「ORM 与 SQL 两套结构」分叉。

类型映射约定（与 §1.2 类型映射一致）：
    VARCHAR(n) → String(n)   TEXT → Text   BIGINT → BigInteger   INT → Integer
    TINYINT → mysql.TINYINT  DOUBLE → mysql.DOUBLE(asdecimal=False)

**浮点列一律写 `DOUBLE(asdecimal=False)`**（t5 复核发现）：`mysql.DOUBLE` 默认 `asdecimal=True`，
读出来是 `Decimal('2.0000000000')`，经 JSON 序列化会变成**字符串** `"2.0000000000"`，
而客户端 `numOf(row, 'amount')` / `Number(...)` 期待的是数值 —— 契约里 `amount` / `reduction_kg` /
`progress` / `threshold` / `factor_value` 全是数值（§1.2：客户端 REAL → 服务端 DOUBLE），不是定点货币。
`tests/test_sync.py` 有断言把这一点钉住（pull 回来的浮点必须是 `float`）。
"""

from __future__ import annotations

from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    """CarbonBoo 服务端 ORM 基类（SQLAlchemy 2.x Declarative）。"""

    def __repr__(self) -> str:  # pragma: no cover - 调试用
        pk = getattr(self, "id", None)
        return f"<{type(self).__name__} id={pk!r}>"


__all__ = ["Base"]

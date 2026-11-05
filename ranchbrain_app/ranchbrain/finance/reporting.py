"""Ranch Finance v1 reporting semantics (Master Specification v1.1 §6).

Pure functions over FinanceTransaction rows. Only active, non-transfer actual
rows count toward income, expenses, net, and categories; transfers are counted
separately as distinct confirmed transfers. Month boundaries and "today" use
America/Chicago, never server UTC (§2.8, §6.3).

Spec reading recorded for owner review: §6.1 counts every positive non-transfer
row as income, while §6.2 nets refunds against their expense category. Both are
implemented literally, so a refund in an expense category appears in the
monthly income card *and* reduces that category's spending.
"""

from __future__ import annotations

import calendar
import re
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from datetime import date, datetime, timezone
from decimal import Decimal
from zoneinfo import ZoneInfo

from ranchbrain.finance.model import CategoryType, FinanceModelError, FinanceTransaction

FINANCE_TIMEZONE = ZoneInfo("America/Chicago")
ZERO = Decimal("0.00")
UNCATEGORIZED = "Uncategorized"
_MONTH = re.compile(r"^(\d{4})-(0[1-9]|1[0-2])$")


@dataclass(frozen=True)
class Month:
    year: int
    month: int

    @classmethod
    def parse(cls, value: str) -> "Month":
        match = _MONTH.fullmatch(value or "")
        if not match:
            raise FinanceModelError("month must be YYYY-MM")
        return cls(int(match.group(1)), int(match.group(2)))

    @property
    def first_day(self) -> date:
        return date(self.year, self.month, 1)

    @property
    def days(self) -> int:
        return calendar.monthrange(self.year, self.month)[1]

    @property
    def next_first_day(self) -> date:
        return date(self.year + (self.month == 12), self.month % 12 + 1, 1)

    def contains(self, day: date) -> bool:
        return self.first_day <= day < self.next_first_day

    def __str__(self) -> str:
        return f"{self.year:04d}-{self.month:02d}"


def finance_today(now: datetime) -> date:
    """The current calendar day in America/Chicago for an aware instant."""
    if now.tzinfo is None or now.utcoffset() is None:
        raise FinanceModelError("now must be timezone-aware")
    return now.astimezone(FINANCE_TIMEZONE).date()


def _counted(rows: Iterable[FinanceTransaction], month: Month) -> list[FinanceTransaction]:
    return [row for row in rows if row.is_active and not row.is_transfer and month.contains(row.transaction_date)]


@dataclass(frozen=True)
class MonthlySummary:
    month: str
    total_income: Decimal
    total_expenses: Decimal
    net: Decimal
    transaction_count: int
    transfer_count: int
    uncategorized_count: int
    average_daily_spend: Decimal
    average_daily_spend_applicable: bool


def average_daily_spend(total_expenses: Decimal, month: Month, today: date) -> tuple[Decimal, bool]:
    """§6.3: current month ÷ local day number, past ÷ days in month, future 0.00 (n/a)."""
    if month.contains(today):
        divisor = today.day
    elif month.next_first_day <= today:
        divisor = month.days
    else:
        return ZERO, False
    # divisor is >= 1 by construction; division by zero is impossible.
    return (total_expenses / Decimal(divisor)).quantize(Decimal("0.01")), True


def monthly_summary(
    rows: Iterable[FinanceTransaction],
    month: Month,
    *,
    confirmed_transfer_ids: Iterable[str],
    now: datetime,
) -> MonthlySummary:
    all_rows = list(rows)
    counted = _counted(all_rows, month)
    income = sum((row.amount for row in counted if row.amount > 0), ZERO)
    expenses = sum((-row.amount for row in counted if row.amount < 0), ZERO)
    net = sum((row.amount for row in counted), ZERO)
    confirmed = set(confirmed_transfer_ids)
    transfer_ids = {
        row.transfer_id
        for row in all_rows
        if row.is_active and row.is_transfer and row.transfer_id in confirmed and month.contains(row.transaction_date)
    }
    average, applicable = average_daily_spend(expenses, month, finance_today(now))
    return MonthlySummary(
        month=str(month),
        total_income=income,
        total_expenses=expenses,
        net=net,
        transaction_count=len(counted),
        transfer_count=len(transfer_ids),
        uncategorized_count=sum(1 for row in counted if row.category_id is None),
        average_daily_spend=average,
        average_daily_spend_applicable=applicable,
    )


@dataclass(frozen=True)
class CategoryTotal:
    category_id: str | None
    name: str
    amount: Decimal
    percentage: Decimal


def top_categories(
    rows: Iterable[FinanceTransaction],
    month: Month,
    *,
    categories: Mapping[str, tuple[str, CategoryType]],
    limit: int = 5,
) -> list[CategoryTotal]:
    """§6.2: adjusted expense spending by category, largest first.

    Expense-category rows net together (refunds reduce spending). Uncategorized
    outflows appear as "Uncategorized". Income/transfer-category rows and
    uncategorized inflows are not spending.
    """
    if limit < 1:
        raise FinanceModelError("limit must be positive")
    totals: dict[str | None, Decimal] = {}
    for row in _counted(rows, month):
        if row.category_id is None:
            if row.amount < 0:
                totals[None] = totals.get(None, ZERO) - row.amount
            continue
        name_and_type = categories.get(row.category_id)
        if name_and_type is None or name_and_type[1] is not CategoryType.EXPENSE:
            continue
        totals[row.category_id] = totals.get(row.category_id, ZERO) - row.amount
    positive = {key: value for key, value in totals.items() if value > 0}
    grand = sum(positive.values(), ZERO)
    ranked = sorted(
        positive.items(),
        key=lambda item: (-item[1], UNCATEGORIZED if item[0] is None else categories[item[0]][0]),
    )
    result = []
    for category_id, amount in ranked[:limit]:
        name = UNCATEGORIZED if category_id is None else categories[category_id][0]
        percentage = (amount * 100 / grand).quantize(Decimal("0.1")) if grand else Decimal("0.0")
        result.append(CategoryTotal(category_id, name, amount, percentage))
    return result


def utc_now() -> datetime:
    return datetime.now(timezone.utc)

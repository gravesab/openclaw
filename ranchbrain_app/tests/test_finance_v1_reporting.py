"""Ranch Finance v1 reporting semantics (Master Specification v1.1 §6)."""

from datetime import date, datetime, timezone
from decimal import Decimal

import pytest

from ranchbrain.finance.model import (
    CategoryType,
    DomainCode,
    FinanceModelError,
    FinanceTransaction,
    RecordStatus,
)
from ranchbrain.finance.reporting import (
    UNCATEGORIZED,
    Month,
    average_daily_spend,
    finance_today,
    monthly_summary,
    top_categories,
)

OCT = Month.parse("2026-10")
# 2026-10-15 18:00 UTC is 13:00 CDT on Oct 15.
MID_OCT = datetime(2026, 10, 15, 18, 0, tzinfo=timezone.utc)

CATEGORIES = {
    "feed": ("Feed", CategoryType.EXPENSE),
    "vet": ("Vet", CategoryType.EXPENSE),
    "fuel": ("Fuel", CategoryType.EXPENSE),
    "hay": ("Hay", CategoryType.EXPENSE),
    "tools": ("Tools", CategoryType.EXPENSE),
    "parts": ("Parts", CategoryType.EXPENSE),
    "sales": ("Cattle sales", CategoryType.INCOME),
}


def row(tid, amount, day, *, category=None, transfer=None, status=RecordStatus.ACTIVE, domain=DomainCode.RANCH):
    return FinanceTransaction(
        id=tid, account_id="acct", domain_code=domain, category_id=category, transfer_id=transfer,
        amount=amount, currency="USD", description=tid, transaction_date=day, record_status=status,
    )


def test_month_parse_and_bounds():
    assert (OCT.first_day, OCT.next_first_day, OCT.days) == (date(2026, 10, 1), date(2026, 11, 1), 31)
    dec = Month.parse("2026-12")
    assert dec.next_first_day == date(2027, 1, 1)
    assert Month.parse("2028-02").days == 29
    for bad in ("2026-13", "2026-1", "26-10", "2026/10", "", None):
        with pytest.raises(FinanceModelError):
            Month.parse(bad)


def test_finance_today_uses_america_chicago_not_utc():
    # 2026-11-01 03:30 UTC is still Oct 31 in Chicago (CDT, UTC-5).
    assert finance_today(datetime(2026, 11, 1, 3, 30, tzinfo=timezone.utc)) == date(2026, 10, 31)
    assert finance_today(datetime(2026, 11, 1, 5, 30, tzinfo=timezone.utc)) == date(2026, 11, 1)
    with pytest.raises(FinanceModelError):
        finance_today(datetime(2026, 11, 1, 3, 30))


def test_summary_counts_only_active_nontransfer_rows_in_month():
    rows = [
        row("income", "1000.00", date(2026, 10, 2), category="sales"),
        row("feed", "-200.00", date(2026, 10, 3), category="feed"),
        row("uncat", "-50.00", date(2026, 10, 4)),
        row("excluded", "-999.00", date(2026, 10, 5), status=RecordStatus.EXCLUDED),
        row("superseded", "-888.00", date(2026, 10, 5), status=RecordStatus.SUPERSEDED),
        row("xfer-out", "-500.00", date(2026, 10, 6), transfer="T1"),
        row("xfer-in", "500.00", date(2026, 10, 6), transfer="T1"),
        row("pending-xfer", "-70.00", date(2026, 10, 7), transfer="T2"),
        row("september", "-123.00", date(2026, 9, 30)),
        row("november", "-321.00", date(2026, 11, 1)),
    ]
    summary = monthly_summary(rows, OCT, confirmed_transfer_ids={"T1"}, now=MID_OCT)
    assert summary.total_income == Decimal("1000.00")
    assert summary.total_expenses == Decimal("250.00")
    assert summary.net == Decimal("750.00")
    assert summary.transaction_count == 3
    # Transfers never change totals; only distinct *confirmed* transfers are counted.
    assert summary.transfer_count == 1
    assert summary.uncategorized_count == 1


def test_transfers_do_not_change_income_expense_net():
    base = [row("feed", "-40.00", date(2026, 10, 3), category="feed")]
    with_transfer = base + [
        row("a", "-500.00", date(2026, 10, 3), transfer="T"),
        row("b", "500.00", date(2026, 10, 3), transfer="T"),
    ]
    a = monthly_summary(base, OCT, confirmed_transfer_ids={"T"}, now=MID_OCT)
    b = monthly_summary(with_transfer, OCT, confirmed_transfer_ids={"T"}, now=MID_OCT)
    assert (a.total_income, a.total_expenses, a.net) == (b.total_income, b.total_expenses, b.net)


def test_empty_month_is_zero_not_blank():
    summary = monthly_summary([], OCT, confirmed_transfer_ids=set(), now=MID_OCT)
    assert (summary.total_income, summary.total_expenses, summary.net) == (Decimal("0.00"),) * 3
    assert summary.transaction_count == 0 and summary.average_daily_spend == Decimal("0.00")


@pytest.mark.parametrize("now, expected, applicable", [
    # Current month: divide by the Chicago day number (15).
    (MID_OCT, Decimal("20.00"), True),
    # Past month: divide by days in month (31).
    (datetime(2026, 12, 1, 18, tzinfo=timezone.utc), Decimal("9.68"), True),
    # Future month: 0.00 and not applicable.
    (datetime(2026, 9, 15, 18, tzinfo=timezone.utc), Decimal("0.00"), False),
    # 2026-11-01 03:00 UTC is still Oct 31 in Chicago: current month, day 31.
    (datetime(2026, 11, 1, 3, tzinfo=timezone.utc), Decimal("9.68"), True),
])
def test_average_daily_spend_rules(now, expected, applicable):
    assert average_daily_spend(Decimal("300.00"), OCT, finance_today(now)) == (expected, applicable)


def test_top_categories_nets_refunds_and_includes_uncategorized():
    rows = [
        row("feed1", "-300.00", date(2026, 10, 1), category="feed"),
        row("feed-refund", "50.00", date(2026, 10, 2), category="feed"),
        row("vet", "-100.00", date(2026, 10, 3), category="vet"),
        row("uncat-out", "-100.00", date(2026, 10, 4)),
        row("uncat-in", "75.00", date(2026, 10, 4)),
        row("sale", "900.00", date(2026, 10, 5), category="sales"),
        row("xfer", "-400.00", date(2026, 10, 6), category="feed", transfer="T"),
    ]
    totals = top_categories(rows, OCT, categories=CATEGORIES)
    assert [(t.name, t.amount) for t in totals] == [
        ("Feed", Decimal("250.00")),
        (UNCATEGORIZED, Decimal("100.00")),
        ("Vet", Decimal("100.00")),
    ]
    assert sum(t.percentage for t in totals) == Decimal("100.0")
    assert totals[0].percentage == Decimal("55.6")


def test_top_categories_limits_to_five_largest():
    names = ["feed", "vet", "fuel", "hay", "tools", "parts"]
    rows = [row(n, f"-{(i + 1) * 10}.00", date(2026, 10, 1), category=n) for i, n in enumerate(names)]
    totals = top_categories(rows, OCT, categories=CATEGORIES)
    assert [t.category_id for t in totals] == ["parts", "tools", "hay", "fuel", "vet"]
    with pytest.raises(FinanceModelError):
        top_categories(rows, OCT, categories=CATEGORIES, limit=0)


def test_fully_refunded_category_drops_out():
    rows = [
        row("feed", "-50.00", date(2026, 10, 1), category="feed"),
        row("refund", "50.00", date(2026, 10, 2), category="feed"),
    ]
    assert top_categories(rows, OCT, categories=CATEGORIES) == []

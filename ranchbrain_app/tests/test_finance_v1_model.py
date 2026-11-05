"""Ranch Finance v1 model rules (Master Specification v1.1 §4–§5)."""

from datetime import date
from decimal import Decimal

import pytest

from ranchbrain.finance.model import (
    BLOCKED_DOMAINS,
    DomainCode,
    FinanceModelError,
    FinanceTransaction,
    RecordStatus,
    direction,
    parse_amount,
    require_currency,
)


@pytest.mark.parametrize("text, expected", [
    ("12.34", Decimal("12.34")),
    ("-0.01", Decimal("-0.01")),
    ("5", Decimal("5.00")),
    (Decimal("7.1"), Decimal("7.10")),
    (42, Decimal("42.00")),
    ("999999999999.99", Decimal("999999999999.99")),
])
def test_parse_amount_accepts_exact_signed_values(text, expected):
    assert parse_amount(text) == expected
    assert parse_amount(text).as_tuple().exponent == -2


@pytest.mark.parametrize("bad", [
    "0", "0.00", "-0", 0, Decimal("0"),
    "1.234", Decimal("1.234"), "1e3", "abc", "", " ", "1,000.00", "+5",
    "1000000000000.00", Decimal("NaN"), Decimal("Infinity"),
    1.5, True, None, [],
])
def test_parse_amount_rejects_zero_floats_and_malformed(bad):
    with pytest.raises(FinanceModelError):
        parse_amount(bad)


def test_currency_must_be_iso_uppercase():
    assert require_currency("USD") == "USD"
    for bad in ("usd", "US", "USDD", "", None, 840):
        with pytest.raises(FinanceModelError):
            require_currency(bad)


def test_direction_is_derived_from_sign_only():
    assert direction(Decimal("1.00")) == "inflow"
    assert direction(Decimal("-1.00")) == "outflow"


def _row(**overrides):
    values = dict(
        id="t1", account_id="a1", domain_code=DomainCode.RANCH, category_id=None, transfer_id=None,
        amount="-10.00", currency="USD", description="Feed", transaction_date=date(2026, 10, 3),
        record_status=RecordStatus.ACTIVE,
    )
    values.update(overrides)
    return FinanceTransaction(**values)


def test_transaction_normalizes_amount_and_flags():
    row = _row(amount="-10", transfer_id="x")
    assert row.amount == Decimal("-10.00")
    assert row.is_active and row.is_transfer


@pytest.mark.parametrize("overrides", [
    {"amount": "0"},
    {"currency": "usd"},
    {"transaction_date": "2026-10-03"},
    {"domain_code": "ranch"},
    {"record_status": "active"},
])
def test_transaction_rejects_contract_violations(overrides):
    with pytest.raises(FinanceModelError):
        _row(**overrides)


def test_personal_domain_is_blocked_by_default():
    assert BLOCKED_DOMAINS == frozenset({DomainCode.PERSONAL})

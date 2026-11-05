"""Ranch Finance v1 domain model (Master Specification v1.1 §4–§5).

Amounts are signed and authoritative: positive is inflow, negative is outflow,
zero is prohibited. There is no stored direction; ``direction`` is derived for
presentation only.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date
from decimal import Decimal, InvalidOperation
from enum import Enum

CENT = Decimal("0.01")
# numeric(14,2): at most 12 integer digits.
MAX_ABS_AMOUNT = Decimal("999999999999.99")
_CURRENCY = re.compile(r"^[A-Z]{3}$")
_AMOUNT_TEXT = re.compile(r"^-?\d{1,12}(\.\d{1,2})?$")


class FinanceModelError(ValueError):
    """A value violates the Ranch Finance v1 contract."""


class DomainCode(str, Enum):
    PERSONAL = "personal"
    RANCH = "ranch"
    ZERO_G = "zero_g"


# Personal-finance records need a separately approved per-user privacy policy
# (Checkpoint 0 plan C5/D3); until then reads exclude and refuse this domain.
BLOCKED_DOMAINS = frozenset({DomainCode.PERSONAL})


class CategoryType(str, Enum):
    INCOME = "income"
    EXPENSE = "expense"
    TRANSFER = "transfer"


class RecordStatus(str, Enum):
    ACTIVE = "active"
    EXCLUDED = "excluded"
    VOIDED = "voided"
    SUPERSEDED = "superseded"


class TransferStatus(str, Enum):
    PENDING = "pending"
    CONFIRMED = "confirmed"
    EXCLUDED = "excluded"
    BROKEN = "broken"


def parse_amount(value: object) -> Decimal:
    """Parse an exact signed amount: 2 decimal places max, nonzero, within numeric(14,2).

    Floats are refused so binary rounding can never enter the ledger.
    """
    if isinstance(value, bool) or isinstance(value, float):
        raise FinanceModelError("amount must be a decimal string or Decimal, not a float")
    if isinstance(value, Decimal):
        amount = value
    elif isinstance(value, (int, str)):
        text = str(value).strip()
        if not _AMOUNT_TEXT.fullmatch(text):
            raise FinanceModelError("amount must be a number with at most 2 decimal places")
        try:
            amount = Decimal(text)
        except InvalidOperation as exc:  # pragma: no cover - guarded by the regex
            raise FinanceModelError("amount is not a number") from exc
    else:
        raise FinanceModelError("amount must be a decimal string or Decimal")
    if not amount.is_finite():
        raise FinanceModelError("amount must be finite")
    if amount != amount.quantize(CENT):
        raise FinanceModelError("amount must have at most 2 decimal places")
    amount = amount.quantize(CENT)
    if amount == 0:
        raise FinanceModelError("amount must be nonzero")
    if abs(amount) > MAX_ABS_AMOUNT:
        raise FinanceModelError("amount exceeds numeric(14,2)")
    return amount


def require_currency(value: object) -> str:
    if not isinstance(value, str) or not _CURRENCY.fullmatch(value):
        raise FinanceModelError("currency must be an ISO 4217 code such as USD")
    return value


def direction(amount: Decimal) -> str:
    """Presentation-only direction derived from the signed amount."""
    return "inflow" if amount > 0 else "outflow"


@dataclass(frozen=True)
class FinanceDomain:
    id: str
    code: DomainCode
    name: str
    sort_order: int
    is_active: bool


@dataclass(frozen=True)
class FinanceCategory:
    id: str
    name: str
    category_type: CategoryType
    domain_id: str | None
    parent_id: str | None
    color: str | None
    icon: str | None
    is_active: bool


@dataclass(frozen=True)
class FinanceAccount:
    id: str
    name: str
    account_type: str
    default_domain_id: str
    currency: str
    last_four: str | None
    is_active: bool


@dataclass(frozen=True)
class FinanceTransaction:
    """The reporting-relevant projection of a finance_transactions row."""

    id: str
    account_id: str
    domain_code: DomainCode
    category_id: str | None
    transfer_id: str | None
    amount: Decimal
    currency: str
    description: str
    transaction_date: date
    record_status: RecordStatus

    def __post_init__(self) -> None:
        object.__setattr__(self, "amount", parse_amount(self.amount))
        require_currency(self.currency)
        if not isinstance(self.transaction_date, date):
            raise FinanceModelError("transaction_date must be a date")
        if not isinstance(self.domain_code, DomainCode):
            raise FinanceModelError("domain_code must be a DomainCode")
        if not isinstance(self.record_status, RecordStatus):
            raise FinanceModelError("record_status must be a RecordStatus")

    @property
    def is_active(self) -> bool:
        return self.record_status is RecordStatus.ACTIVE

    @property
    def is_transfer(self) -> bool:
        return self.transfer_id is not None

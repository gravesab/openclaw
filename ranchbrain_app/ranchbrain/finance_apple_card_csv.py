"""Pure Apple Card CSV parser. No I/O, database, or network."""

from __future__ import annotations

import csv
import io
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from hashlib import sha256
from json import dumps


PARSER_VERSION = "apple-card-csv-v1"
CODE_INVALID = "finance_csv_invalid"
CODE_DUPLICATE_ROW = "finance_csv_duplicate_row"
CODE_FUTURE_DATE = "finance_csv_future_date"
CODE_AMOUNT_ZERO = "finance_csv_amount_zero"
CODE_MISSING_COLUMN = "finance_csv_missing_column"

_EXPECTED_HEADERS = (
    "Transaction Date",
    "Clearing Date",
    "Description",
    "Merchant",
    "Category",
    "Type",
    "Amount (USD)",
    "Purchased By",
)
_ACTIVITY_TYPES = frozenset({"purchase", "payment", "refund", "adjustment", "fee"})
_CENTS = Decimal("0.01")
_ZERO = Decimal("0.00")
_DATE_FORMATS = ("%m/%d/%Y", "%Y-%m-%d")


class FinanceCsvError(ValueError):
    def __init__(self, message: str, code: str):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class ParsedActivity:
    transaction_date: date
    clearing_date: date | None
    description: str
    merchant: str
    category: str
    type: str
    amount: Decimal
    purchased_by: str
    external_id: str


@dataclass(frozen=True)
class ParsedArtifact:
    artifact_hash: str
    filename: str
    byte_size: int
    row_count: int
    activities: tuple[ParsedActivity, ...]


def parse_apple_card_csv(csv_bytes: bytes, filename: str, *, now: datetime | None = None) -> ParsedArtifact:
    if not isinstance(csv_bytes, bytes):
        raise FinanceCsvError("csv input must be bytes", CODE_INVALID)
    if not isinstance(filename, str) or not filename.strip():
        raise FinanceCsvError("filename is required", CODE_INVALID)
    clock = now or datetime.now(timezone.utc)
    if clock.tzinfo is None or clock.utcoffset() is None:
        raise FinanceCsvError("parser clock must be timezone-aware", CODE_INVALID)
    try:
        text = csv_bytes.decode("utf-8-sig")
    except UnicodeError as error:
        raise FinanceCsvError("csv must be utf-8", CODE_INVALID) from error
    rows = list(csv.reader(io.StringIO(text)))
    if not rows:
        raise FinanceCsvError("csv header is missing", CODE_MISSING_COLUMN)
    header = [cell.strip() for cell in rows[0]]
    missing = [name for name in _EXPECTED_HEADERS if name not in header]
    if missing:
        raise FinanceCsvError("required csv column is missing", CODE_MISSING_COLUMN)
    index = {name: header.index(name) for name in _EXPECTED_HEADERS}
    latest_allowed = clock.astimezone(timezone.utc).date() + timedelta(days=2)
    activities: list[ParsedActivity] = []
    seen: set[str] = set()
    for raw in rows[1:]:
        if not any(cell.strip() for cell in raw):
            continue
        activity = _parse_row(raw, index, latest_allowed)
        if activity.external_id in seen:
            raise FinanceCsvError("duplicate csv row", CODE_DUPLICATE_ROW)
        seen.add(activity.external_id)
        activities.append(activity)
    parsed = tuple(activities)
    return ParsedArtifact(sha256(csv_bytes).hexdigest(), filename.strip(), len(csv_bytes), len(parsed), parsed)


def _parse_row(raw: list[str], index: dict[str, int], latest_allowed: date) -> ParsedActivity:
    transaction_date = _parse_date(_cell(raw, index["Transaction Date"]), "transaction date")
    if transaction_date > latest_allowed:
        raise FinanceCsvError("transaction date is too far in the future", CODE_FUTURE_DATE)
    clearing_text = _cell(raw, index["Clearing Date"])
    clearing_date = None if not clearing_text else _parse_date(clearing_text, "clearing date")
    if clearing_date is not None and clearing_date < transaction_date:
        raise FinanceCsvError("clearing date precedes transaction date", CODE_INVALID)
    description = _cell(raw, index["Description"])
    if not description:
        raise FinanceCsvError("description is required", CODE_INVALID)
    activity_type = _cell(raw, index["Type"]).casefold()
    if activity_type not in _ACTIVITY_TYPES:
        raise FinanceCsvError("activity type is invalid", CODE_INVALID)
    amount = _parse_amount(_cell(raw, index["Amount (USD)"]))
    merchant = _cell(raw, index["Merchant"])
    category = _cell(raw, index["Category"])
    purchased_by = _cell(raw, index["Purchased By"])
    return ParsedActivity(
        transaction_date,
        clearing_date,
        description,
        merchant,
        category,
        activity_type,
        amount,
        purchased_by,
        _external_id(transaction_date, clearing_date, description, merchant, category, activity_type, amount, purchased_by),
    )


def _cell(raw: list[str], position: int) -> str:
    if position >= len(raw):
        return ""
    return raw[position].strip()


def _parse_date(text: str, field_name: str) -> date:
    if not text:
        raise FinanceCsvError(f"{field_name} is required", CODE_INVALID)
    for fmt in _DATE_FORMATS:
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    raise FinanceCsvError(f"{field_name} is invalid", CODE_INVALID)


def _parse_amount(text: str) -> Decimal:
    if not text or any(mark in text for mark in "$, "):
        raise FinanceCsvError("amount is invalid", CODE_INVALID)
    try:
        amount = Decimal(text)
        cents = amount.quantize(_CENTS)
    except InvalidOperation as error:
        raise FinanceCsvError("amount is invalid", CODE_INVALID) from error
    if cents != amount:
        raise FinanceCsvError("amount is invalid", CODE_INVALID)
    if cents == _ZERO:
        raise FinanceCsvError("amount is zero", CODE_AMOUNT_ZERO)
    return cents


def _external_id(
    transaction_date: date,
    clearing_date: date | None,
    description: str,
    merchant: str,
    category: str,
    activity_type: str,
    amount: Decimal,
    purchased_by: str,
) -> str:
    payload = {
        "amount": str(amount),
        "category": category,
        "clearing_date": "" if clearing_date is None else clearing_date.isoformat(),
        "description": description,
        "merchant": merchant,
        "purchased_by": purchased_by,
        "transaction_date": transaction_date.isoformat(),
        "type": activity_type,
    }
    return sha256(dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")).hexdigest()

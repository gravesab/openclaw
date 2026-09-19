"""DEV-only in-memory Ranch Finance foundation.

This module models immutable source activity, interpretations, splits, and a
balanced double-entry journal. It does not authorize persistence, migrations,
credentials, connectors, money movement, AI writes, or Production.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal, InvalidOperation
from enum import Enum


CENTS = Decimal("0.01")
ZERO = Decimal("0.00")


class FinanceErrorCode(str, Enum):
    INVALID = "finance_invalid"
    UNBALANCED_JOURNAL = "finance_unbalanced_journal"
    SPLIT_TOTAL_MISMATCH = "finance_split_total_mismatch"
    UNKNOWN_INTERPRETATION = "finance_unknown_interpretation"
    INTERPRETATION_SUPERSEDED = "finance_interpretation_superseded"
    INCOMPATIBLE_ALLOCATION = "finance_incompatible_allocation"


class FinanceError(ValueError):
    def __init__(self, message: str, code: FinanceErrorCode):
        super().__init__(message)
        self.code = code


class AccountType(str, Enum):
    ASSET = "asset"
    LIABILITY = "liability"
    INCOME = "income"
    EXPENSE = "expense"
    EQUITY = "equity"


class AllocationDomain(str, Enum):
    HOUSEHOLD = "household"
    LIVESTOCK = "livestock"
    PROPERTY = "property"
    EQUIPMENT = "equipment"
    LAND = "land"


class AllocationTargetType(str, Enum):
    NONE = "none"
    HOUSEHOLD = "household"
    HERD = "herd"
    ANIMAL = "animal"
    ASSET = "asset"
    EQUIPMENT = "equipment"
    PARCEL = "parcel"


COMPATIBLE_ALLOCATION_TARGETS: dict[AllocationDomain, frozenset[AllocationTargetType]] = {
    AllocationDomain.HOUSEHOLD: frozenset({AllocationTargetType.NONE, AllocationTargetType.HOUSEHOLD}),
    AllocationDomain.LIVESTOCK: frozenset({AllocationTargetType.HERD, AllocationTargetType.ANIMAL}),
    AllocationDomain.PROPERTY: frozenset({AllocationTargetType.ASSET}),
    AllocationDomain.EQUIPMENT: frozenset({AllocationTargetType.EQUIPMENT}),
    AllocationDomain.LAND: frozenset({AllocationTargetType.PARCEL}),
}


def money(value: Decimal | int | str) -> Decimal:
    try:
        amount = value if isinstance(value, Decimal) else Decimal(str(value))
        quantized = amount.quantize(CENTS)
    except (InvalidOperation, ValueError) as error:
        raise FinanceError("amount must be cent-precision decimal money", FinanceErrorCode.INVALID) from error
    if quantized != amount:
        raise FinanceError("amount must be cent-precision decimal money", FinanceErrorCode.INVALID)
    return quantized


def _require_token(value: object, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise FinanceError(f"{field_name} is required", FinanceErrorCode.INVALID)
    return value


def _require_aware(value: object, field_name: str) -> None:
    try:
        is_aware = isinstance(value, datetime) and value.tzinfo is not None and value.utcoffset() is not None
    except (TypeError, ValueError):
        is_aware = False
    if not is_aware:
        raise FinanceError(f"{field_name} must be timezone-aware", FinanceErrorCode.INVALID)


@dataclass(frozen=True)
class Account:
    id: str
    name: str
    account_type: AccountType
    institution: str | None = None

    def __post_init__(self) -> None:
        _require_token(self.id, "account id")
        _require_token(self.name, "account name")
        if not isinstance(self.account_type, AccountType):
            raise FinanceError("account type is required", FinanceErrorCode.INVALID)
        if self.institution is not None and (not isinstance(self.institution, str) or not self.institution.strip()):
            raise FinanceError("institution must be omitted or a non-empty name", FinanceErrorCode.INVALID)


@dataclass(frozen=True)
class AllocationLink:
    domain: AllocationDomain
    target_type: AllocationTargetType
    target_id: str = ""

    def __post_init__(self) -> None:
        if not isinstance(self.domain, AllocationDomain) or not isinstance(self.target_type, AllocationTargetType):
            raise FinanceError("allocation requires a domain and target type", FinanceErrorCode.INVALID)
        allowed = COMPATIBLE_ALLOCATION_TARGETS[self.domain]
        if self.target_type not in allowed:
            raise FinanceError(
                f"{self.domain.value} cannot allocate to {self.target_type.value}",
                FinanceErrorCode.INCOMPATIBLE_ALLOCATION,
            )
        if self.target_type is AllocationTargetType.NONE:
            if self.target_id:
                raise FinanceError("untyped household allocation cannot name a target", FinanceErrorCode.INVALID)
            return
        _require_token(self.target_id, "allocation target id")


@dataclass(frozen=True)
class SourceActivity:
    id: str
    source_account_id: str
    posted_at: datetime
    description: str
    amount: Decimal

    def __post_init__(self) -> None:
        _require_token(self.id, "source activity id")
        _require_token(self.source_account_id, "source account id")
        _require_token(self.description, "source description")
        _require_aware(self.posted_at, "source posted_at")
        object.__setattr__(self, "amount", money(self.amount))
        if self.amount == ZERO:
            raise FinanceError("source activity amount cannot be zero", FinanceErrorCode.INVALID)


@dataclass(frozen=True)
class Split:
    amount: Decimal
    destination_account_id: str
    allocation: AllocationLink | None = None

    def __post_init__(self) -> None:
        _require_token(self.destination_account_id, "split destination account id")
        object.__setattr__(self, "amount", money(self.amount))
        if self.amount == ZERO:
            raise FinanceError("split amount cannot be zero", FinanceErrorCode.INVALID)
        if self.allocation is not None and not isinstance(self.allocation, AllocationLink):
            raise FinanceError("split allocation must be an AllocationLink", FinanceErrorCode.INVALID)


@dataclass(frozen=True)
class JournalLine:
    account_id: str
    debit: Decimal
    credit: Decimal

    def __post_init__(self) -> None:
        _require_token(self.account_id, "journal line account id")
        object.__setattr__(self, "debit", money(self.debit))
        object.__setattr__(self, "credit", money(self.credit))
        if (self.debit > ZERO) == (self.credit > ZERO):
            raise FinanceError("journal line requires exactly one of debit or credit", FinanceErrorCode.INVALID)
        if self.debit < ZERO or self.credit < ZERO:
            raise FinanceError("journal line amounts cannot be negative", FinanceErrorCode.INVALID)


@dataclass(frozen=True)
class JournalEntry:
    id: str
    recorded_at: datetime
    lines: tuple[JournalLine, ...]
    reverses_journal_id: str | None = None

    def __post_init__(self) -> None:
        _require_token(self.id, "journal entry id")
        _require_aware(self.recorded_at, "journal recorded_at")
        if not isinstance(self.lines, tuple) or len(self.lines) < 2:
            raise FinanceError("journal entry requires at least two lines", FinanceErrorCode.INVALID)
        if any(not isinstance(line, JournalLine) for line in self.lines):
            raise FinanceError("journal lines must be JournalLine values", FinanceErrorCode.INVALID)
        debit_total = sum((line.debit for line in self.lines), ZERO)
        credit_total = sum((line.credit for line in self.lines), ZERO)
        if debit_total != credit_total:
            raise FinanceError("journal entry must balance exactly", FinanceErrorCode.UNBALANCED_JOURNAL)
        if self.reverses_journal_id is not None:
            _require_token(self.reverses_journal_id, "reversed journal id")


@dataclass(frozen=True)
class Interpretation:
    id: str
    source_activity_id: str
    splits: tuple[Split, ...]
    journal_entry: JournalEntry
    reverses_id: str | None = None
    supersedes_id: str | None = None

    def __post_init__(self) -> None:
        _require_token(self.id, "interpretation id")
        _require_token(self.source_activity_id, "source activity id")
        if not isinstance(self.journal_entry, JournalEntry):
            raise FinanceError("interpretation requires a journal entry", FinanceErrorCode.INVALID)
        if self.reverses_id is not None and self.supersedes_id is not None:
            raise FinanceError("correction cannot both reverse and supersede", FinanceErrorCode.INVALID)
        if self.reverses_id is not None:
            _require_token(self.reverses_id, "reversed interpretation id")
        if self.supersedes_id is not None:
            _require_token(self.supersedes_id, "superseded interpretation id")
        if not isinstance(self.splits, tuple):
            raise FinanceError("splits must be an immutable tuple", FinanceErrorCode.INVALID)
        if any(not isinstance(split, Split) for split in self.splits):
            raise FinanceError("splits must be Split values", FinanceErrorCode.INVALID)
        if self.reverses_id is None and not self.splits:
            raise FinanceError("posted interpretation requires splits", FinanceErrorCode.INVALID)


def split_total(splits: tuple[Split, ...]) -> Decimal:
    return sum((split.amount for split in splits), ZERO)


def expense_journal_from_splits(
    entry_id: str,
    recorded_at: datetime,
    source_account_id: str,
    splits: tuple[Split, ...],
) -> JournalEntry:
    if not splits:
        raise FinanceError("expense journal requires splits", FinanceErrorCode.INVALID)
    outflow = -split_total(splits)
    if outflow <= ZERO:
        raise FinanceError("expense splits must sum to an outflow", FinanceErrorCode.INVALID)
    debit_lines = tuple(
        JournalLine(split.destination_account_id, debit=money(-split.amount), credit=ZERO) for split in splits
    )
    credit_line = JournalLine(source_account_id, debit=ZERO, credit=outflow)
    return JournalEntry(entry_id, recorded_at, debit_lines + (credit_line,))


def require_splits_match_activity(activity: SourceActivity, splits: tuple[Split, ...]) -> None:
    if split_total(splits) != activity.amount:
        raise FinanceError(
            "split total must equal the source activity amount",
            FinanceErrorCode.SPLIT_TOTAL_MISMATCH,
        )


def require_journal_represents_splits(
    journal_entry: JournalEntry,
    activity: SourceActivity,
    splits: tuple[Split, ...],
) -> None:
    require_splits_match_activity(activity, splits)
    expected = expense_journal_from_splits(
        journal_entry.id,
        journal_entry.recorded_at,
        activity.source_account_id,
        splits,
    )
    if journal_entry != expected:
        raise FinanceError(
            "journal must represent the supplied splits and source activity",
            FinanceErrorCode.INVALID,
        )


def reverse_journal_lines(lines: tuple[JournalLine, ...]) -> tuple[JournalLine, ...]:
    return tuple(JournalLine(line.account_id, debit=line.credit, credit=line.debit) for line in lines)


def _index_interpretations(interpretations: tuple[Interpretation, ...]) -> dict[str, Interpretation]:
    indexed: dict[str, Interpretation] = {}
    for interpretation in interpretations:
        if interpretation.id in indexed:
            raise FinanceError("interpretation ids must be unique", FinanceErrorCode.INVALID)
        indexed[interpretation.id] = interpretation
    return indexed


def _closed_interpretation_ids(interpretations: tuple[Interpretation, ...]) -> frozenset[str]:
    closed: set[str] = set()
    for interpretation in interpretations:
        if interpretation.reverses_id is not None:
            closed.add(interpretation.reverses_id)
        if interpretation.supersedes_id is not None:
            closed.add(interpretation.supersedes_id)
    return frozenset(closed)


def _reversed_interpretation_ids(interpretations: tuple[Interpretation, ...]) -> frozenset[str]:
    return frozenset(
        interpretation.reverses_id
        for interpretation in interpretations
        if interpretation.reverses_id is not None
    )


def _require_paired_supersessions(interpretations: tuple[Interpretation, ...]) -> None:
    reversed_ids = _reversed_interpretation_ids(interpretations)
    for interpretation in interpretations:
        if interpretation.supersedes_id is not None and interpretation.supersedes_id not in reversed_ids:
            raise FinanceError(
                "superseding interpretation requires a paired reversal",
                FinanceErrorCode.INVALID,
            )


def _referenced_account_ids(interpretation: Interpretation) -> set[str]:
    return {line.account_id for line in interpretation.journal_entry.lines} | {
        split.destination_account_id for split in interpretation.splits
    }


def require_reversal_matches_original(interpretation: Interpretation, original: Interpretation) -> None:
    if interpretation.source_activity_id != original.source_activity_id:
        raise FinanceError("reversal must keep the source activity", FinanceErrorCode.INVALID)
    expected_lines = reverse_journal_lines(original.journal_entry.lines)
    if interpretation.journal_entry.lines != expected_lines:
        raise FinanceError("reversal journal must invert the original lines", FinanceErrorCode.INVALID)
    if interpretation.journal_entry.reverses_journal_id != original.journal_entry.id:
        raise FinanceError("reversal journal must bind the original journal", FinanceErrorCode.INVALID)
    if interpretation.splits:
        raise FinanceError("reversal cannot carry replacement splits", FinanceErrorCode.INVALID)


def require_open_interpretation(
    interpretations: tuple[Interpretation, ...],
    interpretation_id: str,
) -> Interpretation:
    indexed = _index_interpretations(interpretations)
    original = indexed.get(interpretation_id)
    if original is None:
        raise FinanceError("correction target is unknown", FinanceErrorCode.UNKNOWN_INTERPRETATION)
    if interpretation_id in _closed_interpretation_ids(interpretations):
        raise FinanceError(
            "correction target is already superseded or reversed",
            FinanceErrorCode.INTERPRETATION_SUPERSEDED,
        )
    return original


def reverse_interpretation(
    interpretations: tuple[Interpretation, ...],
    original_id: str,
    new_id: str,
    recorded_at: datetime,
) -> Interpretation:
    original = require_open_interpretation(interpretations, original_id)
    reversing_entry = JournalEntry(
        id=f"journal-reverse-{new_id}",
        recorded_at=recorded_at,
        lines=reverse_journal_lines(original.journal_entry.lines),
        reverses_journal_id=original.journal_entry.id,
    )
    return Interpretation(
        id=new_id,
        source_activity_id=original.source_activity_id,
        splits=(),
        journal_entry=reversing_entry,
        reverses_id=original.id,
    )


def supersede_interpretation(
    interpretations: tuple[Interpretation, ...],
    original_id: str,
    replacement: Interpretation,
) -> Interpretation:
    original = require_open_interpretation(interpretations, original_id)
    if replacement.supersedes_id != original.id:
        raise FinanceError("superseding interpretation must target the original", FinanceErrorCode.INVALID)
    if replacement.source_activity_id != original.source_activity_id:
        raise FinanceError("superseding interpretation must keep the source activity", FinanceErrorCode.INVALID)
    if replacement.reverses_id is not None:
        raise FinanceError("superseding interpretation cannot also reverse", FinanceErrorCode.INVALID)
    return replacement


@dataclass(frozen=True)
class FinanceLedger:
    accounts: tuple[Account, ...]
    activities: tuple[SourceActivity, ...]
    interpretations: tuple[Interpretation, ...] = ()

    def __post_init__(self) -> None:
        account_ids = [account.id for account in self.accounts]
        if len(account_ids) != len(set(account_ids)):
            raise FinanceError("account ids must be unique", FinanceErrorCode.INVALID)
        activity_ids = [activity.id for activity in self.activities]
        if len(activity_ids) != len(set(activity_ids)):
            raise FinanceError("source activity ids must be unique", FinanceErrorCode.INVALID)
        _index_interpretations(self.interpretations)
        _require_paired_supersessions(self.interpretations)

    def account_ids(self) -> frozenset[str]:
        return frozenset(account.id for account in self.accounts)

    def activity_by_id(self, activity_id: str) -> SourceActivity:
        for activity in self.activities:
            if activity.id == activity_id:
                return activity
        raise FinanceError("source activity is unknown", FinanceErrorCode.INVALID)

    def with_interpretation(self, interpretation: Interpretation) -> "FinanceLedger":
        if interpretation.supersedes_id is not None:
            raise FinanceError("supersession must use with_supersession", FinanceErrorCode.INVALID)
        if interpretation.reverses_id is not None:
            original = require_open_interpretation(self.interpretations, interpretation.reverses_id)
            require_reversal_matches_original(interpretation, original)
        else:
            activity = self.activity_by_id(interpretation.source_activity_id)
            require_journal_represents_splits(interpretation.journal_entry, activity, interpretation.splits)
        missing = _referenced_account_ids(interpretation) - self.account_ids()
        if missing:
            raise FinanceError("interpretation references an unknown account", FinanceErrorCode.INVALID)
        return FinanceLedger(self.accounts, self.activities, self.interpretations + (interpretation,))

    def with_supersession(self, replacement: Interpretation) -> "FinanceLedger":
        if replacement.supersedes_id is None:
            raise FinanceError("supersession requires a superseded interpretation", FinanceErrorCode.INVALID)
        original = require_open_interpretation(self.interpretations, replacement.supersedes_id)
        replacement = supersede_interpretation(self.interpretations, original.id, replacement)
        activity = self.activity_by_id(replacement.source_activity_id)
        require_journal_represents_splits(replacement.journal_entry, activity, replacement.splits)
        reversal = reverse_interpretation(
            self.interpretations,
            original.id,
            f"reverse-{replacement.id}",
            replacement.journal_entry.recorded_at,
        )
        missing = (_referenced_account_ids(reversal) | _referenced_account_ids(replacement)) - self.account_ids()
        if missing:
            raise FinanceError("interpretation references an unknown account", FinanceErrorCode.INVALID)
        return FinanceLedger(self.accounts, self.activities, self.interpretations + (reversal, replacement))

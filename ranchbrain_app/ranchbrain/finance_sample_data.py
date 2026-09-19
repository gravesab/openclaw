"""Deterministic DEV-only Ranch Finance sample catalog.

The catalog is sample data only. It does not connect accounts, store
credentials, import live statements, or authorize money movement.
"""

from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal

from ranchbrain.finance_model import (
    Account,
    AccountType,
    AllocationDomain,
    AllocationLink,
    AllocationTargetType,
    FinanceLedger,
    Interpretation,
    SourceActivity,
    Split,
    expense_journal_from_splits,
)


POSTED_AT = datetime(2026, 9, 1, 12, tzinfo=timezone.utc)
RECORDED_AT = datetime(2026, 9, 1, 18, tzinfo=timezone.utc)

ACCT_BANCFIRST_CHECKING = "acct-bancfirst-checking"
ACCT_BANCFIRST_SAVINGS = "acct-bancfirst-savings"
ACCT_CITI = "acct-citi-cards"
ACCT_AMEX = "acct-amex-cards"
ACCT_AMAZON = "acct-amazon-card"
ACCT_APPLE_CARD = "acct-apple-card"
ACCT_MORTGAGE = "acct-first-united-mortgage"
ACCT_LAND_LOAN = "acct-first-united-land-loan"
ACCT_GROCERIES = "acct-expense-household-groceries"
ACCT_PET_SUPPLIES = "acct-expense-household-pet-supplies"
ACCT_FEED = "acct-expense-ranch-livestock-feed"
ACCT_MOWER_OIL = "acct-expense-ranch-equipment-oil"
ACCT_LAND = "acct-expense-ranch-land"

ACTIVITY_GROCERIES = "activity-household-groceries"
ACTIVITY_TRACTOR_SUPPLY = "activity-tractor-supply-split"
ACTIVITY_MOWER_OIL = "activity-mower-oil"
ACTIVITY_LAND_COST = "activity-back-20-acres-land"

TARGET_CATTLE_HERD = "cattle-herd"
TARGET_MOWER = "mower"
TARGET_BACK_20 = "back-20-acres"


def sample_accounts() -> tuple[Account, ...]:
    return (
        Account(ACCT_BANCFIRST_CHECKING, "BancFirst: Checking", AccountType.ASSET, "BancFirst"),
        Account(ACCT_BANCFIRST_SAVINGS, "BancFirst: Savings", AccountType.ASSET, "BancFirst"),
        Account(ACCT_CITI, "Citibank credit cards", AccountType.LIABILITY, "Citibank"),
        Account(ACCT_AMEX, "American Express credit cards", AccountType.LIABILITY, "American Express"),
        Account(ACCT_AMAZON, "Amazon credit card", AccountType.LIABILITY, "Amazon"),
        Account(ACCT_APPLE_CARD, "Apple Card", AccountType.LIABILITY, "Apple Card"),
        Account(ACCT_MORTGAGE, "First United Bank: Home mortgage", AccountType.LIABILITY, "First United Bank"),
        Account(ACCT_LAND_LOAN, "First United Bank: Back 20 acres loan", AccountType.LIABILITY, "First United Bank"),
        Account(ACCT_GROCERIES, "Household: Groceries", AccountType.EXPENSE),
        Account(ACCT_PET_SUPPLIES, "Household: Pet supplies", AccountType.EXPENSE),
        Account(ACCT_FEED, "Ranch: Livestock: Feed", AccountType.EXPENSE),
        Account(ACCT_MOWER_OIL, "Ranch: Equipment: Oil", AccountType.EXPENSE),
        Account(ACCT_LAND, "Ranch: Land: Taxes and maintenance", AccountType.EXPENSE),
    )


def sample_activities() -> tuple[SourceActivity, ...]:
    return (
        SourceActivity(
            ACTIVITY_GROCERIES,
            ACCT_APPLE_CARD,
            POSTED_AT,
            "Neighborhood grocery",
            Decimal("-150.00"),
        ),
        SourceActivity(
            ACTIVITY_TRACTOR_SUPPLY,
            ACCT_CITI,
            POSTED_AT.replace(day=2),
            "Tractor Supply",
            Decimal("-68.00"),
        ),
        SourceActivity(
            ACTIVITY_MOWER_OIL,
            ACCT_AMAZON,
            POSTED_AT.replace(day=3),
            "Mower oil",
            Decimal("-16.00"),
        ),
        SourceActivity(
            ACTIVITY_LAND_COST,
            ACCT_BANCFIRST_CHECKING,
            POSTED_AT.replace(day=4),
            "Back 20 acres land cost",
            Decimal("-240.00"),
        ),
    )


def _posted_interpretation(
    interpretation_id: str,
    activity: SourceActivity,
    splits: tuple[Split, ...],
    recorded_at: datetime,
) -> Interpretation:
    return Interpretation(
        interpretation_id,
        activity.id,
        splits,
        expense_journal_from_splits(f"journal-{interpretation_id}", recorded_at, activity.source_account_id, splits),
    )


def sample_interpretations(activities: tuple[SourceActivity, ...]) -> tuple[Interpretation, ...]:
    by_id = {activity.id: activity for activity in activities}
    groceries = (
        Split(
            Decimal("-150.00"),
            ACCT_GROCERIES,
            AllocationLink(AllocationDomain.HOUSEHOLD, AllocationTargetType.HOUSEHOLD, "household"),
        ),
    )
    tractor_supply = (
        Split(
            Decimal("-42.00"),
            ACCT_FEED,
            AllocationLink(AllocationDomain.LIVESTOCK, AllocationTargetType.HERD, TARGET_CATTLE_HERD),
        ),
        Split(
            Decimal("-16.00"),
            ACCT_MOWER_OIL,
            AllocationLink(AllocationDomain.EQUIPMENT, AllocationTargetType.EQUIPMENT, TARGET_MOWER),
        ),
        Split(
            Decimal("-10.00"),
            ACCT_PET_SUPPLIES,
            AllocationLink(AllocationDomain.HOUSEHOLD, AllocationTargetType.NONE),
        ),
    )
    mower_oil = (
        Split(
            Decimal("-16.00"),
            ACCT_MOWER_OIL,
            AllocationLink(AllocationDomain.EQUIPMENT, AllocationTargetType.EQUIPMENT, TARGET_MOWER),
        ),
    )
    land_cost = (
        Split(
            Decimal("-240.00"),
            ACCT_LAND,
            AllocationLink(AllocationDomain.LAND, AllocationTargetType.PARCEL, TARGET_BACK_20),
        ),
    )
    return (
        _posted_interpretation("interp-groceries", by_id[ACTIVITY_GROCERIES], groceries, RECORDED_AT),
        _posted_interpretation("interp-tractor-supply", by_id[ACTIVITY_TRACTOR_SUPPLY], tractor_supply, RECORDED_AT),
        _posted_interpretation("interp-mower-oil", by_id[ACTIVITY_MOWER_OIL], mower_oil, RECORDED_AT),
        _posted_interpretation("interp-land-cost", by_id[ACTIVITY_LAND_COST], land_cost, RECORDED_AT),
    )


def sample_ledger() -> FinanceLedger:
    accounts = sample_accounts()
    activities = sample_activities()
    ledger = FinanceLedger(accounts, activities)
    for interpretation in sample_interpretations(activities):
        ledger = ledger.with_interpretation(interpretation)
    return ledger

"""Deterministic account and transaction selection for DEV Finance navigation."""

from __future__ import annotations

from ranchbrain.finance_model import Account, AccountType, FinanceError, FinanceErrorCode, SourceActivity

SELECTABLE_ACCOUNT_TYPES = frozenset({AccountType.ASSET, AccountType.LIABILITY})


def visible_accounts(accounts: tuple[Account, ...]) -> tuple[Account, ...]:
    selectable = [account for account in accounts if account.account_type in SELECTABLE_ACCOUNT_TYPES]
    selectable.sort(key=lambda account: (account.name, account.id))
    return tuple(selectable)


def select_account(accounts: tuple[Account, ...], account_id: str | None) -> Account | None:
    visible = visible_accounts(accounts)
    if account_id is None:
        return visible[0] if visible else None
    matches = [account for account in visible if account.id == account_id]
    if not matches:
        raise FinanceError("selected account is not visible", FinanceErrorCode.INVALID)
    return matches[0]


def resolved_account_id(accounts: tuple[Account, ...], account_id: str | None) -> str | None:
    selected = select_account(accounts, account_id)
    if selected is None:
        return None
    return selected.id


def visible_transactions(
    activities: tuple[SourceActivity, ...],
    account_id: str | None,
    accounts: tuple[Account, ...],
) -> tuple[SourceActivity, ...]:
    resolved = resolved_account_id(accounts, account_id)
    if resolved is None:
        return ()
    selected = [activity for activity in activities if activity.source_account_id == resolved]
    selected.sort(key=lambda activity: (activity.posted_at, activity.id))
    return tuple(selected)


def select_transaction_id(
    activities: tuple[SourceActivity, ...],
    account_id: str | None,
    accounts: tuple[Account, ...],
    transaction_id: str | None = None,
) -> str | None:
    visible = visible_transactions(activities, account_id, accounts)
    if transaction_id is None:
        return visible[0].id if visible else None
    if not is_valid_transaction_selection(transaction_id, account_id, activities, accounts):
        raise FinanceError("selected transaction is not visible for the account", FinanceErrorCode.INVALID)
    return transaction_id


def is_valid_transaction_selection(
    transaction_id: str | None,
    account_id: str | None,
    activities: tuple[SourceActivity, ...],
    accounts: tuple[Account, ...],
) -> bool:
    if transaction_id is None:
        return False
    return any(activity.id == transaction_id for activity in visible_transactions(activities, account_id, accounts))

from datetime import datetime, timezone
from decimal import Decimal
import unittest

from ranchbrain.finance_model import Account, AccountType, FinanceError, FinanceErrorCode, SourceActivity
from ranchbrain.finance_selection import (
    is_valid_transaction_selection,
    select_account,
    select_transaction_id,
    visible_accounts,
    visible_transactions,
)


NOW = datetime(2026, 9, 1, 12, tzinfo=timezone.utc)
ACCT_ALPHA = "acct-alpha"
ACCT_EMPTY = "acct-empty"
ACCT_EXPENSE = "acct-expense"
TXN_ALPHA = "txn-alpha"
TXN_OTHER = "txn-other"


def selection_accounts() -> tuple[Account, ...]:
    return (
        Account(ACCT_EMPTY, "B Empty Card", AccountType.LIABILITY),
        Account(ACCT_ALPHA, "A Card", AccountType.LIABILITY),
        Account(ACCT_EXPENSE, "Household: Groceries", AccountType.EXPENSE),
    )


def selection_activities() -> tuple[SourceActivity, ...]:
    return (
        SourceActivity(TXN_OTHER, ACCT_ALPHA, NOW.replace(day=2), "Later charge", Decimal("-20.00")),
        SourceActivity(TXN_ALPHA, ACCT_ALPHA, NOW, "First charge", Decimal("-10.00")),
    )


class FinanceSelectionTests(unittest.TestCase):
    def test_account_selection_is_deterministic_and_prefers_named_visible_account(self):
        accounts = selection_accounts()
        visible = visible_accounts(accounts)
        self.assertEqual(visible, tuple(sorted(visible, key=lambda account: (account.name, account.id))))
        self.assertEqual([account.id for account in visible], [ACCT_ALPHA, ACCT_EMPTY])
        default_account = select_account(accounts, None)
        self.assertIsNotNone(default_account)
        self.assertEqual(default_account.id, ACCT_ALPHA)
        selected = select_account(accounts, ACCT_EMPTY)
        self.assertIsNotNone(selected)
        self.assertEqual(selected.id, ACCT_EMPTY)

    def test_transaction_selection_uses_first_visible_activity_for_the_account(self):
        accounts = selection_accounts()
        activities = selection_activities()
        alpha_transactions = visible_transactions(activities, ACCT_ALPHA, accounts)
        self.assertEqual(select_transaction_id(activities, ACCT_ALPHA, accounts), alpha_transactions[0].id)
        self.assertEqual(alpha_transactions[0].id, TXN_ALPHA)

    def test_missing_account_id_resolves_to_the_same_deterministic_default_account(self):
        accounts = selection_accounts()
        activities = selection_activities()
        default_account = select_account(accounts, None)
        self.assertIsNotNone(default_account)
        self.assertEqual(default_account.id, ACCT_ALPHA)
        default_transaction = select_transaction_id(activities, None, accounts)
        self.assertEqual(default_transaction, select_transaction_id(activities, default_account.id, accounts))
        self.assertEqual(default_transaction, TXN_ALPHA)
        self.assertEqual(visible_transactions(activities, None, accounts)[0].id, default_transaction)
        self.assertTrue(is_valid_transaction_selection(TXN_ALPHA, None, activities, accounts))
        self.assertFalse(is_valid_transaction_selection(TXN_OTHER, ACCT_EMPTY, activities, accounts))

    def test_transaction_from_another_account_is_invalid_and_empty_account_clears_detail(self):
        accounts = selection_accounts()
        activities = selection_activities()
        self.assertFalse(is_valid_transaction_selection(TXN_ALPHA, ACCT_EMPTY, activities, accounts))
        self.assertTrue(is_valid_transaction_selection(TXN_ALPHA, ACCT_ALPHA, activities, accounts))
        with self.assertRaises(FinanceError) as raised:
            select_transaction_id(activities, ACCT_EMPTY, accounts, TXN_ALPHA)
        self.assertEqual(raised.exception.code, FinanceErrorCode.INVALID)
        self.assertIsNone(select_transaction_id(activities, ACCT_EMPTY, accounts))
        self.assertEqual(visible_transactions(activities, ACCT_EMPTY, accounts), ())

    def test_unknown_or_expense_account_selection_is_rejected(self):
        accounts = selection_accounts()
        activities = selection_activities()
        with self.assertRaises(FinanceError) as unknown:
            select_account(accounts, "acct-missing")
        self.assertEqual(unknown.exception.code, FinanceErrorCode.INVALID)
        with self.assertRaises(FinanceError) as expense:
            select_transaction_id(activities, ACCT_EXPENSE, accounts)
        self.assertEqual(expense.exception.code, FinanceErrorCode.INVALID)
        with self.assertRaises(FinanceError) as unknown_txn:
            visible_transactions(activities, "acct-missing", accounts)
        self.assertEqual(unknown_txn.exception.code, FinanceErrorCode.INVALID)


if __name__ == "__main__":
    unittest.main()

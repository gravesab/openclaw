from decimal import Decimal
import unittest

from ranchbrain.finance_model import AllocationDomain, AllocationTargetType
from ranchbrain.finance_sample_data import (
    ACCT_AMAZON,
    ACCT_AMEX,
    ACCT_APPLE_CARD,
    ACCT_BANCFIRST_CHECKING,
    ACCT_BANCFIRST_SAVINGS,
    ACCT_CITI,
    ACCT_LAND_LOAN,
    ACCT_MORTGAGE,
    ACTIVITY_GROCERIES,
    ACTIVITY_LAND_COST,
    ACTIVITY_MOWER_OIL,
    ACTIVITY_TRACTOR_SUPPLY,
    TARGET_BACK_20,
    TARGET_CATTLE_HERD,
    TARGET_MOWER,
    sample_ledger,
)


class FinanceSampleDataTests(unittest.TestCase):
    def test_sample_catalog_includes_required_institution_accounts(self):
        ledger = sample_ledger()
        by_id = {account.id: account for account in ledger.accounts}
        self.assertEqual(by_id[ACCT_BANCFIRST_CHECKING].institution, "BancFirst")
        self.assertEqual(by_id[ACCT_BANCFIRST_SAVINGS].institution, "BancFirst")
        self.assertEqual(by_id[ACCT_CITI].institution, "Citibank")
        self.assertEqual(by_id[ACCT_AMEX].institution, "American Express")
        self.assertEqual(by_id[ACCT_AMAZON].institution, "Amazon")
        self.assertEqual(by_id[ACCT_APPLE_CARD].institution, "Apple Card")
        self.assertEqual(by_id[ACCT_MORTGAGE].name, "First United Bank: Home mortgage")
        self.assertEqual(by_id[ACCT_LAND_LOAN].name, "First United Bank: Back 20 acres loan")

    def test_sample_allocations_cover_groceries_feed_mower_oil_and_land(self):
        ledger = sample_ledger()
        allocations = [
            (split.allocation.domain, split.allocation.target_type, split.allocation.target_id, split.amount)
            for interpretation in ledger.interpretations
            for split in interpretation.splits
            if split.allocation is not None
        ]
        self.assertIn(
            (
                AllocationDomain.HOUSEHOLD,
                AllocationTargetType.HOUSEHOLD,
                "household",
                Decimal("-150.00"),
            ),
            allocations,
        )
        self.assertIn(
            (
                AllocationDomain.LIVESTOCK,
                AllocationTargetType.HERD,
                TARGET_CATTLE_HERD,
                Decimal("-42.00"),
            ),
            allocations,
        )
        self.assertIn(
            (
                AllocationDomain.EQUIPMENT,
                AllocationTargetType.EQUIPMENT,
                TARGET_MOWER,
                Decimal("-16.00"),
            ),
            allocations,
        )
        self.assertIn(
            (
                AllocationDomain.LAND,
                AllocationTargetType.PARCEL,
                TARGET_BACK_20,
                Decimal("-240.00"),
            ),
            allocations,
        )

    def test_sample_journals_balance_and_splits_match_source_amounts(self):
        ledger = sample_ledger()
        activities = {activity.id: activity for activity in ledger.activities}
        self.assertLessEqual(
            {ACTIVITY_GROCERIES, ACTIVITY_TRACTOR_SUPPLY, ACTIVITY_MOWER_OIL, ACTIVITY_LAND_COST},
            set(activities),
        )
        for interpretation in ledger.interpretations:
            debit = sum((line.debit for line in interpretation.journal_entry.lines), Decimal("0.00"))
            credit = sum((line.credit for line in interpretation.journal_entry.lines), Decimal("0.00"))
            self.assertEqual(debit, credit)
            activity = activities[interpretation.source_activity_id]
            self.assertEqual(
                sum((split.amount for split in interpretation.splits), Decimal("0.00")),
                activity.amount,
            )


if __name__ == "__main__":
    unittest.main()

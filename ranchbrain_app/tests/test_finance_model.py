from datetime import datetime, timezone
from decimal import Decimal
import unittest

from ranchbrain.finance_model import (
    Account,
    AccountType,
    AllocationDomain,
    AllocationLink,
    AllocationTargetType,
    FinanceError,
    FinanceErrorCode,
    FinanceLedger,
    Interpretation,
    JournalEntry,
    JournalLine,
    SourceActivity,
    Split,
    expense_journal_from_splits,
    money,
    reverse_interpretation,
    reverse_journal_lines,
    split_total,
    supersede_interpretation,
)


NOW = datetime(2026, 9, 1, 12, tzinfo=timezone.utc)
ZERO = Decimal("0.00")


def checking() -> Account:
    return Account("acct-checking", "BancFirst: Checking", AccountType.ASSET, "BancFirst")


def groceries() -> Account:
    return Account("acct-groceries", "Household: Groceries", AccountType.EXPENSE)


def feed() -> Account:
    return Account("acct-feed", "Ranch: Livestock: Feed", AccountType.EXPENSE)


def grocery_split(amount: str = "-150.00") -> Split:
    return Split(
        Decimal(amount),
        "acct-groceries",
        AllocationLink(AllocationDomain.HOUSEHOLD, AllocationTargetType.HOUSEHOLD, "household"),
    )


def feed_split(amount: str) -> Split:
    return Split(
        Decimal(amount),
        "acct-feed",
        AllocationLink(AllocationDomain.LIVESTOCK, AllocationTargetType.HERD, "cattle-herd"),
    )


def posted_interpretation(
    interpretation_id: str = "interp-1",
    splits: tuple[Split, ...] | None = None,
    journal_id: str = "journal-1",
    supersedes_id: str | None = None,
) -> Interpretation:
    chosen = splits if splits is not None else (grocery_split(),)
    return Interpretation(
        interpretation_id,
        "activity-1",
        chosen,
        expense_journal_from_splits(journal_id, NOW, "acct-checking", chosen),
        supersedes_id=supersedes_id,
    )


def empty_ledger(amount: str = "-150.00") -> FinanceLedger:
    return FinanceLedger(
        (checking(), groceries(), feed()),
        (SourceActivity("activity-1", "acct-checking", NOW, "Neighborhood grocery", Decimal(amount)),),
    )


def ledger_with(interpretation: Interpretation, amount: str | None = None) -> FinanceLedger:
    if amount is None:
        amount = str(sum((split.amount for split in interpretation.splits), ZERO))
    return empty_ledger(amount).with_interpretation(interpretation)


class FinanceModelTests(unittest.TestCase):
    def test_journal_entry_requires_exact_balance(self):
        entry = JournalEntry(
            "journal-balanced",
            NOW,
            (
                JournalLine("acct-groceries", Decimal("150.00"), ZERO),
                JournalLine("acct-checking", ZERO, Decimal("150.00")),
            ),
        )
        self.assertEqual(
            sum((line.debit for line in entry.lines), ZERO),
            sum((line.credit for line in entry.lines), ZERO),
        )
        with self.assertRaises(FinanceError) as raised:
            JournalEntry(
                "journal-unbalanced",
                NOW,
                (
                    JournalLine("acct-groceries", Decimal("150.00"), ZERO),
                    JournalLine("acct-checking", ZERO, Decimal("149.00")),
                ),
            )
        self.assertEqual(raised.exception.code, FinanceErrorCode.UNBALANCED_JOURNAL)

    def test_source_activity_journal_entry_and_splits_are_immutable(self):
        source = SourceActivity("activity-1", "acct-checking", NOW, "Neighborhood grocery", Decimal("-150.00"))
        entry = JournalEntry(
            "journal-1",
            NOW,
            (
                JournalLine("acct-groceries", Decimal("150.00"), ZERO),
                JournalLine("acct-checking", ZERO, Decimal("150.00")),
            ),
        )
        split = grocery_split()
        with self.assertRaises(AttributeError):
            source.amount = Decimal("-1.00")
        with self.assertRaises(AttributeError):
            entry.lines = ()
        with self.assertRaises(AttributeError):
            split.amount = Decimal("-1.00")

    def test_interpretation_and_journal_line_are_immutable_after_construction(self):
        line = JournalLine("acct-groceries", Decimal("150.00"), ZERO)
        interpretation = posted_interpretation()
        with self.assertRaises(AttributeError):
            line.debit = ZERO
        with self.assertRaises(AttributeError):
            interpretation.splits = ()
        with self.assertRaises(AttributeError):
            interpretation.journal_entry = interpretation.journal_entry

    def test_sub_cent_money_is_rejected(self):
        with self.assertRaises(FinanceError) as raised:
            money(Decimal("1.001"))
        self.assertEqual(raised.exception.code, FinanceErrorCode.INVALID)
        with self.assertRaises(FinanceError) as activity_raised:
            SourceActivity("activity-1", "acct-checking", NOW, "Neighborhood grocery", Decimal("-150.001"))
        self.assertEqual(activity_raised.exception.code, FinanceErrorCode.INVALID)

    def test_journal_line_rejects_both_debit_and_credit_or_neither(self):
        with self.assertRaises(FinanceError) as both:
            JournalLine("acct-groceries", Decimal("150.00"), Decimal("150.00"))
        self.assertEqual(both.exception.code, FinanceErrorCode.INVALID)
        with self.assertRaises(FinanceError) as neither:
            JournalLine("acct-groceries", ZERO, ZERO)
        self.assertEqual(neither.exception.code, FinanceErrorCode.INVALID)

    def test_posted_interpretation_split_total_equals_source_and_journal_represents_splits(self):
        built = ledger_with(posted_interpretation())
        activity = built.activity_by_id("activity-1")
        posted = built.interpretations[0]
        self.assertEqual(split_total(posted.splits), activity.amount)
        expected = expense_journal_from_splits(
            posted.journal_entry.id,
            posted.journal_entry.recorded_at,
            activity.source_account_id,
            posted.splits,
        )
        self.assertEqual(posted.journal_entry, expected)

    def test_split_total_must_equal_source_activity_amount(self):
        empty = empty_ledger()
        over_total = posted_interpretation("interp-over", (grocery_split("-160.00"),), "journal-over")
        with self.assertRaises(FinanceError) as over_raised:
            empty.with_interpretation(over_total)
        self.assertEqual(over_raised.exception.code, FinanceErrorCode.SPLIT_TOTAL_MISMATCH)
        opposite = Interpretation(
            "interp-opposite",
            "activity-1",
            (grocery_split("150.00"),),
            JournalEntry(
                "journal-opposite",
                NOW,
                (
                    JournalLine("acct-groceries", Decimal("150.00"), ZERO),
                    JournalLine("acct-checking", ZERO, Decimal("150.00")),
                ),
            ),
        )
        with self.assertRaises(FinanceError) as opposite_raised:
            empty.with_interpretation(opposite)
        self.assertEqual(opposite_raised.exception.code, FinanceErrorCode.SPLIT_TOTAL_MISMATCH)
        with self.assertRaises(FinanceError) as empty_splits:
            Interpretation(
                "interp-empty",
                "activity-1",
                (),
                JournalEntry(
                    "journal-empty-splits",
                    NOW,
                    (
                        JournalLine("acct-groceries", Decimal("150.00"), ZERO),
                        JournalLine("acct-checking", ZERO, Decimal("150.00")),
                    ),
                ),
            )
        self.assertEqual(empty_splits.exception.code, FinanceErrorCode.INVALID)

    def test_balanced_journal_that_does_not_represent_splits_is_rejected(self):
        empty = empty_ledger()
        unrelated = Interpretation(
            "interp-unrelated",
            "activity-1",
            (grocery_split(),),
            JournalEntry(
                "journal-unrelated",
                NOW,
                (
                    JournalLine("acct-feed", Decimal("150.00"), ZERO),
                    JournalLine("acct-checking", ZERO, Decimal("150.00")),
                ),
            ),
        )
        with self.assertRaises(FinanceError) as raised:
            empty.with_interpretation(unrelated)
        self.assertEqual(raised.exception.code, FinanceErrorCode.INVALID)

    def test_incompatible_allocation_domain_and_target_are_rejected(self):
        with self.assertRaises(FinanceError) as raised:
            AllocationLink(AllocationDomain.LIVESTOCK, AllocationTargetType.EQUIPMENT, "mower")
        self.assertEqual(raised.exception.code, FinanceErrorCode.INCOMPATIBLE_ALLOCATION)
        with self.assertRaises(FinanceError) as land_raised:
            AllocationLink(AllocationDomain.LAND, AllocationTargetType.HERD, "cattle-herd")
        self.assertEqual(land_raised.exception.code, FinanceErrorCode.INCOMPATIBLE_ALLOCATION)

    def test_successful_supersession_closes_the_original_without_mutating_it(self):
        original = posted_interpretation()
        built = ledger_with(original)
        replacement = posted_interpretation(
            "interp-super",
            (feed_split("-150.00"),),
            "journal-super",
            supersedes_id="interp-1",
        )
        posted = built.with_supersession(supersede_interpretation(built.interpretations, "interp-1", replacement))
        self.assertEqual(built.interpretations[0].journal_entry.lines, original.journal_entry.lines)
        self.assertEqual(posted.interpretations[0].id, "interp-1")
        self.assertEqual(posted.interpretations[0].journal_entry.lines, original.journal_entry.lines)
        reversal = posted.interpretations[1]
        successor = posted.interpretations[2]
        self.assertEqual(reversal.reverses_id, "interp-1")
        self.assertEqual(reversal.journal_entry.reverses_journal_id, original.journal_entry.id)
        self.assertEqual(reversal.journal_entry.lines, reverse_journal_lines(original.journal_entry.lines))
        self.assertEqual(successor.supersedes_id, "interp-1")
        self.assertEqual(split_total(successor.splits), Decimal("-150.00"))
        nets: dict[str, Decimal] = {}
        for interpretation in posted.interpretations:
            for line in interpretation.journal_entry.lines:
                nets[line.account_id] = nets.get(line.account_id, ZERO) + line.debit - line.credit
        self.assertEqual(nets["acct-groceries"], ZERO)
        self.assertEqual(nets["acct-feed"], Decimal("150.00"))
        self.assertEqual(nets["acct-checking"], Decimal("-150.00"))
        with self.assertRaises(FinanceError) as reverse_closed:
            reverse_interpretation(posted.interpretations, "interp-1", "interp-reverse", NOW)
        self.assertEqual(reverse_closed.exception.code, FinanceErrorCode.INTERPRETATION_SUPERSEDED)
        second = posted_interpretation(
            "interp-super-again",
            (grocery_split(),),
            "journal-super-again",
            supersedes_id="interp-1",
        )
        with self.assertRaises(FinanceError) as supersede_closed:
            posted.with_supersession(second)
        self.assertEqual(supersede_closed.exception.code, FinanceErrorCode.INTERPRETATION_SUPERSEDED)

    def test_standalone_superseding_post_is_rejected(self):
        original = posted_interpretation()
        built = ledger_with(original)
        replacement = posted_interpretation(
            "interp-super",
            (feed_split("-150.00"),),
            "journal-super",
            supersedes_id="interp-1",
        )
        with self.assertRaises(FinanceError) as raised:
            built.with_interpretation(replacement)
        self.assertEqual(raised.exception.code, FinanceErrorCode.INVALID)
        with self.assertRaises(FinanceError) as assembled:
            FinanceLedger(built.accounts, built.activities, (original, replacement))
        self.assertEqual(assembled.exception.code, FinanceErrorCode.INVALID)

    def test_correction_rejects_unknown_and_already_reversed_interpretations(self):
        original = posted_interpretation()
        built = ledger_with(original)
        with self.assertRaises(FinanceError) as unknown:
            reverse_interpretation(built.interpretations, "missing", "interp-reverse", NOW)
        self.assertEqual(unknown.exception.code, FinanceErrorCode.UNKNOWN_INTERPRETATION)
        reversal = reverse_interpretation(built.interpretations, "interp-1", "interp-reverse", NOW)
        closed = built.with_interpretation(reversal)
        with self.assertRaises(FinanceError) as superseded:
            reverse_interpretation(closed.interpretations, "interp-1", "interp-again", NOW)
        self.assertEqual(superseded.exception.code, FinanceErrorCode.INTERPRETATION_SUPERSEDED)
        replacement = posted_interpretation(
            "interp-super",
            (grocery_split(),),
            "journal-super",
            supersedes_id="interp-1",
        )
        with self.assertRaises(FinanceError) as supersede_closed:
            supersede_interpretation(closed.interpretations, "interp-1", replacement)
        self.assertEqual(supersede_closed.exception.code, FinanceErrorCode.INTERPRETATION_SUPERSEDED)

    def test_non_inverted_reversal_is_rejected(self):
        original = posted_interpretation()
        built = ledger_with(original)
        non_inverted = Interpretation(
            "interp-bad-reverse",
            original.source_activity_id,
            (),
            original.journal_entry,
            reverses_id="interp-1",
        )
        with self.assertRaises(FinanceError) as raised:
            built.with_interpretation(non_inverted)
        self.assertEqual(raised.exception.code, FinanceErrorCode.INVALID)

    def test_reversal_must_bind_the_original_journal_id(self):
        original = posted_interpretation()
        built = ledger_with(original)
        reversal = reverse_interpretation(built.interpretations, "interp-1", "interp-reverse", NOW)
        self.assertEqual(reversal.journal_entry.reverses_journal_id, original.journal_entry.id)
        inverted = reverse_journal_lines(original.journal_entry.lines)
        missing_link = Interpretation(
            "interp-unbound",
            original.source_activity_id,
            (),
            JournalEntry("journal-unbound", NOW, inverted),
            reverses_id="interp-1",
        )
        with self.assertRaises(FinanceError) as missing:
            built.with_interpretation(missing_link)
        self.assertEqual(missing.exception.code, FinanceErrorCode.INVALID)
        wrong_link = Interpretation(
            "interp-wrong-link",
            original.source_activity_id,
            (),
            JournalEntry("journal-wrong-link", NOW, inverted, reverses_journal_id="journal-other"),
            reverses_id="interp-1",
        )
        with self.assertRaises(FinanceError) as wrong:
            built.with_interpretation(wrong_link)
        self.assertEqual(wrong.exception.code, FinanceErrorCode.INVALID)

    def test_multi_line_reversal_inverts_every_line_without_mutating_the_original(self):
        splits = (grocery_split("-100.00"), feed_split("-50.00"))
        original = posted_interpretation("interp-1", splits)
        built = ledger_with(original)
        reversal = reverse_interpretation(built.interpretations, "interp-1", "interp-reverse", NOW)
        closed = built.with_interpretation(reversal)
        self.assertEqual(closed.interpretations[0].journal_entry.lines, original.journal_entry.lines)
        expected_lines = reverse_journal_lines(original.journal_entry.lines)
        self.assertEqual(closed.interpretations[1].journal_entry.lines, expected_lines)
        self.assertGreater(len(expected_lines), 2)
        for original_line, reversed_line in zip(original.journal_entry.lines, expected_lines, strict=True):
            self.assertEqual(reversed_line.account_id, original_line.account_id)
            self.assertEqual(reversed_line.debit, original_line.credit)
            self.assertEqual(reversed_line.credit, original_line.debit)

    def test_duplicate_ordinary_posting_is_rejected(self):
        original = posted_interpretation()
        built = ledger_with(original)
        duplicate = posted_interpretation("interp-2", journal_id="journal-2")
        with self.assertRaises(FinanceError) as posted_again:
            built.with_interpretation(duplicate)
        self.assertEqual(posted_again.exception.code, FinanceErrorCode.INVALID)
        with self.assertRaises(FinanceError) as assembled:
            FinanceLedger(built.accounts, built.activities, (original, duplicate))
        self.assertEqual(assembled.exception.code, FinanceErrorCode.INVALID)

    def test_direct_ledger_construction_enforces_posting_invariants(self):
        original = posted_interpretation()
        empty = empty_ledger()
        assembled = FinanceLedger(empty.accounts, empty.activities, (original,))
        self.assertEqual(assembled.interpretations[0].id, "interp-1")
        with self.assertRaises(FinanceError) as unknown_account:
            FinanceLedger((checking(),), empty.activities, (original,))
        self.assertEqual(unknown_account.exception.code, FinanceErrorCode.INVALID)
        over_total = posted_interpretation("interp-over", (grocery_split("-160.00"),), "journal-over")
        with self.assertRaises(FinanceError) as split_mismatch:
            FinanceLedger(empty.accounts, empty.activities, (over_total,))
        self.assertEqual(split_mismatch.exception.code, FinanceErrorCode.SPLIT_TOTAL_MISMATCH)
        unrelated = Interpretation(
            "interp-unrelated",
            "activity-1",
            (grocery_split(),),
            JournalEntry(
                "journal-unrelated",
                NOW,
                (
                    JournalLine("acct-feed", Decimal("150.00"), ZERO),
                    JournalLine("acct-checking", ZERO, Decimal("150.00")),
                ),
            ),
        )
        with self.assertRaises(FinanceError) as noncanonical:
            FinanceLedger(empty.accounts, empty.activities, (unrelated,))
        self.assertEqual(noncanonical.exception.code, FinanceErrorCode.INVALID)

    def test_reversal_cannot_be_a_correction_target(self):
        original = posted_interpretation()
        built = ledger_with(original)
        reversal = reverse_interpretation(built.interpretations, "interp-1", "interp-reverse", NOW)
        closed = built.with_interpretation(reversal)
        with self.assertRaises(FinanceError) as reverse_reversal:
            reverse_interpretation(closed.interpretations, "interp-reverse", "interp-rev-rev", NOW)
        self.assertEqual(reverse_reversal.exception.code, FinanceErrorCode.INVALID)
        replacement = posted_interpretation(
            "interp-super",
            (feed_split("-150.00"),),
            "journal-super",
            supersedes_id="interp-reverse",
        )
        with self.assertRaises(FinanceError) as supersede_reversal:
            closed.with_supersession(replacement)
        self.assertEqual(supersede_reversal.exception.code, FinanceErrorCode.INVALID)
        reverse_of_reverse = Interpretation(
            "interp-rev-rev",
            original.source_activity_id,
            (),
            JournalEntry(
                "journal-rev-rev",
                NOW,
                reverse_journal_lines(reversal.journal_entry.lines),
                reverses_journal_id=reversal.journal_entry.id,
            ),
            reverses_id=reversal.id,
        )
        with self.assertRaises(FinanceError) as assembled:
            FinanceLedger(closed.accounts, closed.activities, (original, reversal, reverse_of_reverse))
        self.assertEqual(assembled.exception.code, FinanceErrorCode.INVALID)

    def test_journal_ids_must_be_unique_across_the_ledger(self):
        original = posted_interpretation()
        built = ledger_with(original)
        inverted = reverse_journal_lines(original.journal_entry.lines)
        reused = Interpretation(
            "interp-reverse",
            original.source_activity_id,
            (),
            JournalEntry(original.journal_entry.id, NOW, inverted, reverses_journal_id=original.journal_entry.id),
            reverses_id="interp-1",
        )
        with self.assertRaises(FinanceError) as posted_again:
            built.with_interpretation(reused)
        self.assertEqual(posted_again.exception.code, FinanceErrorCode.INVALID)
        second_activity = SourceActivity("activity-2", "acct-checking", NOW, "Second grocery", Decimal("-150.00"))
        second = Interpretation(
            "interp-2",
            "activity-2",
            (grocery_split(),),
            expense_journal_from_splits("journal-1", NOW, "acct-checking", (grocery_split(),)),
        )
        with self.assertRaises(FinanceError) as assembled:
            FinanceLedger(
                built.accounts,
                (built.activities[0], second_activity),
                (original, second),
            )
        self.assertEqual(assembled.exception.code, FinanceErrorCode.INVALID)

    def test_valid_original_reversal_replacement_history_succeeds(self):
        original = posted_interpretation()
        built = ledger_with(original)
        replacement = posted_interpretation(
            "interp-super",
            (feed_split("-150.00"),),
            "journal-super",
            supersedes_id="interp-1",
        )
        posted = built.with_supersession(supersede_interpretation(built.interpretations, "interp-1", replacement))
        assembled = FinanceLedger(posted.accounts, posted.activities, posted.interpretations)
        self.assertEqual(tuple(item.id for item in assembled.interpretations), ("interp-1", "reverse-interp-super", "interp-super"))
        self.assertEqual(assembled.interpretations[1].reverses_id, "interp-1")
        self.assertEqual(assembled.interpretations[2].supersedes_id, "interp-1")
        self.assertEqual(
            assembled.interpretations[1].journal_entry.lines,
            reverse_journal_lines(original.journal_entry.lines),
        )


if __name__ == "__main__":
    unittest.main()

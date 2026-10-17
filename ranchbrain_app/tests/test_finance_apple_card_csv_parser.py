"""Apple Card CSV parser proof. No database."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from hashlib import sha256
from pathlib import Path
import re
import unittest

from ranchbrain.finance_apple_card_csv import (
    CODE_AMOUNT_ZERO,
    CODE_DUPLICATE_ROW,
    CODE_FUTURE_DATE,
    CODE_INVALID,
    CODE_MISSING_COLUMN,
    FinanceCsvError,
    parse_apple_card_csv,
)
from ranchbrain.finance_csv_write_adapter import apple_card_clearing_account_id, record_apple_card_artifact
from ranchbrain.tenancy import Role, Tenant, TenantContextResolver, TenantMembership, TenancyError, User, VerifiedPrincipal


FIXTURES = Path(__file__).resolve().parent / "fixtures"
NOW = datetime(2026, 6, 1, tzinfo=timezone.utc)
HEADER = "Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By"
FORBIDDEN = re.compile(r"import psycopg2|import asyncpg|import requests|os\.environ|open\(|float")


def _csv(*rows: str) -> bytes:
    return ("\n".join((HEADER, *rows)) + "\n").encode("utf-8")


class AppleCardCsvParserTests(unittest.TestCase):
    def test_modules_have_no_io_driver_or_binary_floating_point(self) -> None:
        root = Path(__file__).resolve().parents[1] / "ranchbrain"
        for name in ("finance_apple_card_csv.py", "finance_csv_write_adapter.py"):
            text = (root / name).read_text(encoding="utf-8")
            self.assertIsNone(FORBIDDEN.search(text), name)

    def test_sample_fixture_parses_bom_quoted_comma_and_decimal_amounts(self) -> None:
        raw = (FIXTURES / "apple_card_sample_10.csv").read_bytes()
        self.assertTrue(raw.startswith(b"\xef\xbb\xbf"))
        parsed = parse_apple_card_csv(raw, "apple_card_sample_10.csv", now=NOW)
        self.assertEqual(parsed.row_count, 10)
        self.assertEqual(len(parsed.activities), 10)
        self.assertEqual(parsed.artifact_hash, sha256(raw).hexdigest())
        self.assertEqual(parsed.byte_size, len(raw))
        merchants = [row.merchant for row in parsed.activities]
        self.assertIn("North Gate Feed, LLC", merchants)
        self.assertEqual(
            {row.type for row in parsed.activities},
            {"purchase", "payment", "refund", "adjustment", "fee"},
        )
        self.assertTrue(all(isinstance(row.amount, Decimal) for row in parsed.activities))
        self.assertEqual(parsed.activities[0].amount, Decimal("186.40"))
        self.assertEqual(parsed.activities[3].amount, Decimal("-250.00"))
        self.assertEqual(len({row.external_id for row in parsed.activities}), 10)
        again = parse_apple_card_csv(raw, "apple_card_sample_10.csv", now=NOW)
        self.assertEqual(again, parsed)

    def test_future_date_is_rejected(self) -> None:
        future = (NOW.date() + timedelta(days=3)).strftime("%m/%d/%Y")
        with self.assertRaises(FinanceCsvError) as raised:
            parse_apple_card_csv(_csv(f"{future},{future},Future,Store,Home,Purchase,1.00,Alex Sample"), "future.csv", now=NOW)
        self.assertEqual(raised.exception.code, CODE_FUTURE_DATE)

    def test_boundary_date_two_days_ahead_is_accepted(self) -> None:
        allowed = (NOW.date() + timedelta(days=2)).strftime("%m/%d/%Y")
        parsed = parse_apple_card_csv(_csv(f"{allowed},{allowed},Soon,Store,Home,Purchase,1.00,Alex Sample"), "soon.csv", now=NOW)
        self.assertEqual(parsed.row_count, 1)

    def test_zero_amount_is_rejected(self) -> None:
        with self.assertRaises(FinanceCsvError) as raised:
            parse_apple_card_csv(_csv("01/02/2024,01/02/2024,Zero,Store,Home,Purchase,0.00,Alex Sample"), "zero.csv", now=NOW)
        self.assertEqual(raised.exception.code, CODE_AMOUNT_ZERO)

    def test_missing_column_fixture_is_rejected(self) -> None:
        raw = (FIXTURES / "apple_card_invalid.csv").read_bytes()
        with self.assertRaises(FinanceCsvError) as raised:
            parse_apple_card_csv(raw, "apple_card_invalid.csv", now=NOW)
        self.assertEqual(raised.exception.code, CODE_MISSING_COLUMN)

    def test_duplicate_fixture_is_rejected(self) -> None:
        raw = (FIXTURES / "apple_card_duplicate.csv").read_bytes()
        with self.assertRaises(FinanceCsvError) as raised:
            parse_apple_card_csv(raw, "apple_card_duplicate.csv", now=NOW)
        self.assertEqual(raised.exception.code, CODE_DUPLICATE_ROW)

    def test_invalid_type_and_clearing_order_are_rejected(self) -> None:
        with self.assertRaises(FinanceCsvError) as raised:
            parse_apple_card_csv(_csv("01/02/2024,01/02/2024,Transfer,Store,Home,Transfer,1.00,Alex Sample"), "type.csv", now=NOW)
        self.assertEqual(raised.exception.code, CODE_INVALID)
        with self.assertRaises(FinanceCsvError) as raised_clearing:
            parse_apple_card_csv(_csv("01/04/2024,01/02/2024,Early,Store,Home,Purchase,1.00,Alex Sample"), "clearing.csv", now=NOW)
        self.assertEqual(raised_clearing.exception.code, CODE_INVALID)

    def test_blank_tenant_fails_before_session_sql(self) -> None:
        parsed = parse_apple_card_csv(_csv("01/02/2024,01/02/2024,Hay,Store,Farm,Purchase,1.00,Alex Sample"), "one.csv", now=NOW)
        principal = VerifiedPrincipal(
            "00000000-0000-0000-0000-000000000001",
            "human",
            "development",
            "active",
            "mfa-fresh",
            "session-parser",
            NOW - timedelta(minutes=5),
            NOW + timedelta(hours=1),
            "corr-parser",
        )
        resolver = TenantContextResolver(
            environment="development",
            users=[User("00000000-0000-0000-0000-000000000011", principal.id)],
            tenants=[Tenant("00000000-0000-0000-0000-0000000000a1", "tenant-a", "Tenant A")],
            memberships=[TenantMembership("00000000-0000-0000-0000-0000000000a1", "00000000-0000-0000-0000-000000000011", Role.OWNER)],
        )

        class ExplodingSession:
            def begin(self) -> None:
                raise AssertionError("session sql ran before tenant validation")

        with self.assertRaises(TenancyError):
            record_apple_card_artifact(
                ExplodingSession(),
                "  ",
                parsed,
                apple_card_clearing_account_id(parsed.artifact_hash),
                parsed.artifact_hash,
                principal=principal,
                resolver=resolver,
                now=NOW,
            )

    def test_sample_disclaimer_still_says_passing_is_not_live_pg_proof(self) -> None:
        text = Path(__file__).with_name("test_finance_sample_data.py").read_text(encoding="utf-8")
        self.assertIn("not live PG correctness", text)


if __name__ == "__main__":
    unittest.main()

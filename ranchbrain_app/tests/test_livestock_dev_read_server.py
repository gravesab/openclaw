"""Loopback Livestock DEV read server. No database and no non-local bind."""

from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from ranchbrain.livestock_dev_postgres import LivestockPostgresError, LivestockPostgresRecords
from datetime import datetime, timedelta, timezone

from ranchbrain.livestock_dev_read_server import (
    ANIMALS_PATH,
    LOOPBACK_HOST,
    LivestockDevReadServerError,
    create_server,
    require_loopback,
    reusable_ticket,
    write_ticket,
)


class LivestockDevReadServerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.ticket = Path(self.directory.name) / "dev-read.json"
        self.server, self.base_url = create_server(self.ticket)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.token = json.loads(self.ticket.read_text(encoding="utf-8"))["token"]

    def tearDown(self) -> None:
        self.server.shutdown()
        self.thread.join(timeout=2)
        self.server.server_close()
        self.directory.cleanup()

    def test_loopback_get_returns_live_animals_and_writes_a_private_ticket(self) -> None:
        payload = self._get(self.token, "tenant-a")
        self.assertEqual(payload["origin"], "live")
        self.assertEqual(payload["operation"], "animal_list")
        names = [animal["display_name"] for animal in payload["body"]["animals"]]
        self.assertEqual(names, ["Aster", "Briar"])
        mode = self.ticket.stat().st_mode & 0o777
        self.assertEqual(mode, 0o600)
        self.assertNotIn("password", self.ticket.read_text(encoding="utf-8").lower())

    def test_write_verbs_and_bad_auth_fail_closed(self) -> None:
        for method in ("POST", "PUT", "PATCH", "DELETE"):
            with self.subTest(method=method):
                status = self._status(method, self.token, "tenant-a")
                self.assertEqual(status, 405)
        self.assertEqual(self._status("GET", "wrong-token", "tenant-a"), 401)
        self.assertEqual(self._status("GET", self.token, "tenant-b"), 403)

    def test_non_loopback_bind_is_rejected(self) -> None:
        with self.assertRaises(LivestockDevReadServerError):
            require_loopback("0.0.0.0")
        self.assertEqual(require_loopback(LOOPBACK_HOST), LOOPBACK_HOST)

    def _get(self, token: str, tenant: str) -> dict:
        request = urllib.request.Request(
            self.base_url + ANIMALS_PATH,
            headers={"Authorization": f"Bearer {token}", "X-RanchOS-Tenant": tenant},
            method="GET",
        )
        with urllib.request.urlopen(request, timeout=2) as response:
            return json.loads(response.read().decode("utf-8"))

    def _status(self, method: str, token: str, tenant: str) -> int:
        request = urllib.request.Request(
            self.base_url + ANIMALS_PATH,
            data=b"{}" if method != "GET" else None,
            headers={"Authorization": f"Bearer {token}", "X-RanchOS-Tenant": tenant},
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                return response.status
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
            return status


class LivestockDevTicketReuseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.ticket = Path(self.directory.name) / "dev-read.json"

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_restart_reuses_a_valid_ticket_on_the_same_port(self) -> None:
        first, url = create_server(self.ticket)
        payload = json.loads(self.ticket.read_text(encoding="utf-8"))
        port = int(url.rsplit(":", 1)[-1])
        first.server_close()
        restarted, same_url = create_server(self.ticket, port=port)
        restarted.server_close()
        reused = json.loads(self.ticket.read_text(encoding="utf-8"))
        self.assertEqual(same_url, url)
        self.assertEqual(reused["token"], payload["token"])
        self.assertEqual(reused["expiresAt"], payload["expiresAt"])

    def test_expired_ticket_is_not_reused(self) -> None:
        now = datetime.now(timezone.utc)
        write_ticket(self.ticket, f"http://{LOOPBACK_HOST}:18761", "old-token", now - timedelta(minutes=1))
        self.assertIsNone(reusable_ticket(self.ticket, f"http://{LOOPBACK_HOST}:18761", now))
        self.assertIsNone(reusable_ticket(self.ticket, f"http://{LOOPBACK_HOST}:9", now))


class LivestockPostgresRecordTests(unittest.TestCase):
    def test_assign_keeps_trimmed_value_and_rejects_unknown_kind(self) -> None:
        seen: list[str] = []

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT species_code" in sql:
                return "cattle"
            return "11111111-2222-4333-8444-555555555561"

        records = LivestockPostgresRecords(runner)
        records.assign_identifier("11111111-2222-4333-8444-555555555551", "brand", "  NR-7  ")
        self.assertIn("'NR-7'", seen[1])
        with self.assertRaises(LivestockPostgresError):
            records.assign_identifier("11111111-2222-4333-8444-555555555551", "license", "D-1")
        with self.assertRaises(LivestockPostgresError):
            records.assign_identifier("11111111-2222-4333-8444-555555555551", "band", "X")

    def test_high_impact_care_and_cost_require_confirmation_before_sql(self) -> None:
        seen: list[str] = []

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT reason FROM ranchos.livestock_animal_retirements" in sql:
                return ""
            return "11111111-2222-4333-8444-555555555571"

        records = LivestockPostgresRecords(runner)
        animal = "11111111-2222-4333-8444-555555555551"
        when = "2026-10-03T14:00:00Z"
        with self.assertRaises(LivestockPostgresError):
            records.record_care(animal, "surgery", when, False)
        self.assertEqual(seen, [])
        records.record_care(animal, "observation", when, False)
        observation = next(sql for sql in seen if "'observation'" in sql)
        self.assertIn("NULL", observation)
        with self.assertRaises(LivestockPostgresError):
            records.record_cost(animal, "12.50", "", False)
        self.assertFalse(any("12.50" in sql for sql in seen))
        records.record_cost(animal, "12.50", "", True)
        cost = next(sql for sql in seen if "12.50" in sql)
        self.assertIn("'USD'", cost)
        self.assertIn("'per_animal'", cost)

    def test_weight_recorded_stores_pounds_and_other_events_do_not(self) -> None:
        seen: list[str] = []

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT reason FROM ranchos.livestock_animal_retirements" in sql:
                return ""
            return "11111111-2222-4333-8444-555555555571"

        records = LivestockPostgresRecords(runner)
        animal = "11111111-2222-4333-8444-555555555551"
        when = "2026-10-12T14:00:00Z"
        with self.assertRaises(LivestockPostgresError):
            records.record_lifecycle(animal, "weight_recorded", when, "")
        with self.assertRaises(LivestockPostgresError):
            records.record_lifecycle(animal, "weight_recorded", when, "0")
        with self.assertRaises(LivestockPostgresError):
            records.record_lifecycle(animal, "intake", when, "10")
        self.assertEqual(seen, [])
        records.record_lifecycle(animal, "weight_recorded", when, "842.5")
        saved = next(sql for sql in seen if "weight_recorded" in sql and "INSERT" in sql)
        self.assertIn("weight_pounds", saved)
        self.assertIn("'842.5'::numeric", saved)
        records.record_lifecycle(animal, "intake", when)
        intake = next(sql for sql in seen if "'intake'" in sql and "INSERT" in sql)
        self.assertIn("weight_pounds", intake)
        self.assertIn("NULL", intake)
        self.assertNotIn("::numeric", intake)

    def test_lifecycle_correction_keeps_the_original_event_and_requires_confirmation(self) -> None:
        seen: list[str] = []

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT reason FROM ranchos.livestock_animal_retirements" in sql:
                return ""
            if "supersedes_event_id" in sql and "incorrect_time" in sql:
                return "11111111-2222-4333-8444-555555555581"
            return ""

        records = LivestockPostgresRecords(runner)
        animal = "11111111-2222-4333-8444-555555555551"
        event = "11111111-2222-4333-8444-555555555571"
        when = "2026-10-08T20:00:00Z"
        with self.assertRaises(LivestockPostgresError):
            records.correct_lifecycle(animal, event, when, "incorrect_time", False)
        self.assertEqual(seen, [])
        with self.assertRaises(LivestockPostgresError):
            records.correct_lifecycle(animal, event, when, "sold", True)
        records.correct_lifecycle(animal, event, when, "incorrect_time", True)
        correction = next(sql for sql in seen if "incorrect_time" in sql)
        self.assertIn("target.event_type", correction)
        self.assertIn("target.weight_pounds", correction)
        self.assertIn("supersedes_event_id", correction)
        self.assertIn(event, correction)
        self.assertNotIn("'intake'", correction)
        with self.assertRaises(LivestockPostgresError):
            records.correct_lifecycle(animal, event, when, "incorrect_value", True)

    def test_cost_accepts_a_negative_correction_and_rejects_zero(self) -> None:
        seen: list[str] = []

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT reason FROM ranchos.livestock_animal_retirements" in sql:
                return ""
            return "11111111-2222-4333-8444-555555555571"

        records = LivestockPostgresRecords(runner)
        animal = "11111111-2222-4333-8444-555555555551"
        records.record_cost(animal, "-4.25", "", True)
        cost = next(sql for sql in seen if "-4.25" in sql)
        self.assertIn("-4.25", cost)
        with self.assertRaises(LivestockPostgresError):
            records.record_cost(animal, "0", "", True)
        with self.assertRaises(LivestockPostgresError):
            records.record_cost(animal, "-0.00", "", True)

    def test_lifecycle_and_care_costs_link_to_their_event(self) -> None:
        seen: list[str] = []
        event = "11111111-2222-4333-8444-555555555571"

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT reason FROM ranchos.livestock_animal_retirements" in sql:
                return ""
            return event

        records = LivestockPostgresRecords(runner)
        animal = "11111111-2222-4333-8444-555555555551"
        when = "2026-10-15T14:00:00Z"
        self.assertEqual(records.record_lifecycle(animal, "intake", when), event)
        self.assertEqual(records.record_care(animal, "vaccination", when, True, "CDT", ""), event)

        records.record_cost(animal, "18.00", "", True, lifecycle_event_id=event)
        lifecycle_cost = next(sql for sql in seen if "18.00" in sql)
        self.assertIn(f"'{event}'::uuid", lifecycle_cost)
        self.assertIn("ranchos.livestock_lifecycle_events e", lifecycle_cost)
        self.assertIn(f"e.animal_id = '{animal}'", lifecycle_cost)

        records.record_cost(animal, "-2.50", "", True, care_event_id=event)
        care_cost = next(sql for sql in seen if "-2.50" in sql)
        self.assertIn("ranchos.livestock_care_events c", care_cost)
        self.assertIn(f"c.animal_id = '{animal}'", care_cost)

        before = len(seen)
        with self.assertRaises(LivestockPostgresError):
            records.record_cost(animal, "5", "", True, feed_type="hay", care_event_id=event)
        with self.assertRaises(LivestockPostgresError):
            records.record_cost(animal, "5", "", True, lifecycle_event_id="not-a-uuid")
        self.assertEqual(len(seen), before)

    def test_care_feed_and_cost_corrections_supersede_the_current_record(self) -> None:
        seen: list[str] = []
        new_id = "11111111-2222-4333-8444-5555555555f1"

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT reason FROM ranchos.livestock_animal_retirements" in sql:
                return ""
            return new_id

        records = LivestockPostgresRecords(runner)
        animal = "11111111-2222-4333-8444-555555555551"
        record = "11111111-2222-4333-8444-555555555571"
        when = "2026-10-15T14:00:00Z"

        with self.assertRaises(LivestockPostgresError):
            records.correct_care(animal, record, when, "incorrect_time", False)
        with self.assertRaises(LivestockPostgresError):
            records.correct_care(animal, record, when, "sold", True)
        with self.assertRaises(LivestockPostgresError):
            records.correct_consumption(animal, record, "0", "scoop", "daily", when, "", "", "incorrect_value", True)
        with self.assertRaises(LivestockPostgresError):
            records.correct_cost(animal, record, "5", "incorrect_time", True)
        with self.assertRaises(LivestockPostgresError):
            records.correct_cost(animal, record, "0", "incorrect_value", True)
        self.assertEqual(seen, [])

        self.assertEqual(records.correct_care(animal, record, when, "incorrect_value", True, " CDT ", ""), new_id)
        care = seen[-1]
        self.assertIn("target.event_type", care)
        self.assertIn("supersedes_event_id", care)
        self.assertIn("'CDT'", care)
        self.assertIn("NOT EXISTS", care)

        records.correct_consumption(animal, record, "3", "bale", "weekly", when, "Valley Mill", "", "incorrect_value", True)
        feed = seen[-1]
        self.assertIn("target.input_type", feed)
        self.assertIn("supersedes_consumption_id", feed)
        self.assertIn("'weekly'", feed)
        self.assertIn("'Valley Mill'", feed)

        records.correct_cost(animal, record, "-12.50", "incorrect_value", True)
        cost = seen[-1]
        self.assertIn("-12.50", cost)
        self.assertIn("target.care_event_id", cost)
        self.assertIn("supersedes_cost_id", cost)

        records.correct_cost(animal, record, "", "duplicate_entry", True)
        self.assertIn("target.amount", seen[-1])

        records.correct_lifecycle(animal, record, when, "incorrect_value", True, "910")
        self.assertIn("'910'::numeric", seen[-1])
        records.correct_lifecycle(animal, record, when, "incorrect_time", True)
        self.assertIn("target.weight_pounds", seen[-1])

    def test_event_and_feed_corrections_carry_their_cost_in_one_statement(self) -> None:
        seen: list[str] = []
        new_id = "11111111-2222-4333-8444-5555555555f2"

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT reason FROM ranchos.livestock_animal_retirements" in sql:
                return ""
            return new_id

        records = LivestockPostgresRecords(runner)
        animal = "11111111-2222-4333-8444-555555555551"
        record = "11111111-2222-4333-8444-555555555571"
        cost = "11111111-2222-4333-8444-555555555581"
        when = "2026-10-15T14:00:00Z"

        with self.assertRaises(LivestockPostgresError):
            records.correct_care(animal, record, when, "duplicate_entry", True, cost_id=cost, cost_amount="9")
        with self.assertRaises(LivestockPostgresError):
            records.correct_care(animal, record, when, "incorrect_value", True, cost_id=cost, cost_amount="0")
        with self.assertRaises(LivestockPostgresError):
            records.correct_care(animal, record, when, "incorrect_value", True, cost_id=cost)
        with self.assertRaises(LivestockPostgresError):
            records.correct_consumption(
                animal, record, "3", "bale", "weekly", when, "", "", "duplicate_entry", True, cost_amount="20"
            )
        self.assertEqual(seen, [])

        records.correct_care(animal, record, when, "incorrect_value", True, cost_id=cost, cost_amount="18.25")
        statement = seen[-1]
        self.assertIn("WITH corrected AS", statement)
        self.assertIn("18.25", statement)
        self.assertIn(f"c.id = '{cost}'", statement)
        self.assertIn("c.care_event_id IN (SELECT id FROM chain)", statement)
        self.assertIn("supersedes_cost_id", statement)

        records.correct_lifecycle(animal, record, when, "incorrect_value", True, cost_amount="7")
        statement = seen[-1]
        self.assertIn("AND NOT EXISTS (WITH RECURSIVE chain", statement)
        self.assertIn("c.lifecycle_event_id IN (SELECT id FROM chain)", statement)
        self.assertIn(f"'{record}'::uuid", statement)
        self.assertIn("FROM corrected", statement)

        before = len(seen)
        with self.assertRaises(LivestockPostgresError):
            records.correct_consumption(
                animal, record, "3", "bale", "weekly", when, "", "", "incorrect_value", True, cost_id=cost, cost_amount="-4"
            )
        self.assertEqual(len(seen), before)
        records.correct_consumption(
            animal, record, "3", "bale", "weekly", when, "", "", "incorrect_value", True, cost_id=cost, cost_amount="14"
        )
        statement = seen[-1]
        self.assertIn("c.consumption_id IN (SELECT id FROM chain)", statement)
        self.assertIn("e.supersedes_consumption_id", statement)
        self.assertIn("target.consumption_id", statement)
        self.assertIn("14", statement)
        self.assertIn("'weekly', target.feed_type", statement)

        records.correct_consumption(
            animal, record, "3", "bale", "weekly", when, "", "", "incorrect_value", True, cost_amount="20"
        )
        statement = seen[-1]
        self.assertIn("feed_type, frequency_code, consumption_id", statement)
        self.assertIn("SELECT n.input_type FROM ranchos.livestock_input_consumption n", statement)
        self.assertIn(f"'{record}'::uuid", statement)

        before = len(seen)
        records.correct_care(animal, record, when, "duplicate_entry", True)
        self.assertNotIn("WITH corrected AS", seen[-1])
        self.assertEqual(len(seen), before + 2)

    def test_feed_cost_links_to_its_feed_record(self) -> None:
        seen: list[str] = []
        new_id = "11111111-2222-4333-8444-5555555555f3"

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT reason FROM ranchos.livestock_animal_retirements" in sql:
                return ""
            return new_id

        records = LivestockPostgresRecords(runner)
        animal = "11111111-2222-4333-8444-555555555551"
        feed = "11111111-2222-4333-8444-555555555591"
        self.assertEqual(
            records.record_consumption(animal, "hay", "2", "bale", "2026-10-15T14:00:00Z", "", "", "daily"), new_id
        )
        with self.assertRaises(LivestockPostgresError):
            records.record_cost(animal, "30", "", True, "daily", "", consumption_id=feed)
        with self.assertRaises(LivestockPostgresError):
            records.record_cost(animal, "-5", "", True, "daily", "hay", consumption_id=feed)
        records.record_cost(animal, "30", "", True, "daily", "hay", consumption_id=feed)
        statement = seen[-1]
        self.assertIn(f"'{feed}'::uuid", statement)
        self.assertIn("n.input_type = 'hay'", statement)
        self.assertIn(f"n.animal_id = '{animal}'", statement)

    def test_herd_feed_links_cost_to_the_herd_not_the_animals(self) -> None:
        seen: list[str] = []
        new_id = "11111111-2222-4333-8444-5555555555f4"

        def runner(sql: str) -> str:
            seen.append(sql)
            if "THEN 'open'" in sql:
                return "open"
            return new_id

        records = LivestockPostgresRecords(runner)
        herd = "11111111-2222-4333-8444-5555555555bb"
        feed = "11111111-2222-4333-8444-555555555592"
        with self.assertRaises(LivestockPostgresError):
            records.record_consumption(input_type="hay", quantity="4", unit="bale", observed_at="2026-10-16T14:00:00Z")
        self.assertEqual(
            records.record_consumption(
                input_type="hay",
                quantity="4",
                unit="bale",
                observed_at="2026-10-16T14:00:00Z",
                frequency="daily",
                herd_id=herd,
            ),
            new_id,
        )
        consumption_sql = next(item for item in seen if "INSERT INTO ranchos.livestock_input_consumption" in item)
        self.assertIn(f"'{herd}'", consumption_sql)
        self.assertIn("NULL", consumption_sql)
        records.record_cost(
            amount="40",
            finance_reference="",
            confirmed=True,
            frequency="daily",
            feed_type="hay",
            consumption_id=feed,
            herd_id=herd,
        )
        cost_sql = seen[-1]
        self.assertIn("'per_herd'", cost_sql)
        self.assertIn(f"n.herd_id = '{herd}'", cost_sql)
        self.assertIn("n.animal_id IS NULL", cost_sql)
        remaining = {"state": "retired"}

        def retired(sql: str) -> str:
            if "THEN 'open'" in sql:
                return remaining["state"]
            return new_id

        retired_records = LivestockPostgresRecords(retired)
        with self.assertRaises(LivestockPostgresError):
            retired_records.record_consumption(
                input_type="hay",
                quantity="1",
                unit="bale",
                observed_at="2026-10-16T14:00:00Z",
                frequency="daily",
                herd_id=herd,
            )

    def test_herd_care_links_cost_to_the_herd_not_the_animals(self) -> None:
        seen: list[str] = []
        new_id = "11111111-2222-4333-8444-5555555555c4"

        def runner(sql: str) -> str:
            seen.append(sql)
            if "THEN 'open'" in sql:
                return "open"
            return new_id

        records = LivestockPostgresRecords(runner)
        herd = "11111111-2222-4333-8444-5555555555bb"
        care = "11111111-2222-4333-8444-555555555593"
        with self.assertRaises(LivestockPostgresError):
            records.record_care(event_type="vaccination", occurred_at="2026-10-16T14:00:00Z", confirmed=True)
        with self.assertRaises(LivestockPostgresError):
            records.record_care(
                event_type="vaccination",
                occurred_at="2026-10-16T14:00:00Z",
                confirmed=False,
                herd_id=herd,
            )
        self.assertEqual(
            records.record_care(
                event_type="vaccination",
                occurred_at="2026-10-16T14:00:00Z",
                confirmed=True,
                item_name="CDT",
                herd_id=herd,
            ),
            new_id,
        )
        care_sql = next(item for item in seen if "INSERT INTO ranchos.livestock_care_events" in item)
        self.assertIn(f"'{herd}'", care_sql)
        self.assertIn("'vaccination'", care_sql)
        records.record_cost(
            amount="12",
            finance_reference="",
            confirmed=True,
            care_event_id=care,
            herd_id=herd,
        )
        cost_sql = seen[-1]
        self.assertIn("'per_herd'", cost_sql)
        self.assertIn(f"c.herd_id = '{herd}'", cost_sql)
        self.assertIn("c.animal_id IS NULL", cost_sql)

    def test_correction_whose_cost_changed_is_refused(self) -> None:
        def runner(sql: str) -> str:
            return ""

        records = LivestockPostgresRecords(runner)
        with self.assertRaisesRegex(LivestockPostgresError, "reload"):
            records.correct_care(
                "11111111-2222-4333-8444-555555555551",
                "11111111-2222-4333-8444-555555555571",
                "2026-10-15T14:00:00Z",
                "incorrect_value",
                True,
                cost_id="11111111-2222-4333-8444-555555555581",
                cost_amount="5",
            )

    def test_correction_of_an_already_corrected_record_is_refused(self) -> None:
        def runner(sql: str) -> str:
            return ""

        records = LivestockPostgresRecords(runner)
        with self.assertRaises(LivestockPostgresError):
            records.correct_cost(
                "11111111-2222-4333-8444-555555555551",
                "11111111-2222-4333-8444-555555555571",
                "4",
                "incorrect_value",
                True,
            )

    def test_cost_for_another_animals_event_is_refused(self) -> None:
        def runner(sql: str) -> str:
            if "SELECT reason FROM ranchos.livestock_animal_retirements" in sql:
                return ""
            return ""

        records = LivestockPostgresRecords(runner)
        with self.assertRaises(LivestockPostgresError):
            records.record_cost(
                "11111111-2222-4333-8444-555555555551",
                "9",
                "",
                True,
                care_event_id="11111111-2222-4333-8444-555555555599",
            )

    def test_herd_assignment_closes_the_previous_herd(self) -> None:
        seen: list[str] = []

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT species_code" in sql:
                return "chicken"
            if "THEN 'open'" in sql:
                return "open"
            if "SELECT herd_id::text" in sql:
                return "11111111-2222-4333-8444-5555555555aa"
            if "lower(name)" in sql:
                return "development"
            return "11111111-2222-4333-8444-5555555555bb"

        records = LivestockPostgresRecords(runner)
        animal = "11111111-2222-4333-8444-555555555551"
        current = "11111111-2222-4333-8444-5555555555aa"
        other = "11111111-2222-4333-8444-5555555555bb"
        with self.assertRaises(LivestockPostgresError):
            records.assign_herd(animal, current)
        records.assign_herd(animal, other)
        sql = next(item for item in seen if "INSERT INTO ranchos.livestock_herd_assignments" in item)
        self.assertIn("ended_at = CURRENT_TIMESTAMP", sql)
        self.assertIn(other, sql)
        self.assertIn("COUNT(*) FROM closed", sql)
        with self.assertRaises(LivestockPostgresError):
            records.create_herd(" ")
        records.create_herd(" North pasture ", " Winter lot ")
        created = next(item for item in seen if "INSERT INTO ranchos.livestock_herds" in item)
        self.assertIn("'North pasture'", created)
        self.assertIn("'Winter lot'", created)
        records.assign_herd(animal, "")
        cleared = next(item for item in seen if "UPDATE ranchos.livestock_herd_assignments SET ended_at" in item)
        self.assertNotIn("INSERT INTO ranchos.livestock_herd_assignments", cleared)

    def test_retire_herd_waits_until_every_animal_is_cleared(self) -> None:
        remaining = {"count": "2"}

        def runner(sql: str) -> str:
            if "THEN 'open'" in sql:
                return "open"
            if "COUNT(*)::text" in sql:
                return remaining["count"]
            return "11111111-2222-4333-8444-5555555555bb"

        records = LivestockPostgresRecords(runner)
        herd = "11111111-2222-4333-8444-5555555555bb"
        with self.assertRaises(LivestockPostgresError) as caught:
            records.retire_herd(herd)
        self.assertIn("reassign or unassign", str(caught.exception))
        remaining["count"] = "0"
        records.retire_herd(herd)

    def test_consumption_rejects_non_positive_quantity_before_sql(self) -> None:
        records = LivestockPostgresRecords(lambda sql: "unused")
        animal = "11111111-2222-4333-8444-555555555551"
        when = "2026-10-03T14:00:00Z"
        with self.assertRaises(LivestockPostgresError):
            records.record_consumption(animal, "hay", "0", "bale", when, "", "")
        with self.assertRaises(LivestockPostgresError):
            records.record_consumption(animal, "hay", "-1", "bale", when, "", "")

    def test_create_animal_keeps_pets_without_a_breed(self) -> None:
        seen: list[str] = []

        def runner(sql: str) -> str:
            seen.append(sql)
            return "11111111-2222-4333-8444-555555555553"

        records = LivestockPostgresRecords(runner)
        with self.assertRaises(LivestockPostgresError):
            records.create_animal("Moss", "pet", "companion", "", pet_breed="mixed", mix_one="Labrador Retriever", pet_species="dog")
        self.assertEqual(seen, [])
        created = records.create_animal(
            "Moss", "pet", "companion", "", pet_breed="Labrador Retriever", pet_species="dog"
        )
        self.assertEqual(created, "11111111-2222-4333-8444-555555555553")
        self.assertIn("'Labrador Retriever'", seen[0])
        self.assertIn("'dog'", seen[0])
        records.create_animal(
            "Moss", "pet", "companion", "", pet_breed="mixed", mix_one="Labrador Retriever", mix_two="Poodle",
            pet_species="dog",
        )
        self.assertIn("'mixed'", seen[1])
        self.assertIn("'Poodle'", seen[1])
        with self.assertRaises(LivestockPostgresError):
            records.create_animal("Moss", "pet", "companion", "", pet_species="other")
        records.create_animal(
            "Nim", "pet", "companion", "", pet_breed="Silver", pet_species="other", pet_species_other="Ferret"
        )
        self.assertIn("'Ferret'", seen[-1])
        records.create_animal("Clover", "cattle", "beef", "angus")
        self.assertIn("'angus'", seen[-1])

    def test_pet_retirement_is_rehomed_deceased_or_lost(self) -> None:
        species = {"value": "pet"}
        seen: list[str] = []

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT species_code" in sql:
                return species["value"]
            return "11111111-2222-4333-8444-555555555561"

        records = LivestockPostgresRecords(runner)
        animal = "11111111-2222-4333-8444-555555555551"
        identifier = "11111111-2222-4333-8444-555555555561"
        records.retire_identifier(animal, identifier, "rehomed")
        self.assertIn("'rehomed'", seen[-1])
        with self.assertRaises(LivestockPostgresError):
            records.retire_identifier(animal, identifier, "replaced")
        species["value"] = "cattle"
        with self.assertRaises(LivestockPostgresError):
            records.retire_identifier(animal, identifier, "rehomed")
        records.retire_identifier(animal, identifier, "sold")
        self.assertIn("'sold'", seen[-1])
        records.retire_identifier(animal, identifier, "processed")
        self.assertIn("'processed'", seen[-1])
        with self.assertRaises(LivestockPostgresError):
            records.retire_identifier(animal, identifier, "replaced")
        before = len(seen)
        with self.assertRaises(LivestockPostgresError):
            records.retire_animal(animal, "sold")
        records.retire_animal(animal, "sold", "1200", "2026-10-04")
        self.assertIn("livestock_animal_retirements", seen[-1])
        self.assertIn("1200", seen[-1])
        self.assertIn("2026-10-04", seen[-1])
        self.assertNotIn("animal_identifiers", seen[-1])
        self.assertGreater(len(seen), before)
        species["value"] = "pet"
        records.retire_animal(animal, "rehomed")
        self.assertIn("'rehomed'", seen[-1])
        with self.assertRaises(LivestockPostgresError):
            records.retire_animal(animal, "sold")

    def test_classification_updates_production_and_breed_for_livestock_only(self) -> None:
        seen: list[str] = []
        species = {"value": "pet"}
        animal = "11111111-2222-4333-8444-555555555551"

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT species_code" in sql:
                return species["value"]
            return animal.lower()

        records = LivestockPostgresRecords(runner)
        with self.assertRaises(LivestockPostgresError):
            records.update_classification(animal, "dairy", "holstein")
        self.assertFalse(any("UPDATE ranchos.livestock_animals" in sql for sql in seen))
        species["value"] = "dairy_cow"
        with self.assertRaises(LivestockPostgresError):
            records.update_classification(animal, "dairy", "angus")
        self.assertFalse(any("UPDATE ranchos.livestock_animals" in sql for sql in seen))
        records.update_classification(animal, "dairy", "holstein")
        saved = seen[-1]
        self.assertIn("UPDATE ranchos.livestock_animals", saved)
        self.assertIn("production_type_code", saved)
        self.assertIn("'dairy'", saved)
        self.assertIn("'holstein'", saved)
        self.assertIn("species_code <> 'pet'", saved)
        self.assertNotIn("SET species_code", saved)
        records.update_classification(animal, "breeding", "")
        self.assertIn("breed_code = NULL", seen[-1])

    def test_rename_trims_names_and_rejects_a_duplicate_herd(self) -> None:
        seen: list[str] = []
        animal = "11111111-2222-4333-8444-555555555551"
        herd = "11111111-2222-4333-8444-555555555561"
        duplicate = {"value": ""}

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT CASE WHEN retired_at" in sql:
                return "retired"
            if "lower(name)" in sql:
                return duplicate["value"]
            if "SELECT species_code" in sql:
                return "pet"
            return animal

        records = LivestockPostgresRecords(runner)
        with self.assertRaises(LivestockPostgresError):
            records.rename_animal(animal, "   ")
        self.assertFalse(any("SET display_name" in sql for sql in seen))
        records.rename_animal(animal, "  Laniey  ")
        renamed = next(sql for sql in seen if "SET display_name" in sql)
        self.assertIn("'Laniey'", renamed)
        self.assertIn(animal, renamed)
        with self.assertRaises(LivestockPostgresError):
            records.rename_herd(herd, " ")
        self.assertFalse(any("SET name =" in sql for sql in seen))
        records.rename_herd(herd, "  North Field  ")
        herd_sql = next(sql for sql in seen if "SET name =" in sql)
        self.assertIn("'North Field'", herd_sql)
        self.assertIn(herd, herd_sql)
        duplicate["value"] = "22222222-2222-4333-8444-555555555562"
        with self.assertRaisesRegex(LivestockPostgresError, "already used"):
            records.rename_herd(herd, "West Field")

    def test_feed_accepts_species_rations_and_care_detail_can_be_blank(self) -> None:
        seen: list[str] = []
        animal = "11111111-2222-4333-8444-555555555551"

        def runner(sql: str) -> str:
            seen.append(sql)
            if "SELECT reason FROM ranchos.livestock_animal_retirements" in sql:
                return ""
            return animal

        records = LivestockPostgresRecords(runner)
        records.record_consumption(animal, "corn", "1", "scoop", "2026-10-13T14:00:00Z", "", "", "daily")
        saved = seen[-1]
        self.assertIn("'corn'", saved)
        self.assertIn("'scoop'", saved)
        records.record_consumption(animal, "prepared_meal", "1", "cup", "2026-10-13T14:00:00Z", "", "", "daily")
        self.assertIn("'cup'", seen[-1])
        records.record_care(animal, "vaccination", "2026-10-13T14:00:00Z", True, "  CDT  ", "")
        shot = seen[-1]
        self.assertIn("'CDT'", shot)
        self.assertIn("NULL", shot)
        records.record_care(animal, "medication_administration", "2026-10-13T15:00:00Z", True, "", "pills")
        medicine = seen[-1]
        self.assertIn("'pills'", medicine)
        with self.assertRaisesRegex(LivestockPostgresError, "too long"):
            records.record_care(animal, "vaccination", "2026-10-13T14:00:00Z", True, "x" * 81, "")
        with self.assertRaises(LivestockPostgresError):
            records.record_consumption(animal, "corn", "1", "flake", "2026-10-13T14:00:00Z", "", "", "daily")

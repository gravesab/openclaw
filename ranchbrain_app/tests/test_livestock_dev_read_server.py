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
from ranchbrain.livestock_dev_read_server import (
    ANIMALS_PATH,
    LOOPBACK_HOST,
    LivestockDevReadServerError,
    create_server,
    require_loopback,
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

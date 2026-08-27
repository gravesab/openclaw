#!/usr/bin/env python3
"""Focused DEV regression contracts for isolated mobile work-request intake."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

API_DIR = Path(__file__).resolve().parents[1] / "api"
API_KEY = "work-request-test-key"
REVIEW_KEY = "work-request-review-key"
SERVER_SUBMITTER = "dev-api-submitters"
SERVER_REVIEWER = "propertymanager-review-api-key"


def _load_app():
    with mock.patch.dict(os.environ, {
        "PROPERTYMANAGER_AUTH_DISABLED": "0", "PROPERTYMANAGER_API_KEY": API_KEY,
        "PROPERTYMANAGER_REVIEW_API_KEY": REVIEW_KEY, "PROPERTYMANAGER_DEV_SUBMITTER_ID": SERVER_SUBMITTER,
        "PROPERTYMANAGER_DEV_REVIEW_PRINCIPAL": SERVER_REVIEWER, "PROPERTYMANAGER_DB_VIA_DOCKER": "1",
    }, clear=False):
        if str(API_DIR) not in sys.path:
            sys.path.insert(0, str(API_DIR))
        for name in ("auth", "db", "errors", "decimal_utils", "meter_schedule", "assets_api",
                     "mapping_proposals", "maintenance_proposals", "work_requests", "propertymanager_api"):
            sys.modules.pop(name, None)
        import auth
        import propertymanager_api as api
        auth.AUTH_DISABLED = False
        auth.API_KEY = API_KEY
        auth.REVIEW_API_KEY = REVIEW_KEY
        return api


def stored_request(**overrides):
    row = {"id": "00000000-0000-0000-0000-000000000001", "area": "North barn", "item": "Work request",
           "task_description": "Water line is leaking", "asset_id": None, "category_name": "House", "priority": "Medium",
           "intake_state": "submitted", "submitted_by": SERVER_SUBMITTER, "submitted_at": "2026-08-26T12:00:00+00:00",
           "triaged_by": None, "triaged_at": None, "triage_reason": None, "converted_task_id": None,
           "intake_idempotency_key": "retry-1"}
    row.update(overrides)
    return row


class WorkRequestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = _load_app()
        cls.client = cls.api.app.test_client()

    @staticmethod
    def headers(*, review=False, idem="retry-1", forged="caller-controlled-display-name"):
        return {"Authorization": f"Bearer {REVIEW_KEY if review else API_KEY}", "X-Operator-Identity": forged,
                "Idempotency-Key": idem}

    @staticmethod
    def payload(**overrides):
        value = {"description": "Water line is leaking behind the wash rack.", "area": "North barn",
                 "materials": [{"name": "PVC fitting", "quantity": 2, "unit": "each", "note": "draft only"}],
                 "attachment_ids": []}
        value.update(overrides)
        return value

    def test_submission_requires_authentication_before_validation(self):
        response = self.client.post("/v1/work-requests", json=self.payload(), headers={"Idempotency-Key": "x"})
        self.assertEqual(response.status_code, 401)

    def test_duplicate_request_retry_returns_original_without_write(self):
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=stored_request()), \
             mock.patch.object(self.api.pm_db, "execute") as execute:
            response = self.client.post("/v1/work-requests", json=self.payload(), headers=self.headers())
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.get_json()["idempotent_replay"])
        execute.assert_not_called()

    def test_submission_is_one_atomic_write_with_draft_provenance(self):
        with mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=[None, stored_request()]) as query, \
             mock.patch.object(self.api.pm_db, "execute_top_level_one_json", return_value={"id": "created"}) as mutation, \
             mock.patch.object(self.api.pm_db, "execute") as execute:
            response = self.client.post("/v1/work-requests", json=self.payload(), headers=self.headers())
        self.assertEqual(response.status_code, 201)
        execute.assert_not_called()
        sql = mutation.call_args.args[0]
        for token in ("created_request", "intake_event", "draft_material_0", "'request_draft'"):
            self.assertIn(token, sql)
        self.assertIn("SELECT row_to_json(created_request)", sql)
        self.assertNotIn("1 / 0", sql)
        self.assertNotIn("maintenance_completions", sql)

    def test_top_level_mutation_helper_does_not_wrap_write_cte(self):
        completed = mock.Mock(returncode=0, stdout='{"id":"created"}\n')
        with mock.patch.object(self.api.pm_db, "_docker_psql", return_value=completed) as psql:
            result = self.api.pm_db.execute_top_level_one_json(
                "WITH created AS (INSERT INTO example VALUES (%s) RETURNING id) "
                "SELECT row_to_json(created) FROM created",
                ("value",),
            )

        self.assertEqual(result, {"id": "created"})
        executed_sql = psql.call_args.args[0]
        self.assertTrue(executed_sql.startswith("WITH created AS"))
        self.assertNotIn("FROM (WITH", executed_sql)

    def test_failed_atomic_submission_leaves_no_replayable_partial_request(self):
        with mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=[None, None]), \
             mock.patch.object(self.api.pm_db, "execute_top_level_one_json", side_effect=RuntimeError("simulated")), \
             mock.patch.object(self.api.pm_db, "execute") as execute:
            response = self.client.post("/v1/work-requests", json=self.payload(), headers=self.headers())
        self.assertEqual(response.status_code, 500)
        execute.assert_not_called()

    def test_duplicate_attachment_ids_are_rejected_before_durable_write(self):
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=None) as query, \
             mock.patch.object(self.api.pm_db, "execute") as execute:
            response = self.client.post("/v1/work-requests", json=self.payload(attachment_ids=["same", "same"]), headers=self.headers())
        self.assertEqual(response.status_code, 400)
        self.assertEqual(query.call_count, 1)
        execute.assert_not_called()

    def test_attachment_allocation_and_upload_retry_are_idempotent_and_metadata_safe(self):
        attachment_id = "00000000-0000-0000-0000-000000000002"
        existing = {"id": attachment_id, "content_type": "image/jpeg", "max_bytes": 1024}
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=existing), \
             mock.patch.object(self.api.pm_db, "execute") as execute:
            replay = self.client.post("/v1/work-requests/attachments", json={"content_type": "image/jpeg", "byte_size": 1024},
                                      headers=self.headers(idem="photo-1"))
        self.assertEqual(replay.status_code, 200)
        self.assertTrue(replay.get_json()["idempotent_replay"])
        self.assertNotIn("storage", replay.get_json())
        execute.assert_not_called()

        operation = {**existing, "created_by": SERVER_SUBMITTER, "state": "issued", "expires_at": "2999-01-01T00:00:00+00:00",
                     "allocation_idempotency_key": "photo-1"}
        jpeg = b"\xff\xd8\xff\xe1\x00\x09ExifGPS\xff\xdaimage-data"
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=operation), \
                 mock.patch.object(self.api.pm_db, "execute", return_value=1), \
                 mock.patch.object(sys.modules["work_requests"], "_attachment_root", return_value=Path(tmp)):
                uploaded = self.client.put(f"/v1/work-requests/attachments/{attachment_id}/content", data=jpeg,
                                           content_type="image/jpeg", headers=self.headers(idem="photo-1"))
                self.assertEqual(uploaded.status_code, 200, uploaded.get_json())
                saved = (Path(tmp) / f"{attachment_id}.jpg").read_bytes()
        self.assertNotIn(b"ExifGPS", saved)
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value={**operation, "state": "uploaded"}), \
             mock.patch.object(self.api.pm_db, "execute") as execute:
            retry = self.client.put(f"/v1/work-requests/attachments/{attachment_id}/content", data=jpeg,
                                    content_type="image/jpeg", headers=self.headers(idem="photo-1"))
        self.assertEqual(retry.status_code, 200)
        self.assertTrue(retry.get_json()["idempotent_replay"])
        execute.assert_not_called()

    def test_untriaged_request_cannot_enter_completion_or_asset_output(self):
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value={"id": "r", "kind": "Work Request", "intake_state": "submitted"}), \
             mock.patch.object(self.api.ms, "complete_task_meter") as complete_meter:
            response = self.client.post("/tasks/r/complete", json={}, headers=self.headers())
        self.assertEqual(response.status_code, 409)
        complete_meter.assert_not_called()
        assets_api = sys.modules["assets_api"]
        with mock.patch.object(assets_api.pm_db, "execute_json", return_value=[]) as query:
            assets_api.enrich_asset({
                "id": "asset", "current_value": "0", "latest_reading_at": None, "meter_type": "none",
                "unit": "", "meter_epoch": 1, "row_version": 1, "meter_activated_at": None,
            })
        self.assertIn("kind <> 'Work Request'", query.call_args.args[0])

    def test_forged_review_header_never_becomes_triage_or_conversion_actor(self):
        triaged = stored_request(intake_state="triaged", asset_id="asset", category_name="Property", priority="High")
        with mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=[stored_request(), triaged]), \
             mock.patch.object(self.api.pm_db, "execute_top_level_one_json", return_value={"id": "r"}) as mutation:
            response = self.client.post("/v1/work-requests/r/triage", json={"area": "North barn", "asset_id": "asset",
                                        "category_name": "Property", "priority": "High", "reason": "Verified"},
                                        headers=self.headers(review=True, forged="forged-reviewer"))
        self.assertEqual(response.status_code, 200)
        triage_sql, triage_params = mutation.call_args.args
        self.assertIn("triaged_request", triage_sql)
        self.assertIn(SERVER_REVIEWER, repr(triage_params))
        self.assertNotIn("forged-reviewer", repr(triage_params))

        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=triaged), \
             mock.patch.object(self.api.pm_db, "execute_top_level_one_json", return_value={"id": "scheduled"}) as mutation:
            conversion = self.client.post("/v1/work-requests/r/convert", headers=self.headers(review=True, forged="forged-reviewer"))
        self.assertEqual(conversion.status_code, 200)
        sql, params = mutation.call_args.args
        self.assertIn("claimed_request", sql)
        self.assertIn("WHERE id = %s AND kind = 'Work Request' AND intake_state = 'triaged'", sql)
        self.assertIn(SERVER_REVIEWER, repr(params))
        self.assertNotIn("forged-reviewer", repr(params))

    def test_concurrent_triage_claim_creates_one_state_event(self):
        triaged = stored_request(intake_state="triaged")
        with mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=[stored_request(), triaged, stored_request()]), \
             mock.patch.object(self.api.pm_db, "execute_top_level_one_json", side_effect=[{"id": "r"}, None]) as mutation:
            first = self.client.post("/v1/work-requests/r/triage", json={"area": "North barn", "asset_id": "asset",
                                     "category_name": "Property", "priority": "High", "reason": "Verified"},
                                     headers=self.headers(review=True))
            second = self.client.post("/v1/work-requests/r/triage", json={"area": "North barn", "asset_id": "asset",
                                      "category_name": "Property", "priority": "High", "reason": "Verified"},
                                      headers=self.headers(review=True))
        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 409)
        claims = [call.args[0] for call in mutation.call_args_list if "triaged_request" in call.args[0]]
        self.assertEqual(len(claims), 2)
        self.assertIn("INSERT INTO propertymanager.maintenance_task_intake_events", claims[0])

    def test_concurrent_conversion_claim_allows_exactly_one_scheduled_task(self):
        converted = stored_request(intake_state="converted", converted_task_id="scheduled")
        with mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=[converted, converted]), \
             mock.patch.object(self.api.pm_db, "execute_top_level_one_json", side_effect=[{"id": "scheduled"}, None]) as mutation:
            first = self.client.post("/v1/work-requests/r/convert", headers=self.headers(review=True))
            second = self.client.post("/v1/work-requests/r/convert", headers=self.headers(review=True))
        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 409)
        claim_queries = [call.args[0] for call in mutation.call_args_list if "claimed_request" in call.args[0]]
        self.assertEqual(len(claim_queries), 2)
        self.assertIn("UPDATE propertymanager.maintenance_tasks", claim_queries[0])


if __name__ == "__main__":
    unittest.main()

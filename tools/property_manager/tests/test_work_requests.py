#!/usr/bin/env python3
"""Focused DEV contracts for isolated mobile work-request intake."""

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


def _load_app():
    with mock.patch.dict(os.environ, {
        "PROPERTYMANAGER_AUTH_DISABLED": "0",
        "PROPERTYMANAGER_API_KEY": API_KEY,
        "PROPERTYMANAGER_REVIEW_API_KEY": REVIEW_KEY,
        "PROPERTYMANAGER_DEV_SUBMITTER_ID": "server-derived-dev-submitter",
        "PROPERTYMANAGER_DB_VIA_DOCKER": "1",
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
    row = {
        "id": "00000000-0000-0000-0000-000000000001", "area": "North barn", "item": "Work request",
        "task_description": "Water line is leaking", "asset_id": None, "category_name": "House",
        "priority": "Medium", "intake_state": "submitted", "submitted_by": "server-derived-dev-submitter",
        "submitted_at": "2026-08-26T12:00:00+00:00", "triaged_by": None, "triaged_at": None,
        "triage_reason": None, "converted_task_id": None, "intake_idempotency_key": "retry-1",
    }
    row.update(overrides)
    return row


class WorkRequestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = _load_app()
        cls.client = cls.api.app.test_client()

    @staticmethod
    def headers(*, review=False, idem="retry-1"):
        return {
            "Authorization": f"Bearer {REVIEW_KEY if review else API_KEY}",
            "X-Operator-Identity": "caller-controlled-display-name",
            "Idempotency-Key": idem,
        }

    @staticmethod
    def payload():
        return {
            "description": "Water line is leaking behind the wash rack.",
            "area": "North barn",
            "materials": [{"name": "PVC fitting", "quantity": 2, "unit": "each", "note": "draft only"}],
            "attachment_ids": [],
        }

    def test_submission_requires_authentication_before_validation(self):
        response = self.client.post("/v1/work-requests", json=self.payload(), headers={"Idempotency-Key": "x"})
        self.assertEqual(response.status_code, 401)

    def test_duplicate_retry_returns_original_without_write(self):
        with (
            mock.patch.object(self.api.pm_db, "execute_one_json", return_value=stored_request()),
            mock.patch.object(self.api.pm_db, "execute") as execute,
        ):
            response = self.client.post("/v1/work-requests", json=self.payload(), headers=self.headers())
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.get_json()["idempotent_replay"])
        execute.assert_not_called()

    def test_submission_uses_server_submitter_and_draft_provenance(self):
        created = stored_request()
        with (
            mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=[None, created]),
            mock.patch.object(self.api.pm_db, "execute", return_value=1) as execute,
        ):
            response = self.client.post("/v1/work-requests", json=self.payload(), headers=self.headers())
        self.assertEqual(response.status_code, 201)
        calls = "\n".join(str(call.args[0]) for call in execute.call_args_list)
        self.assertIn("'Work Request'", calls)
        self.assertIn("'submitted'", calls)
        self.assertIn("'request_draft'", calls)
        self.assertNotIn("maintenance_completions", calls)
        self.assertNotIn("inventory", calls.lower())
        self.assertNotIn("finance", calls.lower())
        flattened = repr(execute.call_args_list)
        self.assertIn("dev-api-submitters", flattened)
        self.assertNotIn("caller-controlled-display-name", flattened)

    def test_attachment_issue_and_upload_never_expose_storage_metadata(self):
        operation = {"id": "00000000-0000-0000-0000-000000000002", "created_by": "dev-api-submitters",
                     "content_type": "image/jpeg", "max_bytes": 1024, "state": "issued", "expires_at": "2999-01-01T00:00:00+00:00"}
        with mock.patch.object(self.api.pm_db, "execute", return_value=1):
            issue = self.client.post("/v1/work-requests/attachments", json={"content_type": "image/jpeg", "byte_size": 1024}, headers=self.headers())
        self.assertEqual(issue.status_code, 201)
        self.assertNotIn("storage", issue.get_json())
        # APP1 holds EXIF metadata; the sanitizer removes it before durable write.
        jpeg = b"\xff\xd8\xff\xe1\x00\x09ExifGPS\xff\xdaimage-data"
        with tempfile.TemporaryDirectory() as tmp:
            with (
                mock.patch.object(self.api.pm_db, "execute_one_json", return_value=operation),
                mock.patch.object(self.api.pm_db, "execute", return_value=1),
                mock.patch.object(sys.modules["work_requests"], "_attachment_root", return_value=Path(tmp)),
            ):
                response = self.client.put("/v1/work-requests/attachments/00000000-0000-0000-0000-000000000002/content", data=jpeg,
                                           content_type="image/jpeg", headers=self.headers())
                self.assertEqual(response.status_code, 200, response.get_json())
                saved = (Path(tmp) / "00000000-0000-0000-0000-000000000002.jpg").read_bytes()
        self.assertNotIn("storage", response.get_json())
        self.assertNotIn(b"ExifGPS", saved)

    def test_unauthorized_photo_upload_is_denied(self):
        response = self.client.put("/v1/work-requests/attachments/00000000-0000-0000-0000-000000000002/content", data=b"x", content_type="image/jpeg")
        self.assertEqual(response.status_code, 401)

    def test_untriaged_request_cannot_enter_completion_or_meter_workflow(self):
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value={"id": "r", "kind": "Work Request", "intake_state": "submitted"}), \
             mock.patch.object(self.api.ms, "complete_task_meter") as complete_meter:
            response = self.client.post("/tasks/r/complete", json={}, headers=self.headers())
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.get_json()["code"], "INTAKE_NOT_MAINTENANCE")
        complete_meter.assert_not_called()

    def test_triage_and_conversion_preserve_original_report_and_provenance(self):
        triaged = stored_request(intake_state="triaged", asset_id="00000000-0000-0000-0000-000000000099", category_name="Property", priority="High")
        with (
            mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=[stored_request(), triaged, triaged, triaged]),
            mock.patch.object(self.api.pm_db, "execute", return_value=1) as execute,
            mock.patch.object(self.api.pm_db, "execute_script") as script,
        ):
            triage = self.client.post("/v1/work-requests/00000000-0000-0000-0000-000000000001/triage", json={
                "area": "North barn", "asset_id": "00000000-0000-0000-0000-000000000099", "category_name": "Property", "priority": "High", "reason": "Verified on site"}, headers=self.headers(review=True))
            conversion = self.client.post("/v1/work-requests/00000000-0000-0000-0000-000000000001/convert", headers=self.headers(review=True))
        self.assertEqual(triage.status_code, 200)
        self.assertEqual(conversion.status_code, 200)
        triage_sql = "\n".join(str(call.args[0]) for call in execute.call_args_list)
        self.assertNotIn("task_description =", triage_sql)
        self.assertNotIn("maintenance_task_photos", triage_sql)
        self.assertNotIn("maintenance_task_parts", triage_sql)
        conversion_sql = repr(script.call_args)
        self.assertIn("maintenance_tasks", conversion_sql)
        self.assertNotIn("maintenance_task_photos", conversion_sql)
        self.assertNotIn("maintenance_task_parts", conversion_sql)


if __name__ == "__main__":
    unittest.main()

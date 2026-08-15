#!/usr/bin/env python3
"""In-process contract tests for the model proposal review queue."""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest import mock

API_DIR = Path(__file__).resolve().parents[1] / "api"
TEST_API_KEY = "test-maintenance-proposal-key"
TEST_REVIEW_API_KEY = "test-maintenance-review-key"


def proposal(disposition: str = "completed_work") -> dict:
    return {
        "disposition": disposition,
        "title": "Air filter replacement",
        "performed_on": "2026-08-10" if disposition != "planned_work" else None,
        "scheduled_for": "2026-08-20" if disposition == "planned_work" else None,
        "location": "North Barn",
        "action": "Replaced the air filter",
        "confidence": 0.95,
        "reason": "Explicit maintenance statement",
    }


def envelope(disposition: str = "completed_work") -> dict:
    return {
        "operation_id": "maintenance-boundary-v1",
        "schema_version": "1",
        "source_evidence_ref": "evidence://maintenance/abc123",
        "provider": "omlx",
        "model": "Qwen3.5-9B-4bit",
        "proposal": proposal(disposition),
        "guardrail_actions": [],
        "validation_status": "valid",
    }


def _load_app():
    with mock.patch.dict(
        os.environ,
        {
            "PROPERTYMANAGER_AUTH_DISABLED": "0",
            "PROPERTYMANAGER_API_KEY": TEST_API_KEY,
            "PROPERTYMANAGER_REVIEW_API_KEY": TEST_REVIEW_API_KEY,
            "PROPERTYMANAGER_DB_VIA_DOCKER": "1",
        },
        clear=False,
    ):
        if str(API_DIR) not in sys.path:
            sys.path.insert(0, str(API_DIR))
        for name in (
            "auth",
            "db",
            "errors",
            "decimal_utils",
            "meter_schedule",
            "assets_api",
            "mapping_proposals",
            "maintenance_proposals",
            "propertymanager_api",
        ):
            sys.modules.pop(name, None)
        import auth
        import propertymanager_api as api

        auth.AUTH_DISABLED = False
        auth.API_KEY = TEST_API_KEY
        auth.REVIEW_API_KEY = TEST_REVIEW_API_KEY
        return api


class MaintenanceProposalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.api = _load_app()
        cls.client = cls.api.app.test_client()

    def headers(self, *, integration: bool = True) -> dict[str, str]:
        result = {
            "Authorization": f"Bearer {TEST_API_KEY}",
            "X-Operator-Identity": "andy",
            "Idempotency-Key": "idem-1",
        }
        if integration:
            result["X-Integration-Identity"] = "m4-omlx-router"
        return result

    def review_headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {TEST_REVIEW_API_KEY}",
            "X-Operator-Identity": "andy",
        }

    def stored(self, *, status: str = "pending", disposition: str = "completed_work") -> dict:
        return {
            "id": "00000000-0000-0000-0000-000000000001",
            "proposal_version": 1,
            "operation_id": "maintenance-boundary-v1",
            "schema_version": "1",
            "source_evidence_ref": "evidence://maintenance/abc123",
            "provider": "omlx",
            "model": "Qwen3.5-9B-4bit",
            "model_output": proposal(disposition),
            "guardrail_actions": [],
            "validation_status": "valid",
            "status": status,
            "created_by": "m4-omlx-router",
            "integration_identity": "m4-omlx-router",
            "idempotency_key": "idem-1",
            "reviewed_by": None,
            "reviewed_at": None,
            "rejection_reason": None,
        }

    def test_submission_requires_authentication(self) -> None:
        response = self.client.post(
            "/v1/maintenance-proposals",
            json=envelope(),
            headers={"Idempotency-Key": "idem-1"},
        )
        self.assertEqual(response.status_code, 401)

    def test_submission_requires_idempotency_key(self) -> None:
        headers = self.headers()
        headers.pop("Idempotency-Key")
        response = self.client.post("/v1/maintenance-proposals", json=envelope(), headers=headers)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.get_json()["field"], "Idempotency-Key")

    def test_submission_requires_integration_identity(self) -> None:
        response = self.client.post(
            "/v1/maintenance-proposals",
            json=envelope(),
            headers=self.headers(integration=False),
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.get_json()["field"], "X-Integration-Identity")

    def test_submission_stores_only_pending_proposal(self) -> None:
        row = self.stored()
        with (
            mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=[None, row]),
            mock.patch.object(self.api.pm_db, "execute", return_value=1) as execute,
        ):
            response = self.client.post(
                "/v1/maintenance-proposals", json=envelope(), headers=self.headers()
            )
        self.assertEqual(response.status_code, 201)
        sql = execute.call_args.args[0]
        self.assertIn("maintenance_proposals", sql)
        self.assertNotIn("maintenance_tasks", sql)
        self.assertEqual(response.get_json()["status"], "pending")

    def test_idempotent_replay_does_not_insert(self) -> None:
        row = self.stored()
        with (
            mock.patch.object(
                self.api.pm_db,
                "execute_one_json",
                side_effect=[{"id": row["id"]}, row],
            ),
            mock.patch.object(self.api.pm_db, "execute") as execute,
        ):
            response = self.client.post(
                "/v1/maintenance-proposals", json=envelope(), headers=self.headers()
            )
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.get_json()["idempotent_replay"])
        execute.assert_not_called()

    def test_concurrent_idempotent_insert_returns_replay(self) -> None:
        row = self.stored()
        with (
            mock.patch.object(
                self.api.pm_db,
                "execute_one_json",
                side_effect=[None, {"id": row["id"]}, row],
            ),
            mock.patch.object(self.api.pm_db, "execute", return_value=0),
        ):
            response = self.client.post(
                "/v1/maintenance-proposals", json=envelope(), headers=self.headers()
            )
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.get_json()["idempotent_replay"])

    def test_review_queue_reads_require_authentication(self) -> None:
        self.assertEqual(self.client.get("/v1/maintenance-proposals").status_code, 401)
        self.assertEqual(self.client.get("/v1/maintenance-proposals/example").status_code, 401)

    def test_confirmation_requires_exact_version(self) -> None:
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=self.stored()):
            response = self.client.post(
                "/v1/maintenance-proposals/00000000-0000-0000-0000-000000000001/confirm",
                json={"proposal_version": 2},
                headers=self.review_headers(),
            )
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.get_json()["code"], "STALE_PROPOSAL_VERSION")

    def test_needs_review_cannot_be_confirmed(self) -> None:
        with mock.patch.object(
            self.api.pm_db,
            "execute_one_json",
            return_value=self.stored(disposition="needs_review"),
        ):
            response = self.client.post(
                "/v1/maintenance-proposals/00000000-0000-0000-0000-000000000001/confirm",
                json={"proposal_version": 1},
                headers=self.review_headers(),
            )
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.get_json()["code"], "PROPOSAL_NOT_CONFIRMABLE")

    def test_confirmation_never_mutates_maintenance_tasks(self) -> None:
        pending = self.stored()
        confirmed = self.stored(status="confirmed")
        with (
            mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=[pending, confirmed]),
            mock.patch.object(self.api.pm_db, "execute", return_value=1) as execute,
        ):
            response = self.client.post(
                "/v1/maintenance-proposals/00000000-0000-0000-0000-000000000001/confirm",
                json={"proposal_version": 1},
                headers=self.review_headers(),
            )
        self.assertEqual(response.status_code, 200)
        sql = execute.call_args.args[0]
        self.assertIn("maintenance_proposals", sql)
        self.assertNotIn("maintenance_tasks", sql)

    def test_concurrent_confirmation_returns_conflict(self) -> None:
        with (
            mock.patch.object(self.api.pm_db, "execute_one_json", return_value=self.stored()),
            mock.patch.object(self.api.pm_db, "execute", return_value=0),
        ):
            response = self.client.post(
                "/v1/maintenance-proposals/00000000-0000-0000-0000-000000000001/confirm",
                json={"proposal_version": 1},
                headers=self.review_headers(),
            )
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.get_json()["code"], "PROPOSAL_REVIEW_CONFLICT")

    def test_model_credential_cannot_confirm(self) -> None:
        response = self.client.post(
            "/v1/maintenance-proposals/00000000-0000-0000-0000-000000000001/confirm",
            json={"proposal_version": 1},
            headers=self.headers(),
        )
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.get_json()["code"], "UNAUTHORIZED_REVIEW")

    def test_shared_model_and_review_credential_fails_closed(self) -> None:
        with mock.patch.object(sys.modules["auth"], "REVIEW_API_KEY", TEST_API_KEY):
            response = self.client.post(
                "/v1/maintenance-proposals/00000000-0000-0000-0000-000000000001/confirm",
                json={"proposal_version": 1},
                headers=self.headers(),
            )
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.get_json()["code"], "REVIEW_AUTH_NOT_CONFIGURED")

    def test_rejection_requires_reason(self) -> None:
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=self.stored()):
            response = self.client.post(
                "/v1/maintenance-proposals/00000000-0000-0000-0000-000000000001/reject",
                json={"proposal_version": 1},
                headers=self.review_headers(),
            )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.get_json()["field"], "reason")


if __name__ == "__main__":
    unittest.main()

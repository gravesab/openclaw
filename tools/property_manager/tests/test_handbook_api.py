#!/usr/bin/env python3
"""Focused contracts for the Dashboard-owned PropertyManager manual library."""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest import mock

API_DIR = Path(__file__).resolve().parents[1] / "api"
API_KEY = "handbook-test-api-key"
LIBRARY_TOKEN = "dashboard-library-test-token"


def _load_app():
    with mock.patch.dict(
        os.environ,
        {
            "PROPERTYMANAGER_AUTH_DISABLED": "0",
            "PROPERTYMANAGER_API_KEY": API_KEY,
            "PROPERTYMANAGER_REVIEW_API_KEY": "review-key",
            "PROPERTYMANAGER_MANUAL_LIBRARY_SERVICE_TOKEN": LIBRARY_TOKEN,
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
            "work_requests",
            "handbook_api",
            "propertymanager_api",
        ):
            sys.modules.pop(name, None)
        import propertymanager_api as api

        return api


class HandbookAPITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = _load_app()
        cls.client = cls.api.app.test_client()

    @staticmethod
    def app_headers():
        return {"Authorization": f"Bearer {API_KEY}"}

    @staticmethod
    def dashboard_headers():
        return {"X-PropertyManager-Manual-Library-Token": LIBRARY_TOKEN}

    @staticmethod
    def asset():
        return {"id": "asset-1", "name": "Polaris Ranger"}

    @staticmethod
    def stored_manual(**overrides):
        value = {
            "manual_id": "manual-1",
            "asset_id": "asset-1",
            "title": "Ranger Owner's Manual",
            "document_type": "operator_manual",
            "manufacturer": "Polaris",
            "model_number": None,
            "version_id": "version-1",
            "version_number": 1,
            "source_display_name": "Polaris Ranger.pdf",
            "mime_type": "application/pdf",
            "ingestion_status": "pending",
            "review_status": "pending",
            "lifecycle_status": "draft",
            "created_at": "2026-09-03T12:00:00+00:00",
            "task_count": 0,
        }
        value.update(overrides)
        return value

    @staticmethod
    def registration_payload(**overrides):
        value = {
            "source_locator": "dashboard-library://Assets/polaris-ranger-0123456789ab.pdf",
            "source_display_name": "Polaris Ranger.pdf",
            "source_sha256": "a" * 64,
            "byte_size": 12345,
            "title": "Ranger Owner's Manual",
            "document_type": "operator_manual",
            "manufacturer": "Polaris",
        }
        value.update(overrides)
        return value

    def test_library_listing_requires_the_normal_app_credential(self):
        with mock.patch.object(self.api.pm_db, "execute_one_json") as query:
            response = self.client.get("/v1/assets/asset-1/manuals")
        self.assertEqual(response.status_code, 401)
        query.assert_not_called()

    def test_dashboard_registration_rejects_the_normal_app_credential(self):
        response = self.client.post(
            "/v1/internal/manual-library/assets/asset-1/manuals",
            headers=self.app_headers(),
            json=self.registration_payload(),
        )
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.get_json()["code"], "UNAUTHORIZED_MANUAL_LIBRARY")

    def test_dashboard_registration_is_metadata_only_and_returns_sanitized_record(self):
        with mock.patch.object(
            self.api.pm_db,
            "execute_one_json",
            side_effect=[self.asset(), None],
        ), mock.patch.object(
            self.api.pm_db,
            "execute_top_level_one_json",
            return_value=self.stored_manual(),
        ) as write:
            response = self.client.post(
                "/v1/internal/manual-library/assets/asset-1/manuals",
                headers=self.dashboard_headers(),
                json=self.registration_payload(),
            )
        self.assertEqual(response.status_code, 201, response.get_json())
        body = response.get_json()
        self.assertEqual(body["manual_id"], "manual-1")
        self.assertNotIn("source_locator", body)
        self.assertNotIn("source_sha256", body)
        self.assertNotIn("storage_path", body)
        sql = write.call_args.args[0]
        self.assertIn("asset_manual_state_event", sql)
        self.assertIn("Dashboard library registration", sql)
        self.assertNotIn("send_file", sql)

    def test_dashboard_registration_rejects_non_dashboard_source_locator(self):
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=self.asset()):
            response = self.client.post(
                "/v1/internal/manual-library/assets/asset-1/manuals",
                headers=self.dashboard_headers(),
                json=self.registration_payload(source_locator="/var/lib/propertymanager/manuals/ranger.pdf"),
            )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.get_json()["field"], "source_locator")

    def test_listing_never_exposes_external_locator_or_checksum(self):
        listing = self.stored_manual(
            source_locator="dashboard-library://Assets/polaris-ranger-0123456789ab.pdf",
            source_sha256="a" * 64,
        )
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=self.asset()), mock.patch.object(
            self.api.pm_db, "execute_json", return_value=[listing]
        ):
            response = self.client.get("/v1/assets/asset-1/manuals", headers=self.app_headers())
        self.assertEqual(response.status_code, 200)
        row = response.get_json()[0]
        self.assertEqual(row["task_count"], 0)
        self.assertNotIn("source_locator", row)
        self.assertNotIn("source_sha256", row)

    def test_source_resolution_is_dashboard_only(self):
        row = {
            "source_locator": "dashboard-library://Assets/polaris-ranger-0123456789ab.pdf",
            "source_display_name": "Ranger.pdf",
            "mime_type": "application/pdf",
        }
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=row):
            denied = self.client.get(
                "/v1/internal/manual-library/assets/asset-1/manuals/manual-1/versions/version-1/source",
                headers=self.app_headers(),
            )
            allowed = self.client.get(
                "/v1/internal/manual-library/assets/asset-1/manuals/manual-1/versions/version-1/source",
                headers=self.dashboard_headers(),
            )
        self.assertEqual(denied.status_code, 401)
        self.assertEqual(allowed.status_code, 200)
        self.assertEqual(allowed.get_json()["source_locator"], row["source_locator"])

    def test_local_extraction_records_chunks_without_storage_endpoint(self):
        extracted = self.stored_manual(
            ingestion_status="extracted",
            extracted_at="2026-09-03T12:30:00+00:00",
        )
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=self.stored_manual()), mock.patch.object(
            self.api.pm_db,
            "execute_top_level_one_json",
            return_value=extracted,
        ) as write:
            response = self.client.post(
                "/v1/assets/asset-1/manuals/manual-1/versions/version-1/extraction",
                headers=self.app_headers(),
                json={
                    "extractor_name": "PropertyManager Mac local Ollama",
                    "extractor_version": "qwen3:14b",
                    "chunks": [
                        {
                            "page_number": 67,
                            "section_heading": "Periodic Maintenance",
                            "content": "Change engine oil.",
                        },
                        {
                            "page_number": 72,
                            "section_heading": "Engine Oil",
                            "content": "Replace the oil filter.",
                        },
                    ],
                },
            )
        self.assertEqual(response.status_code, 200, response.get_json())
        self.assertEqual(response.get_json()["ingestion_status"], "extracted")
        self.assertNotIn("source_locator", response.get_json())
        self.assertIn("asset_manual_chunk", write.call_args.args[0])


if __name__ == "__main__":
    unittest.main()

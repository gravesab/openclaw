#!/usr/bin/env python3
"""Focused contracts for the IntelMini-owned PropertyManager manual library."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.dashboard import app as dashboard


class _Response:
    def __init__(self, payload: dict, status_code: int = 200):
        self.payload = payload
        self.status_code = status_code

    def json(self):
        return self.payload


class PropertyManagerManualLibraryTests(unittest.TestCase):
    def test_only_known_bom_is_removed_before_pdf_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manual.pdf"
            path.write_bytes(b"\xff\xfe%PDF-1.7\nbody")
            self.assertTrue(dashboard.pdf_upload_normalize_known_bom(path))
            self.assertTrue(path.read_bytes().startswith(b"%PDF-"))

            arbitrary = Path(directory) / "invalid.pdf"
            arbitrary.write_bytes(b"xx%PDF-1.7\nbody")
            self.assertFalse(dashboard.pdf_upload_normalize_known_bom(arbitrary))
            with self.assertRaises(ValueError):
                dashboard.pdf_upload_validate(arbitrary)

    def test_dashboard_source_request_never_accepts_a_traversal_locator(self):
        with mock.patch.object(
            dashboard.requests,
            "get",
            return_value=_Response({"source_locator": "dashboard-library://Assets/../secret.pdf"}),
        ), mock.patch.object(
            dashboard,
            "PROPERTYMANAGER_MANUAL_LIBRARY_SERVICE_TOKEN",
            "test-service-token",
        ):
            with self.assertRaises(ValueError):
                dashboard.propertymanager_manual_library_source("asset", "manual", "version")

    def test_dashboard_source_request_uses_the_service_token(self):
        response = _Response({"source_locator": "dashboard-library://Assets/ranger-0123456789ab.pdf"})
        with mock.patch.object(dashboard.requests, "get", return_value=response) as get, mock.patch.object(
            dashboard,
            "PROPERTYMANAGER_MANUAL_LIBRARY_SERVICE_TOKEN",
            "test-service-token",
        ):
            relative, mime_type = dashboard.propertymanager_manual_library_source("asset", "manual", "version")
        self.assertEqual(relative, "Assets/ranger-0123456789ab.pdf")
        self.assertEqual(mime_type, "application/pdf")
        self.assertEqual(
            get.call_args.kwargs["headers"]["X-PropertyManager-Manual-Library-Token"],
            "test-service-token",
        )

    def test_content_client_requires_the_existing_propertymanager_credential(self):
        with mock.patch.object(dashboard, "PROPERTYMANAGER_API_KEY", "test-client-key"):
            with dashboard.app.test_request_context(
                "/pm/manual-library/content/a/m/v",
                headers={"Authorization": "Bearer test-client-key"},
            ):
                self.assertTrue(dashboard.propertymanager_manual_library_client_authorized())
            with dashboard.app.test_request_context(
                "/pm/manual-library/content/a/m/v",
                headers={"Authorization": "Bearer wrong-key"},
            ):
                self.assertFalse(dashboard.propertymanager_manual_library_client_authorized())


if __name__ == "__main__":
    unittest.main()

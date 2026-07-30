#!/usr/bin/env python3
"""Focused API tests for PostgreSQL-backed task photographs."""

from __future__ import annotations

import io
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

API_DIR = Path(__file__).resolve().parents[1] / "api"
TEST_API_KEY = "test-photo-key"


def _load_app():
    with mock.patch.dict(
        os.environ,
        {
            "PROPERTYMANAGER_AUTH_DISABLED": "0",
            "PROPERTYMANAGER_API_KEY": TEST_API_KEY,
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
            "propertymanager_api",
        ):
            sys.modules.pop(name, None)
        import auth
        import propertymanager_api as api

        auth.AUTH_DISABLED = False
        auth.API_KEY = TEST_API_KEY
        return api


class TaskPhotoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = _load_app()
        cls.client = cls.api.app.test_client()
        cls.task_id = "00000000-0000-0000-0000-000000000001"

    @property
    def auth(self):
        return {"Authorization": f"Bearer {TEST_API_KEY}"}

    def test_upload_requires_auth_before_validation(self):
        response = self.client.post(f"/tasks/{self.task_id}/photos")
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.get_json()["code"], "UNAUTHORIZED")

    def test_delete_requires_auth(self):
        response = self.client.delete(
            f"/tasks/{self.task_id}/photos",
            json={"file_name": "photo.jpg"},
        )
        self.assertEqual(response.status_code, 401)

    def test_upload_rejects_non_image(self):
        with mock.patch.object(self.api, "fetch_task_or_404", return_value={"id": self.task_id}):
            response = self.client.post(
                f"/tasks/{self.task_id}/photos",
                data={"file": (io.BytesIO(b"not an image"), "note.txt", "text/plain")},
                headers=self.auth,
                content_type="multipart/form-data",
            )
        self.assertEqual(response.status_code, 400)

    def test_upload_persists_bytes_and_checksum(self):
        stored = {
            "id": "10000000-0000-0000-0000-000000000001",
            "task_id": self.task_id,
            "file_name": "stored.png",
            "content_type": "image/png",
            "byte_size": 8,
        }
        with (
            mock.patch.object(self.api, "fetch_task_or_404", return_value={"id": self.task_id}),
            mock.patch.object(self.api.pm_db, "execute") as execute,
            mock.patch.object(self.api.pm_db, "execute_one_json", return_value=stored),
        ):
            response = self.client.post(
                f"/tasks/{self.task_id}/photos",
                data={"file": (io.BytesIO(b"pngbytes"), "test.png", "image/png")},
                headers=self.auth,
                content_type="multipart/form-data",
            )
        self.assertEqual(response.status_code, 201)
        params = execute.call_args.args[1]
        self.assertEqual(params[5], 8)
        self.assertEqual(params[7], "cG5nYnl0ZXM=")
        self.assertEqual(len(params[6]), 64)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Task-photo route contracts without a configured DEV database."""

from __future__ import annotations

import base64
import io
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

API_DIR = Path(__file__).resolve().parents[1] / "api"
API_KEY = "task-photo-test-key"
TASK_ID = "00000000-0000-0000-0000-000000000001"
PHOTO_NAME = "00000000-0000-0000-0000-000000000002.jpg"
JPEG = b"\xff\xd8\xff\xe0\x00\x02\xff\xda" + b"photo-bytes"
SANITIZED_JPEG = b"\xff\xd8\xff\xda" + b"photo-bytes"


def _load_app():
    with mock.patch.dict(
        os.environ,
        {
            "PROPERTYMANAGER_AUTH_DISABLED": "0",
            "PROPERTYMANAGER_API_KEY": API_KEY,
            "PROPERTYMANAGER_DB_VIA_DOCKER": "1",
        },
        clear=False,
    ):
        if str(API_DIR) not in sys.path:
            sys.path.insert(0, str(API_DIR))
        for name in (
            "auth", "db", "errors", "decimal_utils", "meter_schedule", "assets_api",
            "mapping_proposals", "maintenance_proposals", "work_requests", "handbook_api",
            "propertymanager_api",
        ):
            sys.modules.pop(name, None)
        import auth
        import propertymanager_api as api

        auth.AUTH_DISABLED = False
        auth.API_KEY = API_KEY
        return api


class TaskPhotoRouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api = _load_app()
        cls.client = cls.api.app.test_client()

    @staticmethod
    def _headers() -> dict[str, str]:
        return {"Authorization": f"Bearer {API_KEY}"}

    def test_mutating_photo_routes_require_authentication(self):
        for method, path in (
            ("POST", f"/tasks/{TASK_ID}/photos"),
            ("GET", f"/tasks/{TASK_ID}/photos/content?file_name={PHOTO_NAME}"),
            ("DELETE", f"/tasks/{TASK_ID}/photos"),
        ):
            with self.subTest(method=method):
                response = self.client.open(path, method=method, json={})
                self.assertEqual(response.status_code, 401, response.get_json())
                self.assertEqual(response.get_json()["code"], "UNAUTHORIZED")

    def test_upload_stores_opaque_name_and_database_content(self):
        with mock.patch.object(self.api, "fetch_task_or_404", return_value={"id": TASK_ID}), \
             mock.patch.object(self.api.pm_db, "execute_one_json", return_value=None), \
             mock.patch.object(self.api.pm_db, "execute", return_value=1) as execute:
            response = self.client.post(
                f"/tasks/{TASK_ID}/photos",
                data={"file": (io.BytesIO(JPEG), "camera.jpg")},
                headers=self._headers(),
                content_type="multipart/form-data",
            )

        self.assertEqual(response.status_code, 201, response.get_json())
        file_name = response.get_json()["file_name"]
        self.assertRegex(file_name, self.api._TASK_PHOTO_NAME_RE)
        query, values = execute.call_args.args
        self.assertIn("content", query)
        self.assertIn("database://maintenance-task-photo/", values[3])
        self.assertEqual(values[-1], SANITIZED_JPEG)
        self.assertNotIn("camera.jpg", values)

    def test_upload_replays_existing_sanitized_content_without_duplication(self):
        with mock.patch.object(self.api, "fetch_task_or_404", return_value={"id": TASK_ID}), \
             mock.patch.object(self.api.pm_db, "execute_one_json", return_value={"file_name": PHOTO_NAME}), \
             mock.patch.object(self.api.pm_db, "execute") as execute:
            response = self.client.post(
                f"/tasks/{TASK_ID}/photos",
                data={"file": (io.BytesIO(JPEG), "camera.jpg")},
                headers=self._headers(),
                content_type="multipart/form-data",
            )

        self.assertEqual(response.status_code, 200, response.get_json())
        self.assertEqual(response.get_json(), {"file_name": PHOTO_NAME, "idempotent_replay": True})
        execute.assert_not_called()

    def test_rejects_non_image_and_oversized_photos(self):
        with mock.patch.object(self.api, "fetch_task_or_404", return_value={"id": TASK_ID}):
            rejected = self.client.post(
                f"/tasks/{TASK_ID}/photos",
                data={"file": (io.BytesIO(b"not an image"), "bad.txt")},
                headers=self._headers(),
                content_type="multipart/form-data",
            )
        self.assertEqual(rejected.status_code, 400, rejected.get_json())
        self.assertEqual(rejected.get_json()["code"], "VALIDATION_ERROR")

    def test_completion_history_boundary_rejects_oversized_entries(self):
        self.assertIsNone(self.api._completion_history_error(["Completed on 2026-09-03."]))
        self.assertEqual(
            self.api._completion_history_error(["x" * (self.api.MAX_COMPLETION_HISTORY_ENTRY_BYTES + 1)]),
            "completion_history contains an invalid or oversized entry",
        )

    def test_download_uses_opaque_id_and_never_returns_storage_path(self):
        with mock.patch.object(self.api, "fetch_task_or_404", return_value={"id": TASK_ID}), \
             mock.patch.object(
                 self.api.pm_db,
                 "execute_one_json",
                 return_value={"content_base64": base64.b64encode(JPEG).decode(), "content_type": "image/jpeg"},
             ) as execute:
            response = self.client.get(
                f"/tasks/{TASK_ID}/photos/content?file_name={PHOTO_NAME}",
                headers=self._headers(),
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, JPEG)
        self.assertEqual(response.headers["X-Content-Type-Options"], "nosniff")
        self.assertNotIn("storage_path", response.headers)

    def test_download_accepts_postgresql_base64_line_wrapping(self):
        encoded = base64.b64encode(JPEG * 20).decode()
        wrapped = "\n".join(encoded[index:index + 76] for index in range(0, len(encoded), 76))
        with mock.patch.object(self.api, "fetch_task_or_404", return_value={"id": TASK_ID}), \
             mock.patch.object(
                 self.api.pm_db,
                 "execute_one_json",
                 return_value={"content_base64": wrapped, "content_type": "image/jpeg"},
             ):
            response = self.client.get(
                f"/tasks/{TASK_ID}/photos/content?file_name={PHOTO_NAME}",
                headers=self._headers(),
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, JPEG * 20)

    def test_download_preserves_importer_photo_access_without_exposing_its_path(self):
        with mock.patch.object(self.api, "fetch_task_or_404", return_value={"id": TASK_ID}), \
             mock.patch.object(
                 self.api.pm_db,
                 "execute_one_json",
                 return_value={"content_base64": None, "content_type": None, "storage_path": "/private/legacy.jpg"},
             ), \
             mock.patch.object(self.api, "_safe_legacy_photo_bytes", return_value=JPEG) as legacy_bytes:
            response = self.client.get(
                f"/tasks/{TASK_ID}/photos/content?file_name=legacy-photo.jpg",
                headers=self._headers(),
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, JPEG)
        self.assertEqual(response.mimetype, "image/jpeg")
        self.assertNotIn("private", response.headers.get("Content-Disposition", ""))
        legacy_bytes.assert_called_once_with("/private/legacy.jpg")

    def test_legacy_filename_case_is_preserved_for_database_lookup(self):
        legacy_name = "IMG_1234.JPG"
        with mock.patch.object(self.api, "fetch_task_or_404", return_value={"id": TASK_ID}), \
             mock.patch.object(self.api.pm_db, "execute_one_json", return_value=None) as execute:
            response = self.client.get(
                f"/tasks/{TASK_ID}/photos/content?file_name={legacy_name}",
                headers=self._headers(),
            )

        self.assertEqual(response.status_code, 404)
        self.assertEqual(execute.call_args.args[1][1], legacy_name)

    def test_task_enrichment_does_not_expose_storage_paths(self):
        task = {"id": TASK_ID, "asset_id": None, "completion_history": [], "tools_required": []}
        with mock.patch.object(
            self.api.pm_db,
            "execute_json",
            side_effect=[[], [{"id": "photo", "task_id": TASK_ID, "file_name": PHOTO_NAME, "created_at": "now"}]],
        ) as execute_json:
            enriched = self.api.enrich_tasks([task])

        self.assertNotIn("storage_path", enriched[0]["photos"][0])
        self.assertNotIn("storage_path", execute_json.call_args_list[1].args[0])


if __name__ == "__main__":
    unittest.main()

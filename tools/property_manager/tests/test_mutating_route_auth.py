#!/usr/bin/env python3
"""Auth + route-shape tests for PropertyManager mutating category/task/parts routes.

These are in-process Flask tests (no live Gunicorn / postgres required).
"""

from __future__ import annotations

import importlib
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

API_DIR = Path(__file__).resolve().parents[1] / "api"
TEST_API_KEY = "test-mutating-route-key"

# Mutating category / task / parts endpoints that must require credentials.
WRITE_CASES: list[tuple[str, str, dict | list | None]] = [
    ("POST", "/categories", {"name": ""}),
    ("DELETE", "/categories/00000000-0000-0000-0000-000000000001", {}),
    ("POST", "/tasks", {}),
    ("PATCH", "/tasks/00000000-0000-0000-0000-000000000001", {"item": "x"}),
    ("DELETE", "/tasks/00000000-0000-0000-0000-000000000001", None),
    ("PUT", "/tasks/00000000-0000-0000-0000-000000000001/parts", []),
    ("POST", "/tasks/00000000-0000-0000-0000-000000000001/parts", {}),
    ("POST", "/tasks/00000000-0000-0000-0000-000000000001/complete", {}),
    (
        "POST",
        "/tasks/00000000-0000-0000-0000-000000000001/completions/"
        "10000000-0000-0000-0000-000000000001/acknowledge",
        {},
    ),
    (
        "POST",
        "/tasks/00000000-0000-0000-0000-000000000001/completions/"
        "10000000-0000-0000-0000-000000000001/undo",
        {},
    ),
]


def _load_app():
    """Import the Flask app with auth enabled and a known API key."""
    env = {
        "PROPERTYMANAGER_AUTH_DISABLED": "0",
        "PROPERTYMANAGER_API_KEY": TEST_API_KEY,
        "PROPERTYMANAGER_DB_VIA_DOCKER": "1",
    }
    with mock.patch.dict(os.environ, env, clear=False):
        # Ensure API modules resolve from tools/property_manager/api.
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
            if name in sys.modules:
                del sys.modules[name]
        import auth  # noqa: F401
        import propertymanager_api as api

        # Re-assert constants in case modules were partially cached.
        auth.AUTH_DISABLED = False
        auth.API_KEY = TEST_API_KEY
        return api


class MutatingRouteAuthTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.api = _load_app()
        cls.client = cls.api.app.test_client()

    def _auth_headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {TEST_API_KEY}",
            "Content-Type": "application/json",
            "X-Operator-Identity": "Andy Graves",
            "X-Device-Install-ID": "test-device-install-001",
            "X-Device-Label": "Andy Test Device",
            "X-App-Environment": "development",
        }

    def test_unauthenticated_writes_return_401(self) -> None:
        for method, path, body in WRITE_CASES:
            with self.subTest(method=method, path=path):
                response = self.client.open(
                    path,
                    method=method,
                    json=body,
                    headers={"Content-Type": "application/json"},
                )
                self.assertEqual(response.status_code, 401, response.get_json())
                payload = response.get_json()
                self.assertIsInstance(payload, dict)
                self.assertEqual(payload.get("code"), "UNAUTHORIZED")

    def test_unauthenticated_category_post_is_401_not_validation(self) -> None:
        """Acceptance probe: empty name used to return 400; must be 401 first."""
        response = self.client.post(
            "/categories",
            json={"name": ""},
            headers={"Content-Type": "application/json"},
        )
        self.assertEqual(response.status_code, 401)
        payload = response.get_json()
        self.assertEqual(payload.get("code"), "UNAUTHORIZED")
        self.assertNotIn("name is required", str(payload))

    def test_authenticated_category_empty_name_returns_400(self) -> None:
        response = self.client.post(
            "/categories",
            json={"name": ""},
            headers=self._auth_headers(),
        )
        self.assertEqual(response.status_code, 400)
        payload = response.get_json()
        self.assertEqual(payload.get("error"), "name is required")

    def test_authenticated_task_upsert_non_object_returns_400(self) -> None:
        response = self.client.open(
            "/tasks",
            method="POST",
            data="[]",
            headers=self._auth_headers(),
        )
        self.assertEqual(response.status_code, 400)
        payload = response.get_json()
        self.assertEqual(payload.get("error"), "JSON object body required")

    def test_authenticated_patch_empty_body_returns_400(self) -> None:
        response = self.client.patch(
            "/tasks/00000000-0000-0000-0000-000000000001",
            json={},
            headers=self._auth_headers(),
        )
        self.assertEqual(response.status_code, 400)
        payload = response.get_json()
        self.assertEqual(payload.get("error"), "No fields to update")

    def test_authenticated_replace_parts_non_array_returns_400(self) -> None:
        with mock.patch.object(self.api, "fetch_task_or_404", return_value={"id": "t"}):
            response = self.client.put(
                "/tasks/00000000-0000-0000-0000-000000000001/parts",
                json={"not": "a list"},
                headers=self._auth_headers(),
            )
        self.assertEqual(response.status_code, 400)
        payload = response.get_json()
        self.assertEqual(payload.get("error"), "JSON array body required")

    def test_authenticated_create_part_non_object_returns_400(self) -> None:
        with mock.patch.object(self.api, "fetch_task_or_404", return_value={"id": "t"}):
            response = self.client.open(
                "/tasks/00000000-0000-0000-0000-000000000001/parts",
                method="POST",
                data="[]",
                headers=self._auth_headers(),
            )
        self.assertEqual(response.status_code, 400)
        payload = response.get_json()
        self.assertEqual(payload.get("error"), "JSON object body required")

    def test_authenticated_delete_task_not_found_shape(self) -> None:
        with mock.patch.object(self.api.pm_db, "execute", return_value=0):
            response = self.client.delete(
                "/tasks/00000000-0000-0000-0000-000000000001",
                headers=self._auth_headers(),
            )
        self.assertEqual(response.status_code, 404)
        payload = response.get_json()
        self.assertEqual(payload.get("error"), "Task not found")

    def test_authenticated_delete_category_not_found_shape(self) -> None:
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=None):
            response = self.client.delete(
                "/categories/00000000-0000-0000-0000-000000000001",
                json={},
                headers=self._auth_headers(),
            )
        self.assertEqual(response.status_code, 404)
        payload = response.get_json()
        self.assertEqual(payload.get("error"), "Category not found")

    def test_complete_requires_device_install_identity(self) -> None:
        headers = {
            "Authorization": f"Bearer {TEST_API_KEY}",
            "Content-Type": "application/json",
            "X-Operator-Identity": "Andy Graves",
        }
        response = self.client.post(
            "/tasks/00000000-0000-0000-0000-000000000001/complete",
            json={},
            headers=headers,
        )
        self.assertEqual(response.status_code, 400)
        payload = response.get_json()
        self.assertEqual(payload.get("field"), "device_install_id")

    def test_complete_returns_authoritative_completion_receipt(self) -> None:
        task_before = {
            "id": "00000000-0000-0000-0000-000000000001",
            "warning_days": 30,
            "asset_id": None,
            "schedule_kind": "calendar",
            "last_done": None,
            "next_due": None,
            "last_done_meter_value": None,
            "next_due_meter_value": None,
            "result_notes": None,
        }
        task_after = {"id": task_before["id"]}

        with (
            mock.patch.object(
                self.api.pm_db,
                "execute_one_json",
                side_effect=[task_before, task_after],
            ),
            mock.patch.object(
                self.api.ms,
                "complete_task_meter",
                return_value=None,
            ),
            mock.patch.object(
                self.api.pm_db,
                "execute_script",
            ) as execute_script,
            mock.patch.object(
                self.api,
                "enrich_tasks",
                return_value=[{"id": task_before["id"]}],
            ),
        ):
            response = self.client.post(
                f"/tasks/{task_before['id']}/complete",
                json={"note": "completed in test"},
                headers=self._auth_headers(),
            )

        self.assertEqual(response.status_code, 200, response.get_json())
        payload = response.get_json()

        self.assertEqual(payload.get("completed_by"), "Andy Graves")
        self.assertEqual(
            payload.get("device_install_id"),
            "test-device-install-001",
        )
        self.assertEqual(payload.get("device_label"), "Andy Test Device")
        self.assertEqual(payload.get("app_environment"), "development")
        self.assertTrue(payload.get("completion_id"))
        self.assertTrue(payload.get("completed_at"))
        execute_script.assert_called_once()

        statements = execute_script.call_args.args[0]
        sql = "\n".join(statement[0] for statement in statements)
        self.assertIn("maintenance_completions", sql)
        self.assertIn("action_journal", sql)
        self.assertIn("task_completed", sql)

    def test_acknowledge_records_actor_and_device(self) -> None:
        task_id = "00000000-0000-0000-0000-000000000001"
        completion_id = "10000000-0000-0000-0000-000000000001"

        completion = {
            "id": completion_id,
            "task_id": task_id,
            "completed_at": "2026-08-17T18:00:00+00:00",
            "undone_at": None,
            "acknowledged_at": None,
        }

        with (
            mock.patch.object(
                self.api.pm_db,
                "execute_one_json",
                return_value=completion,
            ),
            mock.patch.object(
                self.api.pm_db,
                "execute_script",
            ) as execute_script,
        ):
            response = self.client.post(
                f"/tasks/{task_id}/completions/{completion_id}/acknowledge",
                json={},
                headers=self._auth_headers(),
            )

        self.assertEqual(response.status_code, 200, response.get_json())
        payload = response.get_json()
        self.assertEqual(payload.get("acknowledged_by"), "Andy Graves")

        statements = execute_script.call_args.args[0]
        sql = "\n".join(statement[0] for statement in statements)
        self.assertIn("completion_acknowledged", sql)

    def test_undo_rejects_non_latest_completion(self) -> None:
        task_id = "00000000-0000-0000-0000-000000000001"
        completion_id = "10000000-0000-0000-0000-000000000001"

        completion = {
            "id": completion_id,
            "task_id": task_id,
            "completed_at": "2026-08-17T18:00:00+00:00",
            "meter_reading_id": None,
            "previous_last_done": None,
            "previous_next_due": None,
            "previous_last_done_meter_value": None,
            "previous_next_due_meter_value": None,
            "previous_result_notes": None,
            "undone_at": None,
        }

        newer = {"id": "20000000-0000-0000-0000-000000000001"}

        with mock.patch.object(
            self.api.pm_db,
            "execute_one_json",
            side_effect=[completion, newer],
        ):
            response = self.client.post(
                f"/tasks/{task_id}/completions/{completion_id}/undo",
                json={},
                headers=self._auth_headers(),
            )

        self.assertEqual(response.status_code, 409)
        payload = response.get_json()
        self.assertEqual(payload.get("code"), "COMPLETION_NOT_LATEST")


    def test_undo_restores_task_and_reverses_completion_meter_reading(self) -> None:
        task_id = "00000000-0000-0000-0000-000000000001"
        completion_id = "10000000-0000-0000-0000-000000000001"
        meter_reading_id = "30000000-0000-0000-0000-000000000001"
        asset_id = "40000000-0000-0000-0000-000000000001"

        completion = {
            "id": completion_id,
            "task_id": task_id,
            "completed_at": "2026-08-17T18:00:00+00:00",
            "meter_reading_id": meter_reading_id,
            "previous_last_done": "2026-07-17T18:00:00+00:00",
            "previous_next_due": "2026-08-16T18:00:00+00:00",
            "previous_last_done_meter_value": "100.000",
            "previous_next_due_meter_value": "150.000",
            "previous_result_notes": "previous notes",
            "undone_at": None,
        }

        latest = {"id": completion_id}

        current_task = {
            "id": task_id,
            "asset_id": asset_id,
            "last_done": "2026-08-17T18:00:00+00:00",
            "next_due": "2026-09-16T18:00:00+00:00",
            "last_done_meter_value": "160.000",
            "next_due_meter_value": "210.000",
            "result_notes": "new notes",
        }

        completion_journal = {
            "id": "50000000-0000-0000-0000-000000000001"
        }

        reading = {"meter_epoch": 2}

        updated_task = {"id": task_id}

        with (
            mock.patch.object(
                self.api.pm_db,
                "execute_one_json",
                side_effect=[
                    completion,
                    latest,
                    current_task,
                    completion_journal,
                    reading,
                    updated_task,
                ],
            ),
            mock.patch.object(
                self.api.pm_db,
                "execute_script",
            ) as execute_script,
            mock.patch.object(
                self.api.ms,
                "recalc_usage_for_epoch",
            ) as recalc_usage,
            mock.patch.object(
                self.api.ms,
                "update_current_meter_from_latest",
            ) as update_current,
            mock.patch.object(
                self.api,
                "enrich_tasks",
                return_value=[{"id": task_id}],
            ),
        ):
            response = self.client.post(
                f"/tasks/{task_id}/completions/{completion_id}/undo",
                json={},
                headers=self._auth_headers(),
            )

        self.assertEqual(response.status_code, 200, response.get_json())
        payload = response.get_json()

        self.assertEqual(payload.get("completion_id"), completion_id)
        self.assertEqual(payload.get("undone_by"), "Andy Graves")
        self.assertTrue(payload.get("undone_at"))

        execute_script.assert_called_once()
        statements = execute_script.call_args.args[0]
        sql = "\n".join(statement[0] for statement in statements)

        self.assertIn("UPDATE propertymanager.maintenance_tasks", sql)
        self.assertIn("UPDATE propertymanager.maintenance_completions", sql)
        self.assertIn("UPDATE propertymanager.asset_meter_reading", sql)
        self.assertIn("status = 'rejected'", sql)
        self.assertIn("completion_undone", sql)

        task_update = next(
            statement for statement in statements
            if "UPDATE propertymanager.maintenance_tasks" in statement[0]
        )
        params = task_update[1]

        self.assertEqual(params[0], completion["previous_last_done"])
        self.assertEqual(params[1], completion["previous_next_due"])
        self.assertEqual(params[2], completion["previous_last_done_meter_value"])
        self.assertEqual(params[3], completion["previous_next_due_meter_value"])
        self.assertEqual(params[4], completion["previous_result_notes"])
        self.assertEqual(params[5], task_id)

        recalc_usage.assert_called_once_with(asset_id, 2)
        update_current.assert_called_once_with(asset_id, 2)

    def test_undo_already_undone_returns_conflict(self) -> None:
        task_id = "00000000-0000-0000-0000-000000000001"
        completion_id = "10000000-0000-0000-0000-000000000001"

        completion = {
            "id": completion_id,
            "task_id": task_id,
            "completed_at": "2026-08-17T18:00:00+00:00",
            "meter_reading_id": None,
            "previous_last_done": None,
            "previous_next_due": None,
            "previous_last_done_meter_value": None,
            "previous_next_due_meter_value": None,
            "previous_result_notes": None,
            "undone_at": "2026-08-17T18:05:00+00:00",
        }

        with mock.patch.object(
            self.api.pm_db,
            "execute_one_json",
            return_value=completion,
        ):
            response = self.client.post(
                f"/tasks/{task_id}/completions/{completion_id}/undo",
                json={},
                headers=self._auth_headers(),
            )

        self.assertEqual(response.status_code, 409)
        payload = response.get_json()
        self.assertEqual(payload.get("code"), "COMPLETION_ALREADY_UNDONE")


    def test_reads_remain_unauthenticated(self) -> None:
        with mock.patch.object(self.api.pm_db, "execute_json", return_value=[]):
            response = self.client.get("/categories")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json(), [])


class DockerExecInterruptMessageTests(unittest.TestCase):
    def test_signal_kill_maps_to_interrupt_message(self) -> None:
        if str(API_DIR) not in sys.path:
            sys.path.insert(0, str(API_DIR))
        import db as pm_db

        importlib.reload(pm_db)
        fake = mock.Mock(returncode=-15, stderr="", stdout="")
        with self.assertRaises(RuntimeError) as raised:
            pm_db._raise_psql_failure(fake)
        self.assertIn("interrupted", str(raised.exception).lower())
        self.assertIn("reload", str(raised.exception).lower())


if __name__ == "__main__":
    unittest.main()

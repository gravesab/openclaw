#!/usr/bin/env python3
"""Focused DEV regression contracts for isolated mobile work-request intake."""

from __future__ import annotations

import hashlib
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

API_DIR = Path(__file__).resolve().parents[1] / "api"
REPO_ROOT = Path(__file__).resolve().parents[3]
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

    def test_health_redacts_attachment_root_and_reports_only_verified_current_migration(self):
        with mock.patch.object(
            self.api, "_probe_postgres_and_schema", return_value=(True, True, True)
        ):
            response = self.client.get("/health")

        self.assertEqual(response.status_code, 200)
        body = response.get_json()
        self.assertEqual(body["schema_version"], "014")
        self.assertEqual(body["schema_contract_status"], "migration_014_applied")
        self.assertNotIn("attachments_root", body)
        self.assertNotIn("storage_path", body)

    def test_health_never_claims_current_migration_without_marker_and_required_objects(self):
        complete_objects = {
            "assets_table": "propertymanager.assets",
            "meter_table": "propertymanager.asset_meter",
            "tasks_table": "propertymanager.maintenance_tasks",
            "proposals_table": "propertymanager.maintenance_proposals",
            "required_tables": True,
            "intake_columns": True,
            "photo_columns": True,
            "required_indexes": True,
        }
        with mock.patch.object(
            self.api.pm_db,
            "execute_one_json",
            side_effect=[complete_objects, {"migration_applied": False}],
        ):
            self.assertEqual(self.api._probe_postgres_and_schema(), (True, True, False))

        with mock.patch.object(
            self.api, "_probe_postgres_and_schema", return_value=(True, True, False)
        ):
            response = self.client.get("/health")
        self.assertEqual(response.status_code, 503)
        body = response.get_json()
        self.assertIsNone(body["schema_version"])
        self.assertEqual(body["schema_contract_status"], "migration_014_not_verified")

    def test_health_marker_is_read_only_and_parameterized(self):
        complete_objects = {
            "assets_table": "propertymanager.assets",
            "meter_table": "propertymanager.asset_meter",
            "tasks_table": "propertymanager.maintenance_tasks",
            "proposals_table": "propertymanager.maintenance_proposals",
            "required_tables": True,
            "intake_columns": True,
            "photo_columns": True,
            "required_indexes": True,
        }
        with mock.patch.object(
            self.api.pm_db,
            "execute_one_json",
            side_effect=[complete_objects, {"migration_applied": True}],
        ) as query:
            self.assertEqual(self.api._probe_postgres_and_schema(), (True, True, True))

        marker_sql, marker_params = query.call_args_list[1].args
        self.assertIn("SELECT EXISTS", marker_sql)
        self.assertNotIn("INSERT", marker_sql)
        self.assertEqual(marker_params, ("014",))

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
        params = mutation.call_args.args[1]
        self.assertEqual(params[4], f"Work request {params[2]}")

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
        attachment_id = "00000000-0000-0000-0000-000000000010"
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=None) as query, \
             mock.patch.object(self.api.pm_db, "execute") as execute:
            response = self.client.post(
                "/v1/work-requests",
                json=self.payload(attachment_ids=[attachment_id, attachment_id]),
                headers=self.headers(),
            )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(query.call_count, 1)
        execute.assert_not_called()

    def test_attachment_count_and_malformed_ids_are_rejected_before_database_use(self):
        too_many = [f"00000000-0000-0000-0000-{index:012d}" for index in range(1, 7)]
        for payload, field in (
            (self.payload(attachment_ids=too_many), "attachment_ids"),
            (self.payload(attachment_ids=["not-a-uuid"]), "attachment_ids"),
            (self.payload(asset_id="not-a-uuid"), "asset_id"),
        ):
            with self.subTest(field=field), \
                 mock.patch.object(self.api.pm_db, "execute_one_json", return_value=None) as query, \
                 mock.patch.object(self.api.pm_db, "execute_top_level_one_json") as mutation:
                response = self.client.post(
                    "/v1/work-requests", json=payload, headers=self.headers(idem=f"invalid-{field}")
                )
            self.assertEqual(response.status_code, 400)
            self.assertEqual(response.get_json().get("field"), field)
            self.assertEqual(query.call_count, 1)
            mutation.assert_not_called()

    def test_attachment_allocation_limit_is_claimed_atomically(self):
        with mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=[None, None]), \
             mock.patch.object(self.api.pm_db, "execute_json", return_value=[]), \
             mock.patch.object(self.api.pm_db, "execute_top_level_one_json", return_value=None) as mutation:
            response = self.client.post(
                "/v1/work-requests/attachments",
                json={"content_type": "image/jpeg", "byte_size": 1024},
                headers=self.headers(idem="photo-limit"),
            )
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.get_json()["code"], "ATTACHMENT_LIMIT_REACHED")
        sql = mutation.call_args.args[0]
        self.assertIn("pg_advisory_xact_lock", sql)
        self.assertIn("state IN ('issued', 'uploaded')", sql)
        self.assertEqual(mutation.call_args.args[1][-1], 5)

    def test_attachment_allocation_reaps_only_expired_unattached_photo(self):
        attachment_id = "00000000-0000-0000-0000-000000000021"
        with tempfile.TemporaryDirectory() as tmp:
            photo = Path(tmp) / f"{attachment_id}.jpg"
            photo.write_bytes(b"sanitized-photo")
            with mock.patch.object(
                self.api.pm_db, "execute_one_json", side_effect=[None, {"id": attachment_id}]
            ), mock.patch.object(
                self.api.pm_db, "execute_json", return_value=[{"id": attachment_id}]
            ), mock.patch.object(
                self.api.pm_db, "execute_top_level_one_json", return_value={"id": "new"}
            ), mock.patch.object(
                self.api.pm_db, "execute", return_value=1
            ) as execute, mock.patch.object(
                sys.modules["work_requests"], "_attachment_root", return_value=Path(tmp)
            ):
                response = self.client.post(
                    "/v1/work-requests/attachments",
                    json={"content_type": "image/jpeg", "byte_size": 1024},
                    headers=self.headers(idem="photo-after-expiry"),
                )
            self.assertFalse(photo.exists())
        self.assertEqual(response.status_code, 201)
        self.assertIn("state = 'expired'", execute.call_args.args[0])

    def test_non_finite_draft_material_quantity_is_rejected_before_write(self):
        for quantity in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(quantity=quantity), \
                 mock.patch.object(self.api.pm_db, "execute_one_json", return_value=None), \
                 mock.patch.object(self.api.pm_db, "execute_top_level_one_json") as mutation:
                response = self.client.post(
                    "/v1/work-requests",
                    json=self.payload(materials=[{"name": "PVC fitting", "quantity": quantity}]),
                    headers=self.headers(idem=f"quantity-{quantity}"),
                )
            self.assertEqual(response.status_code, 400)
            self.assertEqual(response.get_json().get("field"), "materials")
            mutation.assert_not_called()

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

    def test_attachment_upload_without_content_type_fails_validation(self):
        attachment_id = "00000000-0000-0000-0000-000000000003"
        operation = {
            "id": attachment_id, "created_by": SERVER_SUBMITTER, "content_type": "image/jpeg",
            "max_bytes": 1024, "state": "issued", "expires_at": "2999-01-01T00:00:00+00:00",
            "allocation_idempotency_key": "photo-missing-type",
        }
        with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=operation), \
             mock.patch.object(self.api.pm_db, "execute") as execute:
            response = self.client.put(
                f"/v1/work-requests/attachments/{attachment_id}/content",
                data=b"not-accepted-without-a-content-type",
                headers=self.headers(idem="photo-missing-type"),
            )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.get_json().get("field"), "Content-Type")
        execute.assert_not_called()

    def test_expired_attachment_allocation_reissues_same_retry_operation(self):
        attachment_id = "00000000-0000-0000-0000-000000000004"
        expired = {
            "id": attachment_id, "content_type": "image/jpeg", "max_bytes": 1024,
            "state": "uploaded", "expired": True,
        }
        with tempfile.TemporaryDirectory() as tmp:
            stale_photo = Path(tmp) / f"{attachment_id}.jpg"
            stale_photo.write_bytes(b"stale-photo")
            with mock.patch.object(self.api.pm_db, "execute_one_json", return_value=expired), \
                 mock.patch.object(self.api.pm_db, "execute", return_value=1) as execute, \
                 mock.patch.object(sys.modules["work_requests"], "_attachment_root", return_value=Path(tmp)):
                response = self.client.post(
                    "/v1/work-requests/attachments",
                    json={"content_type": "image/jpeg", "byte_size": 1024},
                    headers=self.headers(idem="photo-expired"),
                )
            self.assertFalse(stale_photo.exists())
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["attachment_id"], attachment_id)
        self.assertTrue(response.get_json()["idempotent_replay"])
        sql = execute.call_args.args[0]
        self.assertIn("SET state = 'issued'", sql)
        self.assertIn("expires_at <= now()", sql)
        self.assertIn("storage_path = NULL", sql)

    def test_concurrent_attachment_uploads_finalize_one_consistent_file(self):
        attachment_id = "00000000-0000-0000-0000-000000000020"
        operation = {
            "id": attachment_id, "created_by": SERVER_SUBMITTER, "content_type": "image/jpeg",
            "max_bytes": 1024, "state": "issued", "expires_at": "2999-01-01T00:00:00+00:00",
            "allocation_idempotency_key": "photo-race", "storage_path": None,
            "byte_size": None, "sha256": None,
        }
        operation_lock = threading.Lock()
        initial_reads = threading.Barrier(2)
        thread_state = threading.local()

        def read_operation(*_args, **_kwargs):
            with operation_lock:
                snapshot = dict(operation)
            thread_state.reads = getattr(thread_state, "reads", 0) + 1
            if thread_state.reads == 1:
                initial_reads.wait(timeout=2)
            return snapshot

        def finalize(_sql, params):
            with operation_lock:
                if operation["state"] != "issued":
                    return 0
                operation.update({
                    "state": "uploaded", "storage_path": params[0],
                    "byte_size": params[1], "sha256": params[2],
                })
                return 1

        responses = []
        responses_lock = threading.Lock()
        bodies = [b"\xff\xd8\xff\xdafirst-image", b"\xff\xd8\xff\xdasecond-image"]
        with tempfile.TemporaryDirectory() as tmp, \
             mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=read_operation), \
             mock.patch.object(self.api.pm_db, "execute", side_effect=finalize), \
             mock.patch.object(sys.modules["work_requests"], "_attachment_root", return_value=Path(tmp)):
            def upload(body):
                with self.api.app.test_client() as client:
                    response = client.put(
                        f"/v1/work-requests/attachments/{attachment_id}/content",
                        data=body,
                        content_type="image/jpeg",
                        headers=self.headers(idem="photo-race"),
                    )
                with responses_lock:
                    responses.append(response)

            workers = [threading.Thread(target=upload, args=(body,)) for body in bodies]
            for worker in workers:
                worker.start()
            for worker in workers:
                worker.join(timeout=3)
            self.assertTrue(all(not worker.is_alive() for worker in workers))
            saved = (Path(tmp) / f"{attachment_id}.jpg").read_bytes()

        self.assertEqual([response.status_code for response in responses], [200, 200])
        self.assertEqual(sum(bool(response.get_json().get("idempotent_replay")) for response in responses), 1)
        self.assertEqual(hashlib.sha256(saved).hexdigest(), operation["sha256"])
        self.assertEqual(len(saved), operation["byte_size"])

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
        self.assertIn("kind <> 'Work Request' AND intake_state IS NULL", query.call_args.args[0])

        if str(REPO_ROOT) not in sys.path:
            sys.path.insert(0, str(REPO_ROOT))
        from tools.property_manager.mcp_boundary import PropertyManagerMCPDatabaseConfiguration
        from tools.property_manager.mcp_repository import PostgresPropertyManagerReadRepository

        repository = PostgresPropertyManagerReadRepository(
            PropertyManagerMCPDatabaseConfiguration(database_url="postgresql://unused")
        )
        with mock.patch.object(repository, "_rows", return_value=[]) as query:
            repository.list_tasks(days=7)
        self.assertIn(
            "t.kind <> 'Work Request' AND t.intake_state IS NULL",
            query.call_args.args[0],
        )

    def test_generic_task_mutations_reject_work_requests_and_keep_scheduled_control(self):
        intake = stored_request(kind="Work Request")
        scheduled = stored_request(
            id="00000000-0000-0000-0000-000000000030",
            kind="Scheduled",
            intake_state=None,
            item="Inspect north fence",
        )

        with mock.patch.object(self.api.pm_db, "execute") as execute:
            created = self.client.post(
                "/tasks", json={"kind": "Work Request", "area": "North barn"},
                headers=self.headers(),
            )
        self.assertEqual(created.status_code, 409)
        execute.assert_not_called()

        for method, path, body in (
            ("patch", "/tasks/r", {"notes": "bypass"}),
            ("put", "/tasks/r/parts", []),
            ("post", "/tasks/r/parts", {"name": "bypass"}),
        ):
            with self.subTest(method=method, path=path), \
                 mock.patch.object(self.api.pm_db, "execute_one_json", return_value=intake), \
                 mock.patch.object(self.api.pm_db, "execute") as execute:
                response = getattr(self.client, method)(path, json=body, headers=self.headers())
                self.assertEqual(response.status_code, 404)
                execute.assert_not_called()

        with mock.patch.object(self.api.pm_db, "execute", return_value=0) as execute:
            deleted = self.client.delete("/tasks/r", headers=self.headers())
        self.assertEqual(deleted.status_code, 404)
        self.assertIn("kind <> 'Work Request' AND intake_state IS NULL", execute.call_args.args[0])

        with mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=[scheduled, scheduled]), \
             mock.patch.object(self.api.pm_db, "execute_json", return_value=[]), \
             mock.patch.object(self.api.pm_db, "execute", return_value=1) as execute:
            updated = self.client.patch(
                f"/tasks/{scheduled['id']}", json={"notes": "scheduled control"},
                headers=self.headers(),
            )
        self.assertEqual(updated.status_code, 200, updated.get_json())
        self.assertIn("kind <> 'Work Request' AND intake_state IS NULL", execute.call_args.args[0])

    def test_generic_upsert_cannot_claim_an_existing_work_request_id(self):
        task_id = "00000000-0000-0000-0000-000000000040"
        with mock.patch.object(
            self.api.pm_db,
            "execute_one_json",
            side_effect=[{"last_done": "2026-01-01T00:00:00+00:00", "next_due": "2026-02-01T00:00:00+00:00"}, None],
        ), mock.patch.object(self.api.pm_db, "execute", return_value=0) as execute:
            response = self.client.post(
                "/tasks",
                json={"id": task_id, "kind": "Scheduled", "area": "North barn", "item": "Inspect fence"},
                headers=self.headers(),
            )
        self.assertEqual(response.status_code, 409)
        self.assertEqual(execute.call_count, 1)
        self.assertIn(
            "WHERE current_task.kind <> 'Work Request' AND current_task.intake_state IS NULL",
            execute.call_args.args[0],
        )

    def test_forged_review_header_never_becomes_triage_or_conversion_actor(self):
        asset_id = "00000000-0000-0000-0000-000000000030"
        triaged = stored_request(intake_state="triaged", asset_id=asset_id, category_name="Property", priority="High")
        with mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=[stored_request(), triaged]), \
             mock.patch.object(self.api.pm_db, "execute_top_level_one_json", return_value={"id": "r"}) as mutation:
            response = self.client.post("/v1/work-requests/r/triage", json={"area": "North barn", "asset_id": asset_id,
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
        self.assertIn("|| ' [' || id::text || ']'", sql)
        self.assertIn(SERVER_REVIEWER, repr(params))
        self.assertNotIn("forged-reviewer", repr(params))

    def test_concurrent_triage_claim_creates_one_state_event(self):
        triaged = stored_request(intake_state="triaged")
        asset_id = "00000000-0000-0000-0000-000000000030"
        with mock.patch.object(self.api.pm_db, "execute_one_json", side_effect=[stored_request(), triaged, stored_request()]), \
             mock.patch.object(self.api.pm_db, "execute_top_level_one_json", side_effect=[{"id": "r"}, None]) as mutation:
            first = self.client.post("/v1/work-requests/r/triage", json={"area": "North barn", "asset_id": asset_id,
                                     "category_name": "Property", "priority": "High", "reason": "Verified"},
                                     headers=self.headers(review=True))
            second = self.client.post("/v1/work-requests/r/triage", json={"area": "North barn", "asset_id": asset_id,
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

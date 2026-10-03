#!/usr/bin/env python3
"""Focused contracts for the IntelMini-owned PropertyManager manual library."""

from __future__ import annotations

import io
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

    def test_existing_asset_pdf_link_rejects_non_asset_library_path(self):
        with self.assertRaises(ValueError):
            dashboard.pdf_upload_find_available_asset_pdf("Projects/pump-aaaaaaaaaaaa.pdf")

    def test_existing_asset_pdf_link_registers_governed_locator(self):
        existing = {
            "relative_path": "Assets/pump-aaaaaaaaaaaa.pdf",
            "original_filename": "Pump.pdf",
            "title": "Pump Manual",
            "size_bytes": 123,
            "sha256": "a" * 64,
        }
        with self._page_mocks([{"id": "asset-1", "name": "Pump"}]), mock.patch.object(
            dashboard, "pdf_upload_find_available_asset_pdf", return_value=existing
        ), mock.patch.object(dashboard, "propertymanager_manual_library_register") as register:
            response = dashboard.app.test_client().post(
                "/pm/manual-library",
                data={"asset_id": "ASSET-1", "relative_path": existing["relative_path"]},
            )
        page = response.get_data(as_text=True)
        self.assertEqual(response.status_code, 200)
        self.assertIn("Manual connected.", page)
        self.assertEqual(register.call_args.args[0], "asset-1")
        self.assertEqual(
            register.call_args.args[1]["source_locator"],
            "dashboard-library://Assets/pump-aaaaaaaaaaaa.pdf",
        )

    def _page_mocks(self, assets, stored=()):
        stack = mock.patch.multiple(
            dashboard,
            propertymanager_manual_library_list_assets=mock.Mock(return_value=assets),
            propertymanager_manual_library_list_manuals=mock.Mock(return_value=[]),
            pdf_library_list_asset_pdfs=mock.Mock(return_value=list(stored)),
        )
        return stack

    def test_app_library_lists_assets_pdfs_for_the_propertymanager_credential(self):
        stored = [{"relative_path": "Assets/DR_Chipper_Manual.pdf", "title": "DR Chipper Manual"}]
        with mock.patch.object(dashboard, "PROPERTYMANAGER_API_KEY", "test-client-key"), mock.patch.object(
            dashboard, "pdf_library_list_asset_pdfs", return_value=stored
        ):
            denied = dashboard.app.test_client().get(
                "/pm/manual-library/api/library", headers={"Authorization": "Bearer wrong-key"}
            )
            allowed = dashboard.app.test_client().get(
                "/pm/manual-library/api/library", headers={"Authorization": "Bearer test-client-key"}
            )
        self.assertEqual(denied.status_code, 401)
        self.assertEqual(allowed.status_code, 200)
        self.assertEqual(allowed.get_json(), {"documents": stored})

    def test_app_link_connects_the_chosen_library_pdf_without_copying(self):
        with mock.patch.object(dashboard, "PROPERTYMANAGER_API_KEY", "test-client-key"), mock.patch.object(
            dashboard, "propertymanager_manual_library_link_stored_asset_pdf", return_value={"version_id": "v-1"}
        ) as link:
            response = dashboard.app.test_client().post(
                "/pm/manual-library/api/assets/ASSET-1/manuals/link",
                headers={"Authorization": "Bearer test-client-key"},
                json={"relative_path": "Assets/DR_Chipper_Manual.pdf"},
            )
            missing = dashboard.app.test_client().post(
                "/pm/manual-library/api/assets/ASSET-1/manuals/link",
                headers={"Authorization": "Bearer test-client-key"},
                json={},
            )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.get_json()["version_id"], "v-1")
        self.assertEqual(link.call_args.args, ("ASSET-1", "Assets/DR_Chipper_Manual.pdf"))
        self.assertEqual(missing.status_code, 400)
        self.assertEqual(link.call_count, 1)

    def test_app_link_reports_a_non_assets_path(self):
        with mock.patch.object(dashboard, "PROPERTYMANAGER_API_KEY", "test-client-key"), mock.patch.object(
            dashboard, "propertymanager_manual_library_list_assets", return_value=[{"id": "asset-1"}]
        ):
            response = dashboard.app.test_client().post(
                "/pm/manual-library/api/assets/asset-1/manuals/link",
                headers={"Authorization": "Bearer test-client-key"},
                json={"relative_path": "Taxes/return.pdf"},
            )
        self.assertEqual(response.status_code, 400)
        self.assertTrue(response.get_json()["error"])

    def test_mac_upload_requires_the_propertymanager_credential(self):
        with mock.patch.object(dashboard, "PROPERTYMANAGER_API_KEY", "test-client-key"), mock.patch.object(
            dashboard, "propertymanager_manual_library_upload_and_link"
        ) as upload_and_link:
            response = dashboard.app.test_client().post(
                "/pm/manual-library/api/assets/asset-1/manuals",
                headers={"Authorization": "Bearer wrong-key"},
                data={"pdf_file": (io.BytesIO(b"%PDF-1.7\n"), "manual.pdf")},
                content_type="multipart/form-data",
            )
        self.assertEqual(response.status_code, 401)
        upload_and_link.assert_not_called()

    def test_mac_upload_connects_the_pdf_to_the_uppercase_asset_id(self):
        with mock.patch.object(dashboard, "PROPERTYMANAGER_API_KEY", "test-client-key"), mock.patch.object(
            dashboard, "propertymanager_manual_library_list_assets", return_value=[{"id": "asset-1"}]
        ), mock.patch.object(
            dashboard, "propertymanager_manual_library_upload_and_link", return_value="PDF uploaded and connected."
        ) as upload_and_link:
            response = dashboard.app.test_client().post(
                "/pm/manual-library/api/assets/ASSET-1/manuals",
                headers={"Authorization": "Bearer test-client-key"},
                data={"pdf_file": (io.BytesIO(b"%PDF-1.7\n"), "DR_Chipper_Manual.pdf")},
                content_type="multipart/form-data",
            )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.get_json()["message"], "PDF uploaded and connected.")
        self.assertEqual(upload_and_link.call_args.args[0], "asset-1")

    def test_connect_without_a_pdf_says_what_to_choose(self):
        with self._page_mocks([{"id": "asset-1", "name": "DR Chipper"}]), mock.patch.object(
            dashboard, "propertymanager_manual_library_register"
        ) as register:
            response = dashboard.app.test_client().post("/pm/manual-library", data={"asset_id": "asset-1"})
        page = response.get_data(as_text=True)
        self.assertIn("Not connected. Choose a PDF from the library list, or upload one from this computer.", page)
        register.assert_not_called()

    def test_page_suggests_the_library_pdf_that_matches_the_asset_once(self):
        stored = [
            {"relative_path": "Assets/DR_Chipper_Manual.pdf", "title": "Dr Chipper Manual"},
            {"relative_path": "Assets/Home/EcoWater Owners Manual.pdf", "title": "Ecowater Owners Manual"},
            {"relative_path": "Assets/DR-Power/DR Field Mower Manual.pdf", "title": "DR Field Mower Manual"},
        ]
        asset = {"id": "asset-1", "name": "DR Chipper", "manufacturer": "DR Power Equipment"}
        with self._page_mocks([asset], stored):
            response = dashboard.app.test_client().get("/pm/manual-library?asset_id=ASSET-1")
        page = response.get_data(as_text=True)
        self.assertIn("Upload, update, or connect a manual", page)
        suggested = page.split('<optgroup label="Suggested for DR Chipper">', 1)[1].split("</optgroup>", 1)[0]
        self.assertIn("Assets/DR_Chipper_Manual.pdf", suggested)
        self.assertNotIn("EcoWater", suggested)
        self.assertNotIn("Field Mower", suggested)
        self.assertEqual(page.count('value="Assets/DR_Chipper_Manual.pdf"'), 1)
        self.assertEqual(page.count("Connect Manual</button>"), 1)

    def test_link_accepts_the_mac_app_uppercase_asset_id(self):
        existing = {
            "relative_path": "Assets/DR_Chipper_Manual.pdf",
            "original_filename": "DR_Chipper_Manual.pdf",
            "title": "DR Chipper Manual",
            "size_bytes": 123,
            "sha256": "b" * 64,
        }
        asset_id = "0815049e-4456-4d8e-b19e-e7775ff39103"
        with mock.patch.object(
            dashboard, "propertymanager_manual_library_list_assets", return_value=[{"id": asset_id}]
        ), mock.patch.object(
            dashboard, "pdf_upload_find_available_asset_pdf", return_value=existing
        ), mock.patch.object(dashboard, "propertymanager_manual_library_register") as register:
            dashboard.propertymanager_manual_library_link_stored_asset_pdf(
                asset_id.upper(), existing["relative_path"]
            )
        self.assertEqual(register.call_args.args[0], asset_id)

    def test_link_records_an_assets_pdf_that_has_no_library_record_yet(self):
        recorded = {
            "relative_path": "Assets/DR_Chipper_Manual.pdf",
            "original_filename": "DR_Chipper_Manual.pdf",
            "title": "DR_Chipper_Manual",
            "size_bytes": 1094569,
            "sha256": "4d1743655e1c41e1522619dd0615c1877339690bdd65759262010d7e1f8f012d",
        }
        with mock.patch.object(
            dashboard, "propertymanager_manual_library_list_assets", return_value=[{"id": "asset-1"}]
        ), mock.patch.object(
            dashboard,
            "pdf_upload_find_available_asset_pdf",
            side_effect=[FileNotFoundError("no record"), recorded],
        ), mock.patch.object(
            dashboard, "pdf_library_register_existing_asset_pdf", return_value=recorded["relative_path"]
        ) as register_existing, mock.patch.object(
            dashboard, "propertymanager_manual_library_register"
        ) as register:
            dashboard.propertymanager_manual_library_link_stored_asset_pdf("asset-1", recorded["relative_path"])
        register_existing.assert_called_once_with(recorded["relative_path"])
        self.assertEqual(register.call_args.args[1]["source_sha256"], recorded["sha256"])

    def test_recording_an_existing_pdf_never_accepts_a_non_assets_path(self):
        with mock.patch.object(dashboard, "pdf_library_fetch_to_temp") as fetch:
            with self.assertRaises(ValueError):
                dashboard.pdf_library_register_existing_asset_pdf("Unsorted/Strong-Spas-Manual2020sm.pdf")
        fetch.assert_not_called()

    def test_link_rejects_an_asset_that_is_not_active(self):
        with mock.patch.object(
            dashboard, "propertymanager_manual_library_list_assets", return_value=[{"id": "asset-1"}]
        ), mock.patch.object(dashboard, "propertymanager_manual_library_register") as register:
            with self.assertRaises(ValueError):
                dashboard.propertymanager_manual_library_link_stored_asset_pdf(
                    "inactive-asset", "Assets/pump-aaaaaaaaaaaa.pdf"
                )
        register.assert_not_called()

    def test_library_upload_asks_which_asset_the_pdf_is_for(self):
        with mock.patch.object(
            dashboard,
            "propertymanager_manual_library_list_assets",
            return_value=[{"id": "asset-1", "name": "DR Chipper"}],
        ):
            response = dashboard.app.test_client().get("/documentation/upload")
        page = response.get_data(as_text=True)
        self.assertEqual(response.status_code, 200)
        self.assertIn("What asset is this for?", page)
        self.assertIn("DR Chipper", page)
        self.assertIn("Not an asset manual", page)

    def test_already_stored_pdf_links_to_the_chosen_asset_without_another_copy(self):
        duplicate = {"relative_path": "Assets/pump-aaaaaaaaaaaa.pdf", "title": "Pump"}
        with mock.patch.object(dashboard, "propertymanager_manual_library_link_stored_asset_pdf") as link:
            message = dashboard.pdf_upload_link_or_reject_duplicate(
                duplicate,
                "asset-1",
                title="Pump Manual",
                document_type="operator_manual",
                manufacturer="Drummond",
                model_number="63319",
            )
        self.assertIn("already stored", message)
        self.assertEqual(link.call_args.args[0], "asset-1")
        self.assertEqual(link.call_args.args[1], duplicate["relative_path"])

    def test_already_stored_pdf_is_not_linked_when_no_asset_is_chosen(self):
        with mock.patch.object(dashboard, "propertymanager_manual_library_link_stored_asset_pdf") as link:
            with self.assertRaises(ValueError):
                dashboard.pdf_upload_link_or_reject_duplicate(
                    {"relative_path": "Assets/pump-aaaaaaaaaaaa.pdf"},
                    "",
                    title="",
                    document_type="operator_manual",
                    manufacturer="",
                    model_number="",
                )
        link.assert_not_called()


if __name__ == "__main__":
    unittest.main()

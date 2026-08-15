#!/usr/bin/env python3
"""Patch Mac PropertyManagerApp to send API key / operator PIN on mutating requests."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else Path.home() / "Development/PropertyManagerApp")
APP = ROOT / "Sources/PropertyManagerApp/PropertyManagerApp.swift"
API = ROOT / "Sources/PropertyManagerApp/PropertyAPIClient.swift"
ASSET_API = ROOT / "Sources/PropertyManagerApp/AssetAPIClient.swift"
REPO_ASSET = Path(__file__).resolve().parent / "AssetAPIClient.swift"


def must_replace(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        if new.strip() and new.split("\n", 1)[0].strip() in text:
            print(f"skip (already patched): {label}")
            return
        raise SystemExit(f"patch anchor not found: {label}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"patched: {label}")


def patch_property_api_client() -> None:
    text = API.read_text(encoding="utf-8")

    old_fields = """struct PropertyAPIClient {
    var baseURLString: String
"""
    new_fields = """struct PropertyAPIClient {
    var baseURLString: String
    /// PROPERTYMANAGER_API_KEY from Mini ~/.config/openclaw/db.env
    var apiKey: String = ""
    /// PROPERTYMANAGER_OPERATOR_PIN from Mini ~/.config/openclaw/db.env (optional if API key set)
    var operatorPIN: String = ""
"""
    if "var apiKey: String" not in text:
        if old_fields not in text:
            raise SystemExit("anchor missing: PropertyAPIClient fields")
        text = text.replace(old_fields, new_fields, 1)
        print("patched: PropertyAPIClient credential fields")
    else:
        print("skip: PropertyAPIClient credential fields")

    apply_auth = """
    /// Mutating-request auth: Bearer/X-API-Key and optional X-Operator-PIN.
    func applyAuth(_ request: inout URLRequest) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \\(key)", forHTTPHeaderField: "Authorization")
            request.setValue(key, forHTTPHeaderField: "X-API-Key")
        }
        let pin = operatorPIN.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pin.isEmpty {
            request.setValue(pin, forHTTPHeaderField: "X-Operator-PIN")
        }
        request.setValue("mac-operator", forHTTPHeaderField: "X-Operator-Identity")
    }

"""
    if "func applyAuth(_ request: inout URLRequest)" not in text:
        marker = "    func validate(_ response: URLResponse, data: Data? = nil) throws {"
        if marker not in text:
            raise SystemExit("anchor missing: validate")
        text = text.replace(marker, apply_auth + marker, 1)
        print("patched: PropertyAPIClient.applyAuth")
    else:
        print("skip: PropertyAPIClient.applyAuth")

    wires = [
        (
            "createCategory",
            'request.setValue("application/json", forHTTPHeaderField: "Content-Type")\n'
            "        request.httpBody = try JSONSerialization.data(withJSONObject: [\n"
            '            "id": category.id.uuidString,',
        ),
        (
            "upsertTask",
            'request.setValue("application/json", forHTTPHeaderField: "Content-Type")\n'
            "        request.httpBody = try JSONSerialization.data(withJSONObject: APITaskDTO.payload(from: task))",
        ),
        (
            "completeTask",
            'request.setValue("application/json", forHTTPHeaderField: "Content-Type")\n'
            '        var completeBody: [String: Any] = ["note": note ?? ""]',
        ),
    ]
    for label, needle in wires:
        idx = text.find(f"func {label}")
        if idx < 0:
            raise SystemExit(f"missing method: {label}")
        if "applyAuth(&request)" in text[idx : idx + 900]:
            print(f"skip applyAuth wire: {label}")
            continue
        if needle not in text:
            raise SystemExit(f"wire anchor missing: {label}")
        replacement = needle.replace(
            'request.setValue("application/json", forHTTPHeaderField: "Content-Type")\n',
            'request.setValue("application/json", forHTTPHeaderField: "Content-Type")\n'
            "        applyAuth(&request)\n",
            1,
        )
        text = text.replace(needle, replacement, 1)
        print(f"patched: applyAuth in {label}")

    for label, old, new in (
        (
            "deleteTask",
            """    func deleteTask(id: UUID) async throws -> TaskDeleteResult {
        let url = try makeURL("/tasks/\\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        do {""",
            """    func deleteTask(id: UUID) async throws -> TaskDeleteResult {
        let url = try makeURL("/tasks/\\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(&request)

        do {""",
        ),
        (
            "deleteCategory",
            """    func deleteCategory(id: UUID, reassignTo: String? = nil) async throws -> CategoryDeleteResult {
        let url = try makeURL("/categories/\\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if let reassignTo, !reassignTo.isEmpty {""",
            """    func deleteCategory(id: UUID, reassignTo: String? = nil) async throws -> CategoryDeleteResult {
        let url = try makeURL("/categories/\\(id.uuidString)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(&request)
        if let reassignTo, !reassignTo.isEmpty {""",
        ),
    ):
        idx = text.find(f"func {label}")
        if idx < 0:
            raise SystemExit(f"missing method: {label}")
        if "applyAuth(&request)" in text[idx : idx + 400]:
            print(f"skip applyAuth wire: {label}")
            continue
        if old not in text:
            raise SystemExit(f"wire anchor missing: {label}")
        text = text.replace(old, new, 1)
        print(f"patched: applyAuth in {label}")

    API.write_text(text, encoding="utf-8")


def patch_store_and_ui() -> None:
    must_replace(
        APP,
        """    private let apiBaseURLKey = "propertyManager.apiBaseURL"
    private var autosaveTask: Task<Void, Never>?

    var apiBaseURL: String {
        get {
            let value = UserDefaults.standard.string(forKey: apiBaseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { return value }
            return "http://100.85.36.72:5062"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: apiBaseURLKey)
        }
    }

    var apiClient: PropertyAPIClient {
        PropertyAPIClient(baseURLString: apiBaseURL)
    }
""",
        """    private let apiBaseURLKey = "propertyManager.apiBaseURL"
    private let apiKeyKey = "propertyManager.apiKey"
    private let operatorPINKey = "propertyManager.operatorPIN"
    private var autosaveTask: Task<Void, Never>?

    var apiBaseURL: String {
        get {
            let value = UserDefaults.standard.string(forKey: apiBaseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { return value }
            return "http://100.85.36.72:5062"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: apiBaseURLKey)
        }
    }

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyKey) }
    }

    var operatorPIN: String {
        get { UserDefaults.standard.string(forKey: operatorPINKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: operatorPINKey) }
    }

    var apiClient: PropertyAPIClient {
        PropertyAPIClient(baseURLString: apiBaseURL, apiKey: apiKey, operatorPIN: operatorPIN)
    }
""",
        "MaintenanceStore auth credentials",
    )

    must_replace(
        APP,
        """            SidebarView(
                tasks: store.tasks,
                isOnline: store.isOnline,
                lastSyncAt: store.lastSyncAt,
                apiBaseURL: store.apiBaseURL,
                refreshAction: { Task { await store.refreshFromServer() } },
""",
        """            SidebarView(
                tasks: store.tasks,
                isOnline: store.isOnline,
                lastSyncAt: store.lastSyncAt,
                apiBaseURL: Binding(
                    get: { store.apiBaseURL },
                    set: { store.apiBaseURL = $0 }
                ),
                apiKey: Binding(
                    get: { store.apiKey },
                    set: { store.apiKey = $0 }
                ),
                operatorPIN: Binding(
                    get: { store.operatorPIN },
                    set: { store.operatorPIN = $0 }
                ),
                refreshAction: { Task { await store.refreshFromServer() } },
""",
        "ContentView SidebarView bindings",
    )

    must_replace(
        APP,
        """struct SidebarView: View {
    let tasks: [MaintenanceTask]
    let isOnline: Bool
    let lastSyncAt: Date?
    let apiBaseURL: String
    let refreshAction: () -> Void
""",
        """struct SidebarView: View {
    let tasks: [MaintenanceTask]
    let isOnline: Bool
    let lastSyncAt: Date?
    @Binding var apiBaseURL: String
    @Binding var apiKey: String
    @Binding var operatorPIN: String
    let refreshAction: () -> Void
""",
        "SidebarView binding props",
    )

    must_replace(
        APP,
        """            ConnectionStatusCard(
                isOnline: isOnline,
                lastSyncAt: lastSyncAt,
                apiBaseURL: apiBaseURL
            )
""",
        """            ConnectionStatusCard(
                isOnline: isOnline,
                lastSyncAt: lastSyncAt,
                apiBaseURL: $apiBaseURL,
                apiKey: $apiKey,
                operatorPIN: $operatorPIN
            )
""",
        "SidebarView ConnectionStatusCard bindings",
    )

    must_replace(
        APP,
        """struct ConnectionStatusCard: View {
    let isOnline: Bool
    let lastSyncAt: Date?
    let apiBaseURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(isOnline ? "Online" : "Offline", systemImage: isOnline ? "checkmark.circle.fill" : "wifi.slash")
                .font(.caption)
                .foregroundStyle(isOnline ? Color.green : Color.orange)

            if let lastSyncAt {
                Text("Updated \\(lastSyncAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not synced yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(apiBaseURL)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(isOnline ? 0.10 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
""",
        """struct ConnectionStatusCard: View {
    let isOnline: Bool
    let lastSyncAt: Date?
    @Binding var apiBaseURL: String
    @Binding var apiKey: String
    @Binding var operatorPIN: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(isOnline ? "Online" : "Offline", systemImage: isOnline ? "checkmark.circle.fill" : "wifi.slash")
                .font(.caption)
                .foregroundStyle(isOnline ? Color.green : Color.orange)

            if let lastSyncAt {
                Text("Updated \\(lastSyncAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not synced yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("API Base URL")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("http://host:5062", text: $apiBaseURL)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)

            Text("API Key")
                .font(.caption2)
                .foregroundStyle(.secondary)
            SecureField("PROPERTYMANAGER_API_KEY", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)

            Text("Operator PIN")
                .font(.caption2)
                .foregroundStyle(.secondary)
            SecureField("PROPERTYMANAGER_OPERATOR_PIN", text: $operatorPIN)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)

            Text(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Auth: missing API key" : "Auth: API key set")
                .font(.caption2)
                .foregroundStyle(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.orange : Color.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(isOnline ? 0.10 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
""",
        "ConnectionStatusCard auth fields",
    )


def copy_asset_api() -> None:
    if not REPO_ASSET.is_file():
        raise SystemExit(f"missing repo AssetAPIClient: {REPO_ASSET}")
    ASSET_API.write_text(REPO_ASSET.read_text(encoding="utf-8"), encoding="utf-8")
    print(f"copied: AssetAPIClient.swift -> {ASSET_API}")


def main() -> None:
    if not APP.is_file() or not API.is_file():
        raise SystemExit(f"Mac app sources not found under {ROOT}")
    copy_asset_api()
    patch_property_api_client()
    patch_store_and_ui()
    print("Mac API auth patch complete.")


if __name__ == "__main__":
    main()

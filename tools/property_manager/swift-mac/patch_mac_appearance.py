#!/usr/bin/env python3
"""Add appearance (Light / System / Dark) settings to Mac PropertyManagerApp.

Prerequisites: patch_mac_api_auth.py must have been applied first so that
ConnectionStatusCard has the auth fields and @Binding vars this patch extends.

What this adds:
  1. AppAppearance enum (mirrors iOS PropertyManagerApp.swift)
  2. @AppStorage in @main PropertyManagerApp struct + .preferredColorScheme() on WindowGroup
  3. @AppStorage + segmented Appearance picker in ConnectionStatusCard (sidebar UI)

Run:
    python3 patch_mac_appearance.py [/path/to/PropertyManagerApp]
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else Path.home() / "Development/PropertyManagerApp")
SWIFT = ROOT / "Sources/PropertyManagerApp/PropertyManagerApp.swift"

APPEARANCE_ENUM = """\
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    static func from(storageValue: String) -> AppAppearance {
        AppAppearance(rawValue: storageValue) ?? .system
    }
}

"""

APPEARANCE_KEY = '"propertyManager.appearance"'
APPEARANCE_STORAGE = (
    '    @AppStorage("propertyManager.appearance") '
    "private var appearanceRaw: String = AppAppearance.system.rawValue\n"
)


def must_replace(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        probe = new.strip().splitlines()[0].strip() if new.strip() else ""
        if probe and probe in text:
            print(f"skip (already): {label}")
            return text
        raise SystemExit(f"anchor not found: {label}\nMake sure patch_mac_api_auth.py ran first.")
    print(f"patched: {label}")
    return text.replace(old, new, 1)


def step_add_enum(text: str) -> str:
    if "enum AppAppearance" in text:
        print("skip: AppAppearance enum already present")
        return text
    # Insert before @main
    idx = text.find("@main")
    if idx < 0:
        raise SystemExit("@main not found in PropertyManagerApp.swift")
    return text[:idx] + APPEARANCE_ENUM + text[idx:]


def step_hook_main(text: str) -> str:
    """Add @AppStorage + .preferredColorScheme() to the @main App struct.

    Handles the standard single-store pattern Xcode generates:
        @StateObject private var store = MaintenanceStore()
        var body: some Scene {
            WindowGroup {
                ContentView()
                    .environmentObject(store)
            }
        }
    """
    if APPEARANCE_KEY in text and ".preferredColorScheme(" in text:
        print("skip: @main appearance hook already present")
        return text

    # Pattern: store decl immediately before body decl
    OLD_MAIN = (
        "    @StateObject private var store = MaintenanceStore()\n"
        "\n"
        "    var body: some Scene {\n"
        "        WindowGroup {\n"
        "            ContentView()\n"
        "                .environmentObject(store)\n"
        "        }\n"
        "    }"
    )
    NEW_MAIN = (
        "    @StateObject private var store = MaintenanceStore()\n"
        '    @AppStorage("propertyManager.appearance") private var appearanceRaw: String = AppAppearance.system.rawValue\n'
        "\n"
        "    var body: some Scene {\n"
        "        WindowGroup {\n"
        "            ContentView()\n"
        "                .environmentObject(store)\n"
        "                .preferredColorScheme(AppAppearance.from(storageValue: appearanceRaw).colorScheme)\n"
        "        }\n"
        "    }"
    )
    if OLD_MAIN in text:
        print("patched: @main appearance hook (standard pattern)")
        return text.replace(OLD_MAIN, NEW_MAIN, 1)

    # Fallback: store decl with no blank line before body
    OLD_MAIN_ALT = (
        "    @StateObject private var store = MaintenanceStore()\n"
        "    var body: some Scene {\n"
        "        WindowGroup {\n"
        "            ContentView()\n"
        "                .environmentObject(store)\n"
        "        }\n"
        "    }"
    )
    NEW_MAIN_ALT = (
        "    @StateObject private var store = MaintenanceStore()\n"
        '    @AppStorage("propertyManager.appearance") private var appearanceRaw: String = AppAppearance.system.rawValue\n'
        "    var body: some Scene {\n"
        "        WindowGroup {\n"
        "            ContentView()\n"
        "                .environmentObject(store)\n"
        "                .preferredColorScheme(AppAppearance.from(storageValue: appearanceRaw).colorScheme)\n"
        "        }\n"
        "    }"
    )
    if OLD_MAIN_ALT in text:
        print("patched: @main appearance hook (no-blank-line pattern)")
        return text.replace(OLD_MAIN_ALT, NEW_MAIN_ALT, 1)

    # Last resort: just patch ContentView().environmentObject(store) line
    OLD_ENV = (
        "            ContentView()\n"
        "                .environmentObject(store)\n"
    )
    NEW_ENV = (
        "            ContentView()\n"
        "                .environmentObject(store)\n"
        "                .preferredColorScheme(AppAppearance.from(storageValue: appearanceRaw).colorScheme)\n"
    )
    if OLD_ENV in text:
        # Also inject the @AppStorage decl; find @StateObject line and add after it
        old_store_line = "    @StateObject private var store = MaintenanceStore()\n"
        new_store_lines = (
            "    @StateObject private var store = MaintenanceStore()\n"
            '    @AppStorage("propertyManager.appearance") private var appearanceRaw: String = AppAppearance.system.rawValue\n'
        )
        if old_store_line in text:
            text = text.replace(old_store_line, new_store_lines, 1)
        text = text.replace(OLD_ENV, NEW_ENV, 1)
        print("patched: @main appearance hook (fallback last-resort)")
        return text

    raise SystemExit(
        "Could not find a suitable anchor in @main struct.\n"
        "Please manually add:\n"
        '    @AppStorage("propertyManager.appearance") private var appearanceRaw: String = '
        "AppAppearance.system.rawValue\n"
        "and .preferredColorScheme(AppAppearance.from(storageValue: appearanceRaw).colorScheme) "
        "on ContentView() in the WindowGroup."
    )


def step_sidebar_picker(text: str) -> str:
    """Add @AppStorage + segmented picker to ConnectionStatusCard (post auth-patch format)."""

    # Add @AppStorage property to ConnectionStatusCard struct
    text = must_replace(
        text,
        "struct ConnectionStatusCard: View {\n"
        "    let isOnline: Bool\n"
        "    let lastSyncAt: Date?\n"
        "    @Binding var apiBaseURL: String\n"
        "    @Binding var apiKey: String\n"
        "    @Binding var operatorPIN: String\n",
        "struct ConnectionStatusCard: View {\n"
        "    let isOnline: Bool\n"
        "    let lastSyncAt: Date?\n"
        "    @Binding var apiBaseURL: String\n"
        "    @Binding var apiKey: String\n"
        "    @Binding var operatorPIN: String\n"
        '    @AppStorage("propertyManager.appearance") private var appearanceRaw: String = AppAppearance.system.rawValue\n',
        "ConnectionStatusCard appearanceRaw @AppStorage",
    )

    # Add the picker UI at the bottom of the VStack, just before the closing braces
    OLD_CARD_TAIL = (
        "            Text(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"
        ' ? "Auth: missing API key" : "Auth: API key set")\n'
        "                .font(.caption2)\n"
        "                .foregroundStyle(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)"
        ".isEmpty ? Color.orange : Color.secondary)\n"
        "        }\n"
        "        .padding(10)\n"
        "        .frame(maxWidth: .infinity, alignment: .leading)\n"
        "        .background(Color.green.opacity(isOnline ? 0.10 : 0.04))\n"
        "        .clipShape(RoundedRectangle(cornerRadius: 12))\n"
        "    }\n"
        "}"
    )
    NEW_CARD_TAIL = (
        "            Text(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"
        ' ? "Auth: missing API key" : "Auth: API key set")\n'
        "                .font(.caption2)\n"
        "                .foregroundStyle(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)"
        ".isEmpty ? Color.orange : Color.secondary)\n"
        "\n"
        "            Divider()\n"
        "\n"
        "            Text(\"Appearance\")\n"
        "                .font(.caption2)\n"
        "                .foregroundStyle(.secondary)\n"
        "            Picker(\"Appearance\", selection: $appearanceRaw) {\n"
        "                ForEach(AppAppearance.allCases) { mode in\n"
        "                    Text(mode.label).tag(mode.rawValue)\n"
        "                }\n"
        "            }\n"
        "            .pickerStyle(.segmented)\n"
        "            .labelsHidden()\n"
        "        }\n"
        "        .padding(10)\n"
        "        .frame(maxWidth: .infinity, alignment: .leading)\n"
        "        .background(Color.green.opacity(isOnline ? 0.10 : 0.04))\n"
        "        .clipShape(RoundedRectangle(cornerRadius: 12))\n"
        "    }\n"
        "}"
    )

    return must_replace(text, OLD_CARD_TAIL, NEW_CARD_TAIL, "ConnectionStatusCard appearance picker")


def main() -> None:
    if not SWIFT.is_file():
        raise SystemExit(
            f"PropertyManagerApp.swift not found at {SWIFT}\n"
            f"Pass the project root as an argument: python3 patch_mac_appearance.py /path/to/PropertyManagerApp"
        )

    text = SWIFT.read_text(encoding="utf-8")

    # Check prerequisite: auth patch must have been applied
    if "ConnectionStatusCard" not in text or "@Binding var apiKey" not in text:
        raise SystemExit(
            "patch_mac_api_auth.py does not appear to have been applied yet.\n"
            "Run it first: python3 patch_mac_api_auth.py"
        )

    text = step_add_enum(text)
    text = step_hook_main(text)
    text = step_sidebar_picker(text)

    SWIFT.write_text(text, encoding="utf-8")
    print(f"wrote {SWIFT}")
    print()
    print("Appearance settings restored.")
    print("In the app: sidebar → Connection card → Appearance (Light / System / Dark segmented control)")
    print()
    print("Next: rebuild in Xcode and copy/run the new .app.")


if __name__ == "__main__":
    main()

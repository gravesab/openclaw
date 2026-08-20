#!/bin/zsh
set -euo pipefail

usage() {
    echo "Usage: $0 dev|prod [output-directory]"
    exit 2
}

ENVIRONMENT="${1:-}"
OUTPUT_ROOT="${2:-/tmp/propertymanager-packaged}"

case "$ENVIRONMENT" in
    dev)
        APP_NAME="DEV"
        BUNDLE_ID="ai.openclaw.propertymanager.macos.dev"
        ;;
    prod)
        APP_NAME="Property Manager"
        BUNDLE_ID="com.redbudranch.propertymanager"
        ;;
    *)
        usage
        ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "===== BUILD $ENVIRONMENT ====="
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
SOURCE_BIN="$BIN_DIR/PropertyManagerApp"

if [[ ! -x "$SOURCE_BIN" ]]; then
    echo "STOP: executable not found:"
    echo "$SOURCE_BIN"
    exit 1
fi

APP="$OUTPUT_ROOT/$APP_NAME.app"
PLIST="$APP/Contents/Info.plist"

rm -rf "$APP"

mkdir -p \
    "$APP/Contents/MacOS" \
    "$APP/Contents/Resources"

cp "$SOURCE_BIN" \
    "$APP/Contents/MacOS/PropertyManagerApp"

cp Resources/Info.plist \
    "$PLIST"

cp Resources/PropertyManagerIcon.icns \
    "$APP/Contents/Resources/PropertyManagerIcon.icns"

/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    "$PLIST"

/usr/libexec/PlistBuddy \
    -c "Set :CFBundleDisplayName $APP_NAME" \
    "$PLIST"

/usr/libexec/PlistBuddy \
    -c "Set :CFBundleName $APP_NAME" \
    "$PLIST"

/usr/bin/codesign \
    --force \
    --deep \
    --sign - \
    --entitlements Resources/PropertyManagerApp.entitlements \
    "$APP"

echo
echo "===== VERIFY ====="

echo -n "Path: "
echo "$APP"

echo -n "Bundle ID: "
/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' \
    "$PLIST"

echo -n "Display name: "
/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleDisplayName' \
    "$PLIST"

echo -n "Version: "
/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    "$PLIST"

echo -n "Build: "
/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$PLIST"

/usr/bin/codesign \
    --verify \
    --deep \
    --strict \
    --verbose=2 \
    "$APP"

echo
echo "PACKAGED_APP=$APP"

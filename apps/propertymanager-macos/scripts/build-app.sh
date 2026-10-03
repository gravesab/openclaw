#!/usr/bin/env bash
# Build the PropertyManager Mac app.
#
#   scripts/build-app.sh dev                  Rebuild and install into ~/Applications/DEV.app
#   scripts/build-app.sh production           Assemble dist/Property Manager.app
#   scripts/build-app.sh production --install Also install into ~/Applications (needs owner approval)
#
# DEV keeps its installed Info.plist and icon (bundle id, DEV environment marker, version);
# only the executable is replaced. Production uses Resources/Info.plist as its template.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"
INSTALL="${2:-}"
APPS_DIR="${HOME}/Applications"
BACKUP_DIR="${APPS_DIR}/OpenClaw App Backups"
STAMP="$(date +%Y%m%dT%H%M%S)"
EXECUTABLE="PropertyManagerApp"

usage() {
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 64
}

fail() {
  echo "error: $*" >&2
  exit 1
}

build_release() {
  echo "==> swift build -c release"
  (cd "$ROOT" && swift build -c release --arch arm64)
  BIN="$(cd "$ROOT" && swift build -c release --arch arm64 --show-bin-path)/${EXECUTABLE}"
  [[ -x "$BIN" ]] || fail "release executable missing at $BIN"
}

ensure_not_running() {
  local app="$1"
  if pgrep -f "${app}/Contents/MacOS/${EXECUTABLE}" >/dev/null; then
    fail "quit $(basename "$app") before installing"
  fi
}

backup_app() {
  local app="$1" label="$2"
  mkdir -p "$BACKUP_DIR"
  local dest="${BACKUP_DIR}/${label}-before-${STAMP}.app"
  ditto "$app" "$dest"
  echo "==> backed up $(basename "$app") to ${dest}"
}

verify_app() {
  local app="$1" expected_env="$2"
  codesign --verify --strict "$app"
  local env
  env="$(/usr/libexec/PlistBuddy -c 'Print :PropertyManagerEnvironment' "$app/Contents/Info.plist")"
  [[ "$env" == "$expected_env" ]] || fail "$app has PropertyManagerEnvironment=$env, expected $expected_env"
  echo "==> $(basename "$app"): $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" \
    "v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" \
    "build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" \
    "environment=$env"
}

build_dev() {
  local app="${APPS_DIR}/DEV.app"
  [[ -f "$app/Contents/Info.plist" ]] || fail "$app is not installed; DEV reuses its existing bundle"
  build_release
  ensure_not_running "$app"
  backup_app "$app" "DEV"
  install -m 755 "$BIN" "$app/Contents/MacOS/${EXECUTABLE}"
  codesign --force --sign - --preserve-metadata=identifier,entitlements,flags "$app"
  verify_app "$app" "development"
}

build_production() {
  local dist="${ROOT}/dist/Property Manager.app"
  build_release
  rm -rf "$dist"
  mkdir -p "$dist/Contents/MacOS" "$dist/Contents/Resources"
  cp "$ROOT/Resources/Info.plist" "$dist/Contents/Info.plist"
  cp "$ROOT/Resources/PropertyManagerIcon.icns" "$dist/Contents/Resources/"
  install -m 755 "$BIN" "$dist/Contents/MacOS/${EXECUTABLE}"
  codesign --force --sign - --entitlements "$ROOT/Resources/PropertyManagerApp.entitlements" "$dist"
  verify_app "$dist" "production"

  if [[ "$INSTALL" == "--install" ]]; then
    local app="${APPS_DIR}/Property Manager.app"
    if [[ -d "$app" ]]; then
      ensure_not_running "$app"
      backup_app "$app" "Property Manager"
      rm -rf "$app"
    fi
    ditto "$dist" "$app"
    verify_app "$app" "production"
  fi
}

case "$TARGET" in
  dev) build_dev ;;
  production) build_production ;;
  *) usage ;;
esac

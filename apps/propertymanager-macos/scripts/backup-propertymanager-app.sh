#!/usr/bin/env bash

set -euo pipefail

APP_DIR="$HOME/Development/PropertyManagerApp"

mkdir -p "$HOME/openclaw-backups/propertymanager-app"

BACKUP_FILE="$HOME/openclaw-backups/propertymanager-app/propertymanager-app-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

tar \
  --exclude="PropertyManagerApp/.build" \
  --exclude="PropertyManagerApp/backups/app" \
  -czf "$BACKUP_FILE" \
  -C "$HOME/Development" \
  PropertyManagerApp

echo
echo "PropertyManager app backup created:"
echo "$BACKUP_FILE"

ls -lh "$BACKUP_FILE"

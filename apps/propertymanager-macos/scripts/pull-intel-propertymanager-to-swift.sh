#!/usr/bin/env bash

set -euo pipefail

APP_DIR="$HOME/Development/PropertyManagerApp"
IMPORT_DIR="$APP_DIR/imports"
BACKUP_DIR="$APP_DIR/backups"
CSV_FILE="$IMPORT_DIR/maintenance_log_from_intelmini.csv"
SSH_KEY="${PROPERTYMANAGER_SSH_KEY:-$HOME/.ssh/propertymanager_intelmini}"

mkdir -p "$IMPORT_DIR" "$BACKUP_DIR"

cd "$APP_DIR"

echo "Pulling latest PropertyManager data from intelmini..."

if [ -f "$CSV_FILE" ]; then
  BACKUP_FILE="$BACKUP_DIR/maintenance_log_from_intelmini.csv.backup.$(date +%Y%m%d-%H%M%S)"
  cp "$CSV_FILE" "$BACKUP_FILE"
fi

if ! scp \
  -i "$SSH_KEY" \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  gravesab@intelmini.local:~/ai/projects/openclaw/tools/property_manager/maintenance_log.csv \
  "$CSV_FILE"; then
  echo "Intel mini pull failed."
  echo "The script could not connect using the dedicated SSH key:"
  echo "$SSH_KEY"
  echo "Run the pull from Terminal to see details, or confirm the key works before using this script."
  exit 1
fi

echo "Copied maintenance_log.csv"

"$APP_DIR/scripts/load-propertymanager-csv-into-swift-json.py"

echo "Loaded latest PropertyManager data."
echo "Pull complete."

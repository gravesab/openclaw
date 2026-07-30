#!/usr/bin/env bash

set -euo pipefail

EXPORT_FILE="$HOME/Downloads/propertymanager-swift-export-test.csv"
REMOTE_HOST="gravesab@intelmini.local"
REMOTE_DIR="~/ai/projects/openclaw/tools/property_manager"
REMOTE_FILE="maintenance_log.csv"

echo ""
echo "PropertyManager Push Sync"
echo "Push Swift export back to Intel mini"
echo "----------------------------------------"

if [ ! -f "$EXPORT_FILE" ]; then
  echo "ERROR: Swift export file not found:"
  echo "$EXPORT_FILE"
  echo ""
  echo "CSV files in Downloads:"
  ls -lh "$HOME"/Downloads/*.csv 2>/dev/null || true
  exit 1
fi

echo ""
echo "Swift export file:"
ls -lh "$EXPORT_FILE"

echo ""
echo "Preview:"
head -n 20 "$EXPORT_FILE"

echo ""
echo "Checking CSV header..."
HEADER=$(head -n 1 "$EXPORT_FILE")

if [ "$HEADER" != "area,item,last_done,warning_days,critical_days" ]; then
  echo "ERROR: CSV header is not the expected OpenClaw format."
  echo "Found:"
  echo "$HEADER"
  exit 1
fi

echo "Header OK."

echo ""
echo "Creating backup on Intel mini..."
ssh "$REMOTE_HOST" "
cd $REMOTE_DIR || exit 1

mkdir -p backups

if [ ! -f $REMOTE_FILE ]; then
  echo 'ERROR: maintenance_log.csv not found on Intel mini'
  exit 1
fi

BACKUP_FILE=\"backups/maintenance_log.csv.backup.swift-push.\$(date +%Y%m%d-%H%M%S)\"
cp $REMOTE_FILE \"\$BACKUP_FILE\"

echo 'Backup created:'
ls -lh \"\$BACKUP_FILE\"
"

echo ""
echo "Copying Swift export to Intel mini..."
scp "$EXPORT_FILE" "$REMOTE_HOST:~/ai/projects/openclaw/tools/property_manager/maintenance_log.csv"

echo ""
echo "Verifying updated Intel mini file..."
ssh "$REMOTE_HOST" '
cd ~/ai/projects/openclaw/tools/property_manager || exit 1

echo ""
echo "Updated maintenance_log.csv:"
ls -lh maintenance_log.csv

echo ""
echo "First 20 lines:"
head -n 20 maintenance_log.csv

echo ""
echo "PropertyManager summary test:"
cd ~/ai/projects/openclaw || exit 1
./tools/property_manager/propertymanager-summary.sh
'

echo ""
echo "Push complete."

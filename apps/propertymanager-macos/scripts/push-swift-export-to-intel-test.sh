#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="${PROPERTYMANAGER_SSH_KEY:-$HOME/.ssh/propertymanager_intelmini}"
INTEL_USER="gravesab"
INTEL_HOST="intelmini"
REMOTE_DIR="/home/gravesab/ai/projects/openclaw/tools/property_manager"
REMOTE_FILE="$REMOTE_DIR/maintenance_log.csv"
STAMP="$(date +%Y%m%d-%H%M%S)"

LOCAL_EXPORT="${1:-}"

if [[ -z "$LOCAL_EXPORT" ]]; then
  echo "Usage: $0 /path/to/staging_publish.csv"
  exit 1
fi

echo "Checking staging CSV..."
if [[ ! -f "$LOCAL_EXPORT" ]]; then
  echo "ERROR: Staging CSV not found:"
  echo "$LOCAL_EXPORT"
  exit 1
fi

HEADER="$(head -n 1 "$LOCAL_EXPORT" | tr -d '\r')"
EXPECTED="area,item,last_done,warning_days,critical_days"
if [[ "$HEADER" != "$EXPECTED" ]]; then
  echo "ERROR: CSV header is not the expected OpenClaw format."
  echo "Found: $HEADER"
  exit 1
fi

echo "Header OK."
echo "Local staging CSV:"
ls -lh "$LOCAL_EXPORT"

echo
echo "Backing up Intel mini maintenance_log.csv..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$INTEL_USER@$INTEL_HOST"   "mkdir -p '$REMOTE_DIR/backups' && cd '$REMOTE_DIR' && cp maintenance_log.csv backups/maintenance_log.csv.backup.swift-publish-$STAMP"

echo "Backup created on Intel mini:"
echo "$REMOTE_DIR/backups/maintenance_log.csv.backup.swift-publish-$STAMP"

echo
echo "Copying staging CSV to Intel mini..."
scp -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10   "$LOCAL_EXPORT" "$INTEL_USER@$INTEL_HOST:$REMOTE_FILE"

echo
echo "Verifying Intel mini file after publish..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$INTEL_USER@$INTEL_HOST"   "cd '$REMOTE_DIR' && echo 'Line count:' && wc -l maintenance_log.csv && echo && echo 'First 5 lines:' && head -5 maintenance_log.csv"

echo
echo "Publish complete."

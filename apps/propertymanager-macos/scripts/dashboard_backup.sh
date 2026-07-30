#!/usr/bin/env bash
set -euo pipefail

INTEL_USER="gravesab"
INTEL_HOST="intelmini"
SSH_KEY="/Users/andrewgraves/.ssh/propertymanager_intelmini"
REMOTE_BACKUP_SCRIPT="/home/gravesab/ai/projects/openclaw/tools/dashboard/dashboard_property_backup.sh"

echo "Starting Intel mini dashboard/property backup..."

if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 "$INTEL_USER@$INTEL_HOST" "$REMOTE_BACKUP_SCRIPT"; then
  echo "Backup request completed."
else
  echo "Dashboard backup failed."
  echo "The app could not connect using the dedicated SSH key:"
  echo "$SSH_KEY"
  echo "Run the backup from Terminal to see details, or confirm the key works before using this button."
fi

exit 0

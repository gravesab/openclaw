#!/usr/bin/env bash
set -euo pipefail

# Automatic legacy senders are muted when the single daily digest is enabled.
if [ -f "${OPENCLAW_TELEGRAM_POLICY_FILE:-$HOME/.openclaw/telegram-health-only}" ]; then
  echo "Legacy Telegram notification suppressed; daily system health digest enabled."
  exit 0
fi

source ~/.openclaw/credentials/telegram.env

MESSAGE="${*:-OpenClaw Telegram test message}"

curl -s \
  -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  -d text="${MESSAGE}" \
  | python3 -m json.tool

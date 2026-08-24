#!/usr/bin/env bash
set -euo pipefail

TELEGRAM_ENV="${OPENCLAW_TELEGRAM_ENV:-$HOME/.openclaw/credentials/telegram.env}"
source "$TELEGRAM_ENV"

MESSAGE="${*:-OpenClaw Telegram test message}"

curl -s \
  -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  -d text="${MESSAGE}" \
  | python3 -m json.tool

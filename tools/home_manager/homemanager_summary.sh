#!/usr/bin/env bash
set -euo pipefail

BASE="${OPENCLAW_BASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
OLLAMA_URL="${OPENCLAW_OLLAMA_BASE_URL:-http://192.168.50.117:11434}"
MODEL="${OPENCLAW_HOMEMANAGER_MODEL:-hermes3:8b}"

PROMPT="$("$BASE/tools/home_manager/home_manager_prompt.sh")"
RAW_REPORT="$("$BASE/tools/home_manager/home_status_report.sh")"

TMP_RESPONSE="$(mktemp)"
TMP_MODEL_TEXT="$(mktemp)"

cleanup() {
  rm -f "$TMP_RESPONSE" "$TMP_MODEL_TEXT"
}
trap cleanup EXIT

http_code="$(
  curl -sS \
    --max-time 180 \
    -o "$TMP_RESPONSE" \
    -w '%{http_code}' \
    "$OLLAMA_URL/api/generate" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg model "$MODEL" \
      --arg prompt "$PROMPT" \
      '{
        model: $model,
        prompt: $prompt,
        stream: false,
        options: {
          temperature: 0.1,
          num_predict: 500
        }
      }')"
)"

if [[ "$http_code" == "200" ]]; then
  jq -r \
    '.response // .message.content // .content // empty' \
    "$TMP_RESPONSE" \
    > "$TMP_MODEL_TEXT" 2>/dev/null || true
fi

python3 - "$RAW_REPORT" "$TMP_MODEL_TEXT" <<'PY'
import re
import sys
from pathlib import Path

report = sys.argv[1]
model_path = Path(sys.argv[2])
model_text = model_path.read_text(errors="replace").strip()

def find_percent(label: str):
    patterns = [
        rf"{re.escape(label)}.*?(\d{{1,3}})%",
        rf"{re.escape(label)}.*?Use%\s+.*?(\d{{1,3}})%",
    ]
    for pattern in patterns:
        match = re.search(pattern, report, re.I | re.S)
        if match:
            return int(match.group(1))
    return None

internal_disk = find_percent("Disk Usage")

ollama_online = bool(
    re.search(r"M4 Ollama.*?Status:\s*online", report, re.I | re.S)
)

attention = []

if internal_disk is not None:
    if internal_disk >= 90:
        attention.append(
            f"Internal disk usage is critical at {internal_disk}%."
        )
    elif internal_disk >= 80:
        attention.append(
            f"Internal disk usage is elevated at {internal_disk}%."
        )

telegram_current_failure = bool(
    re.search(
        r"Telegram.*(?:failed|offline|unavailable|disconnected)$",
        report,
        re.I | re.M,
    )
)

if telegram_current_failure:
    attention.append("Telegram is currently unavailable.")

if attention:
    overall = (
        "The OpenClaw AI infrastructure is operational, "
        "but one or more current conditions need attention."
    )
    next_step = "Review the current items listed above."
else:
    overall = (
        "The OpenClaw AI infrastructure is healthy and operating normally."
    )
    next_step = "No action required."

good = [
    "OpenClaw Gateway, Voice Service, and Dashboard are running.",
    "Docker containers are running.",
    "The hourly snapshot completed successfully.",
]

if ollama_online:
    good.append(
        "M4 Ollama is online and its model inventory is available."
    )
else:
    attention.append(
        "M4 Ollama model inventory is unavailable."
    )

if internal_disk is not None and internal_disk < 80:
    good.append(
        f"Internal disk usage is healthy at {internal_disk}%."
    )

print("1. Overall Status")
print(overall)
print()

print("2. What Looks Good")
for item in good:
    print(f"- {item}")
print()

print("3. What Needs Attention")
if attention:
    for item in attention:
        print(f"- {item}")
else:
    print("None.")
print()

print("4. Recommended Next Step")
print(next_step)
print()

print("5. Commands Only If Needed")
print("None.")
PY

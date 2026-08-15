#!/usr/bin/env bash
set -euo pipefail

echo "=============================="
echo "OpenClaw AI Infrastructure Report"
echo "=============================="
echo

echo "Host:"
hostname
hostname -I
echo

echo "Date:"
date
echo

echo "=============================="
echo "OpenClaw Gateway"
echo "=============================="
systemctl --user --no-pager --lines=15 status openclaw-gateway.service || true
echo

echo "=============================="
echo "Voice Service"
echo "=============================="
systemctl --user --no-pager --lines=15 status openclaw-voice.service || true
echo

echo "=============================="
echo "Dashboard"
echo "=============================="
systemctl --user --no-pager --lines=15 status openclaw-dashboard.service || true
echo

echo "=============================="
echo "Docker Containers"
echo "=============================="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo

echo "=============================="
echo "M4 Ollama"
echo "=============================="

OLLAMA_BASE_URL="${OPENCLAW_OLLAMA_BASE_URL:-http://192.168.50.117:11434}"
OLLAMA_TAGS_FILE="$(mktemp)"

if curl -fsS --max-time 8   "$OLLAMA_BASE_URL/api/tags"   -o "$OLLAMA_TAGS_FILE"
then
  python3 - "$OLLAMA_BASE_URL" "$OLLAMA_TAGS_FILE" <<'PY_OLLAMA'
import json
import sys
from pathlib import Path

base_url = sys.argv[1]
data = json.loads(Path(sys.argv[2]).read_text())
models = sorted(
    str(item.get("name") or item.get("model") or "unknown")
    for item in data.get("models", [])
)

print(f"Ollama URL: {base_url}")
print("Status: online")
print(f"Model count: {len(models)}")
print("Models:")
for model in models:
    print(model)
PY_OLLAMA
else
  echo "Ollama URL: $OLLAMA_BASE_URL"
  echo "Status: offline"
fi

rm -f "$OLLAMA_TAGS_FILE"
echo

echo "=============================="
echo "AI Benchmark"
echo "=============================="
echo "Status: deferred"
echo "Reason: legacy Ollama benchmark retired during beta migration."
echo "Replacement: AI Intelligence benchmark framework."
echo

echo "=============================="
echo "Scrypted"
echo "=============================="
"${OPENCLAW_BASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/tools/scrypted/scrypted_status.sh" || true
echo

echo "=============================="
echo "Disk Usage"
echo "=============================="
df -h /
echo

echo "=============================="
echo "Memory"
echo "=============================="
free -h
echo

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

import redis
import requests

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.security.allowlist import _is_allowed_host, _is_loopback_only
from tools.security.shell_guard import allowed_url, enforce_dev, run_checked

OLLAMA_URL = os.environ.get(
    "OPENCLAW_OLLAMA_GENERATE_URL",
    "http://127.0.0.1:11434/api/generate",
)

MODEL = os.environ.get("OPENCLAW_AI_SUMMARY_MODEL", "llama3.2:3b")

DB_CONTAINER = os.environ.get("OPENCLAW_DB_CONTAINER", "postgres")
DB_NAME = os.environ.get("OPENCLAW_DB_NAME", "openclaw")
DB_USER = os.environ.get("OPENCLAW_DB_USER", "openclaw")

REDIS_HOST = "127.0.0.1"
REDIS_PORT = 6379


def _redis_client():
    enforce_dev()
    if not _is_loopback_only(REDIS_HOST) or not _is_allowed_host(
        REDIS_HOST,
        service="ai_summary",
    ):
        print("[ai_summary] redis host refused", file=sys.stderr)
        return None
    client = redis.Redis(
        host=REDIS_HOST,
        port=REDIS_PORT,
        decode_responses=True,
        socket_connect_timeout=5,
        socket_timeout=5,
    )
    try:
        client.ping()
        return client
    except Exception as exc:
        print(f"[ai_summary] redis dry-run: {type(exc).__name__}", file=sys.stderr)
        try:
            client.close()
        except Exception:
            pass
        return None


def cmd(command):
    enforce_dev()
    return run_checked(command, state_changing=False, timeout=30, service="ai_summary")

def recent_events(limit=15):
    enforce_dev()
    client = _redis_client()
    if client is None:
        return ""
    try:
        raw = client.lrange("openclaw:events", 0, limit)
    except Exception as exc:
        print(f"[ai_summary] redis dry-run: {type(exc).__name__}", file=sys.stderr)
        return ""

    events = []

    for item in raw:

        try:
            event = json.loads(item)

            events.append(
                f"[{event['agent']}] "
                f"{event['type']} - "
                f"{event['message']}"
            )

        except:
            pass

    return "\n".join(events)

def recent_memories(limit=5):
    enforce_dev()
    safe_limit = max(1, min(int(limit), 50))
    if not (re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", DB_CONTAINER) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", DB_USER) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", DB_NAME)):
        return "command refused"
    query = f"""
        SELECT json_build_object(
            'agent_name', agent_name,
            'category', category,
            'content', LEFT(content, 400)
        )::text
        FROM long_term_memory
        WHERE category != 'gmail_summary'
        ORDER BY created_at DESC
        LIMIT {safe_limit}
    """
    result = run_checked(
        [
            "docker", "exec", DB_CONTAINER,
            "psql", "-U", DB_USER, "-d", DB_NAME,
            "-v", "ON_ERROR_STOP=1", "-At", "-c", query,
        ],
        state_changing=True,
        timeout=20,
        service="ai_summary",
    )
    if result.startswith("dry-run:") or result in {"command refused", "eject"}:
        return result

    output = []
    for line in result.splitlines():
        row = json.loads(line)
        output.append(
            f"[{row['agent_name']}:{row['category']}] {row['content']}"
        )

    return "\n".join(output)

def infrastructure_status():

    return cmd(
        ["docker", "ps", "--format", "{{.Names}} - {{.Status}}"]
    )

def generate_summary():
    enforce_dev()

    prompt = f"""
You are OpenClaw AI Operations Summary Agent.

Current Infrastructure:
{infrastructure_status()}

Recent Events:
{recent_events()}

Recent Memories:
{recent_memories()}

Generate a concise operational summary:
- infrastructure health
- recent incidents
- remediation actions
- any concerns
- recommended attention items
"""

    if not allowed_url(OLLAMA_URL, service="ai_summary"):
        return "summary refused: model URL is not allowlisted"

    response = requests.post(
        OLLAMA_URL,
        json={
            "model": MODEL,
            "prompt": prompt,
            "stream": False
        },
        timeout=180,
        # The allowlist checks only this URL; a 307/308 would replay the prompt elsewhere.
        allow_redirects=False,
    )

    response.raise_for_status()

    return response.json()["response"]

def publish(summary):
    enforce_dev()

    event = {
        "timestamp": datetime.now().isoformat(),
        "agent": "AISummaryAgent",
        "type": "ai_operational_summary",
        "message": summary,
    }

    print()
    client = _redis_client()
    if client is None:
        print("[ai_summary] redis dry-run; event not published", file=sys.stderr)
    else:
        try:
            client.lpush("openclaw:events", json.dumps(event))
        except Exception as exc:
            print(f"[ai_summary] redis dry-run: {type(exc).__name__}", file=sys.stderr)

    print()
    print("=" * 60)
    print("AI OPERATIONAL SUMMARY")
    print("=" * 60)
    print()
    print(summary)

if __name__ == "__main__":

    enforce_dev()
    summary = generate_summary()

    publish(summary)

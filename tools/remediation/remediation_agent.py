import json
import sys
from datetime import datetime
from pathlib import Path

import redis

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.security.allowlist import _is_allowed_host, _is_loopback_only
from tools.security.shell_guard import enforce_dev, run_checked

REDIS_HOST = "127.0.0.1"
REDIS_PORT = 6379


def _redis_client():
    enforce_dev()
    if not _is_loopback_only(REDIS_HOST) or not _is_allowed_host(
        REDIS_HOST,
        service="remediation",
    ):
        print("[remediation] redis host refused", file=sys.stderr)
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
        print(f"[remediation] redis dry-run: {type(exc).__name__}", file=sys.stderr)
        try:
            client.close()
        except Exception:
            pass
        return None


def publish(event_type, message):
    enforce_dev()
    event = {
        "timestamp": datetime.now().isoformat(),
        "agent": "AutoRemediationAgent",
        "type": event_type,
        "message": message,
    }

    print()
    print(json.dumps(event, indent=2))
    client = _redis_client()
    if client is None:
        print("[remediation] redis dry-run; event not published", file=sys.stderr)
        return
    try:
        client.lpush("openclaw:events", json.dumps(event))
    except Exception as exc:
        print(f"[remediation] redis dry-run: {type(exc).__name__}", file=sys.stderr)

def cmd(command):
    enforce_dev()
    return run_checked(command, state_changing=True, timeout=30, service="remediation")

def restart_container(container):
    if container not in {"homeassistant", "scrypted"}:
        publish("container_restart", f"Restart attempt for {container}: command refused")
        return
    result = cmd(["docker", "restart", container])

    publish(
        "container_restart",
        f"Restart attempt for {container}: {result}"
    )

def inspect_latest_events():
    enforce_dev()
    client = _redis_client()
    if client is None:
        publish("no_action_needed", "redis dry-run")
        return
    raw_events = client.lrange("openclaw:events", 0, 10)

    remediated = False

    for raw in raw_events:
        try:
            event = json.loads(raw)

            event_type = event.get("type", "")

            if event_type == "homeassistant_offline":
                publish(
                    "incident_response",
                    "Detected Home Assistant outage. Attempting remediation."
                )

                restart_container("homeassistant")
                remediated = True

            elif event_type == "scrypted_offline":
                publish(
                    "incident_response",
                    "Detected Scrypted outage. Attempting remediation."
                )

                restart_container("scrypted")
                remediated = True

        except Exception as e:
            publish("remediation_error", str(e))

    if not remediated:
        publish(
            "no_action_needed",
            "No remediation needed. Home Assistant and Scrypted appear healthy."
        )

if __name__ == "__main__":
    enforce_dev()
    print("=" * 60)
    print("AUTO REMEDIATION AGENT")
    print("=" * 60)

    inspect_latest_events()

"""Sense-only watchdog. A down Redis stays a dry-run and does not crash."""

import hashlib
import importlib.util
import json
import sys
from datetime import datetime
from pathlib import Path

import redis

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.security.allowlist import (
    _append_chain,
    _is_allowed_host,
    _is_loopback_only,
    _notify_sentinel,
)
from tools.security.shell_guard import run_checked

REDIS_HOST = "127.0.0.1"
REDIS_PORT = 6379
_CHANNEL = "openclaw:security"


def _enforce_dev() -> None:
    path = ROOT / "ranch-redteam" / "ranch_redteam_guards.py"
    spec = importlib.util.spec_from_file_location("ranch_redteam_guards", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("HARD RULE: guards missing")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.HardRules.enforce_dev()
    module.HardRules.enforce_local_only()


def _redis_client():
    """Ping loopback Redis twice. Return None instead of raising."""
    if not _is_loopback_only(REDIS_HOST) or not _is_allowed_host(
        REDIS_HOST,
        service="watchdog",
    ):
        print("[watchdog] redis host refused", file=sys.stderr)
        return None
    last_error: Exception | None = None
    for _attempt in (1, 2):
        client = redis.Redis(
            host=REDIS_HOST,
            port=REDIS_PORT,
            decode_responses=True,
            socket_connect_timeout=5,
            socket_timeout=5,
        )
        try:
            client.ping()
            pubsub = client.pubsub(ignore_subscribe_messages=True)
            pubsub.subscribe(_CHANNEL)
            pubsub.get_message(timeout=0.05)
            pubsub.unsubscribe()
            pubsub.close()
            return client
        except Exception as exc:
            last_error = exc
            try:
                client.close()
            except Exception:
                pass
    print(f"[watchdog] redis dry-run: {type(last_error).__name__}", file=sys.stderr)
    return None


def _audit(check: str, message: str, redis_up: bool) -> None:
    event = {
        "type": "watchdog.sense",
        "service": "watchdog",
        "score": 0.0,
        "payload": {
            "check": check,
            "redis": "up" if redis_up else "dry-run",
            "message_hash": hashlib.sha256(message.encode()).hexdigest(),
        },
    }
    _append_chain(event)
    _notify_sentinel(event)


def run_cmd(cmd):
    """Sense only. This agent does not change services."""
    return run_checked(cmd, state_changing=False, timeout=30, service="watchdog")


def publish(agent, event_type, message, client):
    event = {
        "timestamp": datetime.now().isoformat(),
        "agent": agent,
        "type": event_type,
        "message": message,
    }
    print(json.dumps(event, indent=2))
    _audit(event_type, message, client is not None)
    if client is None:
        print("[watchdog] redis dry-run; event not published", file=sys.stderr)
        return
    try:
        client.lpush("openclaw:events", json.dumps(event))
        client.publish(_CHANNEL, json.dumps({"type": event_type, "service": "watchdog"}))
    except Exception as exc:
        print(f"[watchdog] redis dry-run: {type(exc).__name__}", file=sys.stderr)


def check_docker(client):
    output = run_cmd(["docker", "ps", "--format", "{{.Names}} {{.Status}}"])
    publish("WatchdogAgent", "docker_status", output, client)


def check_disk(client):
    output = run_cmd(["df", "-h", "/"])
    lines = [line for line in output.splitlines() if line.strip()]
    publish("WatchdogAgent", "disk_status", lines[-1] if lines else output, client)


def check_memory(client):
    output = run_cmd(["free", "-h"])
    memory = next((line for line in output.splitlines() if line.startswith("Mem")), output)
    publish("WatchdogAgent", "memory_status", memory, client)


def check_services(client):
    required = ["postgres", "redis", "portainer", "homeassistant", "scrypted"]
    running = run_cmd(["docker", "ps", "--format", "{{.Names}}"]).splitlines()
    missing = [name for name in required if name not in running]
    if missing:
        publish("WatchdogAgent", "service_alert", f"Missing containers: {', '.join(missing)}", client)
    else:
        publish("WatchdogAgent", "service_ok", "All required containers are running.", client)


def main() -> int:
    _enforce_dev()
    client = _redis_client()
    if client is None:
        _audit("redis", "dry-run", False)
    check_services(client)
    check_docker(client)
    check_disk(client)
    check_memory(client)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

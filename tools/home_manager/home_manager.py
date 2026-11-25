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
        service="home_manager",
    ):
        print("[home_manager] redis host refused", file=sys.stderr)
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
        print(f"[home_manager] redis dry-run: {type(exc).__name__}", file=sys.stderr)
        try:
            client.close()
        except Exception:
            pass
        return None


def cmd(command, timeout=15):
    enforce_dev()
    return run_checked(command, state_changing=False, timeout=timeout, service="home_manager")

def publish(event_type, message):
    enforce_dev()

    event = {
        "timestamp": datetime.now().isoformat(),
        "agent": "HomeManager",
        "type": event_type,
        "message": message,
    }

    print()
    print(json.dumps(event, indent=2))
    client = _redis_client()
    if client is None:
        print("[home_manager] redis dry-run; event not published", file=sys.stderr)
        return
    try:
        client.lpush("openclaw:events", json.dumps(event))
    except Exception as exc:
        print(f"[home_manager] redis dry-run: {type(exc).__name__}", file=sys.stderr)

def _container_running(output):
    """True only for a docker status line that says the container is Up."""
    if not isinstance(output, str):
        return False
    return any(line.strip().startswith("Up") for line in output.splitlines())


def check_homeassistant():

    output = cmd(
        ["docker", "ps", "--filter", "name=homeassistant", "--format", "{{.Status}}"]
    )

    if _container_running(output):
        publish(
            "homeassistant_ok",
            f"Home Assistant container running: {output}"
        )
    else:
        publish(
            "homeassistant_offline",
            "Home Assistant container not running."
        )

def check_scrypted():

    output = cmd(
        ["docker", "ps", "--filter", "name=scrypted", "--format", "{{.Status}}"]
    )

    if _container_running(output):
        publish(
            "scrypted_ok",
            f"Scrypted container running: {output}"
        )
    else:
        publish(
            "scrypted_offline",
            "Scrypted container not running."
        )

def check_bluetooth():

    output = cmd(["bluetoothctl", "show"])

    if "Powered: yes" in output:
        publish(
            "bluetooth_ok",
            "Bluetooth adapter is powered and operational."
        )
    else:
        publish(
            "bluetooth_problem",
            "Bluetooth adapter may not be operational."
        )

if __name__ == "__main__":

    enforce_dev()
    print("=" * 60)
    print("HOME MANAGER")
    print("=" * 60)

    check_homeassistant()
    check_scrypted()
    check_bluetooth()

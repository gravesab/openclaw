import json
import sys
from datetime import datetime
from pathlib import Path

import redis

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.security.shell_guard import run_checked

r = redis.Redis(
    host="127.0.0.1",
    port=6379,
    decode_responses=True
)

def cmd(command, timeout=15):
    return run_checked(command, state_changing=False, timeout=timeout, service="home_manager")

def publish(event_type, message):

    event = {
        "timestamp": datetime.now().isoformat(),
        "agent": "HomeManager",
        "type": event_type,
        "message": message,
    }

    r.lpush(
        "openclaw:events",
        json.dumps(event)
    )

    print()
    print(json.dumps(event, indent=2))

def check_homeassistant():

    output = cmd(
        ["docker", "ps", "--filter", "name=homeassistant", "--format", "{{.Status}}"]
    )

    if output:
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

    if output:
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

    print("=" * 60)
    print("HOME MANAGER")
    print("=" * 60)

    check_homeassistant()
    check_scrypted()
    check_bluetooth()

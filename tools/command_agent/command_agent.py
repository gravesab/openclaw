import json
import sys
from datetime import datetime
from pathlib import Path

import redis

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.security.allowlist import _is_allowed_host, _is_loopback_only
from tools.security.shell_guard import enforce_dev, run_checked, vet_text

REDIS_HOST = "127.0.0.1"
REDIS_PORT = 6379


def _redis_client():
    enforce_dev()
    if not _is_loopback_only(REDIS_HOST) or not _is_allowed_host(
        REDIS_HOST,
        service="command_agent",
    ):
        print("[command_agent] redis host refused", file=sys.stderr)
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
        print(f"[command_agent] redis dry-run: {type(exc).__name__}", file=sys.stderr)
        try:
            client.close()
        except Exception:
            pass
        return None


def cmd(command, *, state_changing=False):
    enforce_dev()
    return run_checked(
        command,
        state_changing=state_changing,
        timeout=30,
        service="command_agent",
    )

def publish(event_type, message):
    enforce_dev()

    event = {
        "timestamp": datetime.now().isoformat(),
        "agent": "CommandAgent",
        "type": event_type,
        "message": message,
    }

    print()
    print(json.dumps(event, indent=2))
    client = _redis_client()
    if client is None:
        print("[command_agent] redis dry-run; event not published", file=sys.stderr)
        return
    try:
        client.lpush("openclaw:events", json.dumps(event))
    except Exception as exc:
        print(f"[command_agent] redis dry-run: {type(exc).__name__}", file=sys.stderr)

def summarize_infrastructure():

    docker_status = cmd(
        ["docker", "ps", "--format", "{{.Names}} - {{.Status}}"]
    )

    memory_output = cmd(["free", "-h"])
    memory = next((line for line in memory_output.splitlines() if line.startswith("Mem")), memory_output)

    disk_output = cmd(["df", "-h", "/"])
    disk_lines = [line for line in disk_output.splitlines() if line.strip()]
    disk = disk_lines[-1] if disk_lines else disk_output

    response = f'''
INFRASTRUCTURE SUMMARY

Docker Containers:
{docker_status}

Memory:
{memory}

Disk:
{disk}
'''

    publish(
        "infrastructure_summary",
        response
    )

def recent_events():
    enforce_dev()
    client = _redis_client()
    if client is None:
        publish("recent_events", "redis dry-run")
        return

    raw = client.lrange(
        "openclaw:events",
        0,
        10
    )

    output = []

    for item in raw:

        try:
            event = json.loads(item)

            output.append(
                f"[{event['agent']}] {event['type']}\n{event['message']}"
            )

        except:
            pass

    publish(
        "recent_events",
        "\n\n".join(output)
    )

def restart_container(container):

    if container not in {"homeassistant", "scrypted"}:
        publish("container_restart", f"{container}: command refused")
        return

    result = cmd(
        ["docker", "restart", container],
        state_changing=True,
    )

    publish(
        "container_restart",
        f"{container}: {result}"
    )

def docker_status():

    result = cmd(
        ["docker", "ps", "--format", "{{.Names}} - {{.Status}}"]
    )

    publish(
        "docker_status",
        result
    )

def search_memory(term):
    enforce_dev()

    verdict = vet_text(term if isinstance(term, str) else "", service="command_agent")
    if verdict != "ok":
        publish("memory_search", "eject" if verdict == "eject" else "command refused")
        return
    root = ROOT / "tools" / "memory_context"
    result = run_checked(
        [str(root / ".venv" / "bin" / "python3"), str(root / "memory_context_agent.py")],
        cwd=str(root),
        timeout=30,
        service="command_agent",
        input_text=term,
    )

    publish(
        "memory_search",
        result
    )

def handle_command(command):
    enforce_dev()

    verdict = vet_text(command if isinstance(command, str) else "", service="command_agent")
    if verdict != "ok":
        publish("command_eject", "eject" if verdict == "eject" else "command refused")
        return

    command = command.lower().strip()

    if "summarize infrastructure" in command:
        summarize_infrastructure()

    elif command == "events":
        recent_events()

    elif "restart homeassistant" in command:
        restart_container("homeassistant")

    elif "restart scrypted" in command:
        restart_container("scrypted")

    elif "show docker status" in command:
        docker_status()

    elif "search memory for" in command:

        term = command.replace(
            "search memory for",
            ""
        ).strip()

        search_memory(term)

    else:

        publish(
            "unknown_command",
            f"Unknown command: {command}"
        )

if __name__ == "__main__":

    enforce_dev()
    print("=" * 60)
    print("COMMAND AGENT")
    print("=" * 60)

    command = input("Enter command: ")

    handle_command(command)

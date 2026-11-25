import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.security.allowlist import _is_allowed_host
from tools.security.shell_guard import allowed_url, enforce_dev, run_checked

import psycopg2
import redis
import requests

REDIS_HOST = os.environ.get("OPENCLAW_REDIS_HOST", "127.0.0.1")
POSTGRES_DB = {
    "host": os.environ.get("OPENCLAW_DB_HOST", "127.0.0.1"),
    "port": int(os.environ.get("OPENCLAW_DB_PORT", "5432")),
    "dbname": os.environ.get("OPENCLAW_DB_NAME", "openclaw"),
    "user": os.environ.get("OPENCLAW_DB_USER", "openclaw"),
}
if os.environ.get("OPENCLAW_DB_PASSWORD"):
    POSTGRES_DB["password"] = os.environ["OPENCLAW_DB_PASSWORD"]

DASHBOARD_URL = "http://127.0.0.1:5050"
OLLAMA_URL = os.environ.get(
    "OPENCLAW_OLLAMA_BASE_URL",
    "http://127.0.0.1:11434",
).rstrip("/")
VOICE_HEALTH_URL = "http://127.0.0.1:6060/health"
HOME_ASSISTANT_URL = "http://127.0.0.1:8123"
SCRYPTED_CONTAINER = "scrypted"

REQUIRED_CONTAINERS = [
    "postgres",
    "redis",
    "portainer",
    "homeassistant",
    "scrypted",
]

def run_cmd(command):
    enforce_dev()
    return run_checked(command, state_changing=False, timeout=30, service="recovery")

def publish(event_type, message):
    enforce_dev()
    event = {
        "timestamp": datetime.now().isoformat(),
        "agent": "RecoveryAgent",
        "type": event_type,
        "message": message,
    }

    print(json.dumps(event, indent=2))
    if not _is_loopback_only(REDIS_HOST):
        print("redis refused: OPENCLAW_REDIS_HOST is not loopback", file=sys.stderr)
        return
    try:
        r = redis.Redis(
            host=REDIS_HOST,
            port=6379,
            decode_responses=True,
            socket_connect_timeout=5,
            socket_timeout=5,
        )
        r.lpush("openclaw:events", json.dumps(event))
    except Exception as exc:
        print(f"[recovery] redis dry-run: {type(exc).__name__}", file=sys.stderr)

def check_redis():
    enforce_dev()
    if not _is_loopback_only(REDIS_HOST):
        return False, "Redis host is not loopback"
    try:
        r = redis.Redis(
            host=REDIS_HOST,
            port=6379,
            decode_responses=True,
            socket_connect_timeout=5,
            socket_timeout=5,
        )
        return r.ping(), "Redis reachable"
    except Exception as e:
        return False, f"Redis failed: {e}"

def check_postgres():
    enforce_dev()
    if not _is_loopback_only(POSTGRES_DB["host"]):
        return False, "PostgreSQL host is not loopback"
    try:
        conn = psycopg2.connect(**POSTGRES_DB)
        cur = conn.cursor()
        cur.execute("SELECT 1;")
        cur.fetchone()
        cur.close()
        conn.close()
        return True, "PostgreSQL reachable"
    except Exception as e:
        return False, f"PostgreSQL failed: {e}"

def check_http(name, url):
    enforce_dev()
    if _loopback_http_url(url) is None or not allowed_url(url, service="recovery"):
        return False, f"{name} URL is not loopback"
    try:
        response = requests.get(url, timeout=10, allow_redirects=False)
        if response.status_code < 500:
            return True, f"{name} reachable: HTTP {response.status_code}"
        return False, f"{name} unhealthy: HTTP {response.status_code}"
    except Exception as e:
        return False, f"{name} failed: {e}"

def _is_loopback_only(hostname):
    # Recovery stays stricter than the shared list: 127.0.0.1 and ::1 only.
    if hostname not in {"127.0.0.1", "::1"}:
        return False
    return _is_allowed_host(hostname, service="recovery")

def _loopback_http_url(url):
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        return None
    if not _is_loopback_only(parsed.hostname):
        return None
    return url

def check_ollama():
    enforce_dev()
    if _loopback_http_url(OLLAMA_URL) is None or not allowed_url(OLLAMA_URL, service="recovery"):
        return False, "Ollama URL is not loopback"
    try:
        response = requests.get(OLLAMA_URL, timeout=10, allow_redirects=False)
        if "Ollama is running" in response.text:
            return True, "Ollama reachable"
        return False, f"Ollama unexpected response: {response.text[:120]}"
    except Exception as e:
        return False, f"Ollama failed: {e}"

def check_voice():
    enforce_dev()
    if _loopback_http_url(VOICE_HEALTH_URL) is None or not allowed_url(VOICE_HEALTH_URL, service="recovery"):
        return False, "Voice URL is not loopback"
    try:
        response = requests.get(VOICE_HEALTH_URL, timeout=10, allow_redirects=False)
        data = response.json()
        if data.get("ok") is True:
            return True, f"Voice service healthy: {data.get('status')}"
        return False, f"Voice unhealthy: {data}"
    except Exception as e:
        return False, f"Voice service failed: {e}"

def check_containers():
    running = run_cmd(["docker", "ps", "--format", "{{.Names}}"]).splitlines()
    missing = [
        name for name in REQUIRED_CONTAINERS
        if name not in running
    ]

    if missing:
        return False, f"Missing containers: {', '.join(missing)}"

    return True, "All required containers running"

def check_systemd_service(service_name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9@._-]*", service_name):
        return False, f"{service_name} not active: command refused"
    result = run_cmd(["systemctl", "is-active", service_name])
    if result == "active":
        return True, f"{service_name} active"
    return False, f"{service_name} not active: {result}"

def main():
    enforce_dev()
    checks = [
        ("Redis", check_redis),
        ("PostgreSQL", check_postgres),
        ("Containers", check_containers),
        ("Dashboard", lambda: check_http("Dashboard", DASHBOARD_URL)),
        ("Ollama", check_ollama),
        ("Voice", check_voice),
        ("Home Assistant", lambda: check_http("Home Assistant", HOME_ASSISTANT_URL)),
        ("Dashboard Service", lambda: check_systemd_service("openclaw-dashboard")),
        ("Watchdog Timer", lambda: check_systemd_service("openclaw-watchdog.timer")),
        ("HomeManager Timer", lambda: check_systemd_service("openclaw-home-manager.timer")),
        ("Coordinator Timer", lambda: check_systemd_service("openclaw-coordinator.timer")),
        ("Remediation Timer", lambda: check_systemd_service("openclaw-remediation.timer")),
        ("AI Summary Timer", lambda: check_systemd_service("openclaw-ai-summary.timer")),
        ("Briefing Timer", lambda: check_systemd_service("openclaw-briefing.timer")),
    ]

    failures = []
    successes = []

    for name, check in checks:
        ok, message = check()
        if ok:
            successes.append(message)
        else:
            failures.append(message)

    if failures:
        summary = (
            "RECOVERY VALIDATION INCOMPLETE\n\n"
            "Failures:\n- "
            + "\n- ".join(failures)
            + "\n\nSuccessful checks:\n- "
            + "\n- ".join(successes)
        )

        publish("recovery_incomplete", summary)
    else:
        summary = (
            "FULL SYSTEM RECOVERY SUCCESSFUL\n\n"
            + "\n".join(f"- {item}" for item in successes)
        )

        publish("recovery_success", summary)

if __name__ == "__main__":
    main()

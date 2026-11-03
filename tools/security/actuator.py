"""DEV-only isolation actions. Pause and token revoke stay off unless explicitly enabled."""

from __future__ import annotations

import json
import os
import re
import socket
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import redis

_CONTAINER_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
_TENANT_ID = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")


def _development() -> bool:
    return os.environ.get("ENVIRONMENT") == "development"


def dry_run() -> bool:
    return os.environ.get("RANCH_SENTINEL_DRY_RUN", "0") == "1"


def _redis():
    probe = socket.socket()
    probe.settimeout(0.05)
    try:
        probe.connect(("127.0.0.1", 6379))
    except OSError as exc:
        raise ConnectionError("redis unavailable") from exc
    finally:
        probe.close()
    return redis.Redis(
        host="127.0.0.1",
        port=6379,
        decode_responses=True,
        socket_connect_timeout=0.05,
        socket_timeout=0.05,
    )


def incident_dir() -> Path:
    preferred = Path(os.environ.get("RANCH_INCIDENT_DIR", "/mnt/ai-storage/security/incidents"))
    # Do not create /mnt when that mount is absent. A missing mount must not stall isolation.
    if preferred.exists() or preferred.parent.exists():
        try:
            preferred.mkdir(parents=True, exist_ok=True)
            return preferred
        except OSError:
            pass
    fallback = Path(__file__).resolve().parents[2] / "redteam_logs" / "incidents"
    fallback.mkdir(parents=True, exist_ok=True)
    return fallback


def snapshot_incident(record: dict) -> Path:
    directory = incident_dir()
    stamp = int(datetime.now(timezone.utc).timestamp())
    digest = str(record.get("hash", "incident"))
    path = directory / f"{digest}.json"
    if path.exists():
        return path
    bundle = {
        "incident": record,
        "ts": datetime.now(timezone.utc).isoformat(),
        "dry_run": dry_run(),
        "docker_pause": False,
        "tokens_revoked": 0,
        "stamp": stamp,
        "recent_events": [],
    }
    path.write_text(json.dumps(bundle, indent=2, sort_keys=True))
    path.chmod(0o400)
    return path


def pause_container(name: str) -> bool:
    if dry_run() or os.environ.get("RANCH_ACTUATOR_PAUSE", "0") != "1" or not _development():
        return False
    if not _CONTAINER_NAME.fullmatch(name):
        return False
    completed = subprocess.run(
        ["docker", "pause", name],
        check=False,
        capture_output=True,
        text=True,
    )
    return completed.returncode == 0


def revoke_tokens(tenant_id: str) -> int:
    if dry_run() or os.environ.get("RANCH_ACTUATOR_REVOKE", "0") != "1" or not _development():
        return 0
    if not _TENANT_ID.fullmatch(tenant_id):
        return 0
    client = _redis()
    removed = 0
    prefix = f"openclaw:session:{tenant_id}:"
    for key in client.scan_iter(match=f"{prefix}*", count=100):
        removed += int(client.delete(key))
    return removed


def freeze_memory_writes() -> None:
    if dry_run() or not _development():
        return
    try:
        client = _redis()
        client.set("openclaw:security:freeze_memory", "1", ex=3600)
    except Exception:
        return

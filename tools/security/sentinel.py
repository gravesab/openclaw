"""DEV-only BreachSense sentinel. Bind 127.0.0.1:8001. Off unless this process is started."""

from __future__ import annotations

import hashlib
import json
import os
import socket
from datetime import datetime, timezone
from pathlib import Path
from time import perf_counter

import redis
from fastapi import FastAPI
from pydantic import BaseModel, Field

import tools.security.actuator as actuator

app = FastAPI()
CHAIN_FILE = Path(__file__).resolve().parents[2] / "redteam_logs" / "security_chain.jsonl"
RULES_FILE = Path(__file__).resolve().parent / "rules.yaml"


class SecurityEvent(BaseModel):
    type: str = Field(min_length=1, max_length=80)
    service: str = Field(default="unknown", max_length=80)
    score: float = 0.0
    payload: dict = Field(default_factory=dict)


def _load_rules() -> list[dict]:
    rules: list[dict] = []
    current: dict | None = None
    for raw_line in RULES_FILE.read_text().splitlines():
        line = raw_line.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if line.startswith("- "):
            if current:
                rules.append(current)
            current = {}
            key, value = line[2:].split(":", 1)
            current[key.strip()] = _coerce(value.strip())
            continue
        if current is None or ":" not in line:
            continue
        key, value = line.split(":", 1)
        current[key.strip()] = _coerce(value.strip())
    if current:
        rules.append(current)
    return rules


def _coerce(value: str):
    if value.isdigit():
        return int(value)
    try:
        return float(value)
    except ValueError:
        return value


def _hash_chain(previous: str, payload: dict) -> str:
    encoded = f"{previous}{json.dumps(payload, sort_keys=True)}".encode()
    return hashlib.sha256(encoded).hexdigest()


def _append_chain(event: dict) -> dict:
    CHAIN_FILE.parent.mkdir(parents=True, exist_ok=True)
    previous = "0" * 64
    if CHAIN_FILE.exists() and CHAIN_FILE.stat().st_size:
        last = CHAIN_FILE.read_text().splitlines()[-1]
        previous = json.loads(last).get("hash", previous)
    digest = _hash_chain(previous, event)
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "hash": digest,
        "prev": previous,
        **event,
    }
    with CHAIN_FILE.open("a") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")
    return record


def _rule_matches(rule: dict, event: SecurityEvent, client) -> bool:
    if rule.get("type") != event.type:
        return False
    if "score_gte" in rule and event.score < float(rule["score_gte"]):
        return False
    count = int(rule.get("count", 1))
    if count <= 1:
        return True
    window = int(rule.get("window_seconds", 60))
    key = f"openclaw:security:count:{event.service}:{event.type}"
    seen = int(client.incr(key))
    if seen == 1:
        client.expire(key, window)
    return seen >= count


def _redis_reachable() -> bool:
    probe = socket.socket()
    probe.settimeout(0.05)
    try:
        probe.connect(("127.0.0.1", 6379))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def _redis_client():
    if not _redis_reachable():
        raise ConnectionError("redis unavailable")
    return redis.Redis(
        host="127.0.0.1",
        port=6379,
        decode_responses=True,
        socket_connect_timeout=0.05,
        socket_timeout=0.05,
    )


def _isolate(record: dict, event: SecurityEvent) -> dict:
    snapshot = actuator.snapshot_incident(record)
    try:
        client = _redis_client()
        client.publish("openclaw:security", json.dumps(record, sort_keys=True))
        client.set(f"openclaw:security:quarantined:{event.service}", "1", ex=3600)
    except Exception:
        pass
    paused = False
    revoked = 0
    if not actuator.dry_run():
        actuator.freeze_memory_writes()
        container = str(event.payload.get("container", ""))
        if container:
            paused = actuator.pause_container(container)
        tenant = str(event.payload.get("tenant_id", ""))
        if tenant:
            revoked = actuator.revoke_tokens(tenant)
    return {"snapshot": snapshot, "docker_pause": paused, "tokens_revoked": revoked}


def _should_isolate(event: SecurityEvent) -> bool:
    try:
        client = _redis_client()
        matched = any(
            _rule_matches(rule, event, client) and rule.get("action") == "isolate"
            for rule in _load_rules()
        )
        return matched
    except Exception:
        return event.score >= 0.8 or event.type in {
            "router.egress_blocked",
            "mcp.dev_bypass_attempt",
            "prop.auth_disabled_prod",
            "chat.injection",
        }


@app.post("/sense")
def sense(event: SecurityEvent) -> dict:
    if os.environ.get("ENVIRONMENT") != "development":
        return {"status": "refused"}
    started = perf_counter()
    record = _append_chain(event.model_dump())
    if not _should_isolate(event):
        return {"status": "observed", "incident_id": record["hash"], "dry_run": actuator.dry_run()}
    try:
        isolated = _isolate(record, event)
    except Exception:
        isolated = {
            "snapshot": actuator.snapshot_incident(record),
            "docker_pause": False,
            "tokens_revoked": 0,
        }
    elapsed_ms = (perf_counter() - started) * 1000
    return {
        "status": "quarantined",
        "incident_id": record["hash"],
        "dry_run": actuator.dry_run(),
        "docker_pause": isolated["docker_pause"],
        "tokens_revoked": isolated["tokens_revoked"],
        "snapshot": str(isolated["snapshot"]),
        "elapsed_ms": round(elapsed_ms, 3),
    }


@app.get("/quarantine/{service}")
def quarantine(service: str) -> dict:
    if not service.replace("_", "").replace("-", "").isalnum():
        return {"quarantined": False}
    try:
        flagged = _redis_client().get(f"openclaw:security:quarantined:{service}") == "1"
    except Exception:
        flagged = False
    return {"quarantined": flagged}


@app.get("/status")
def status() -> dict:
    try:
        keys = list(_redis_client().scan_iter(match="openclaw:security:quarantined:*", count=100))
    except Exception:
        keys = []
    return {"quarantined": keys}


if __name__ == "__main__":
    if os.environ.get("ENVIRONMENT") != "development":
        raise SystemExit("sentinel refuses to start unless ENVIRONMENT=development")
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8001)

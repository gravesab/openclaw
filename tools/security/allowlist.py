"""Loopback-first host check. Private LAN requires an explicit opt-in."""

from __future__ import annotations

import hashlib
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen
import ipaddress

_RFC1918 = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)
_LOOPBACK_NAMES = {"127.0.0.1", "localhost", "::1"}
_CHAIN_FILE = Path(__file__).resolve().parents[2] / "redteam_logs" / "security_chain.jsonl"
_DEV_LAN = "192.168.50.117"


def _rfc1918(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    if not isinstance(ip, ipaddress.IPv4Address):
        return False
    return any(ip in network for network in _RFC1918)


def _explicit_hosts(env_name: str) -> set[str]:
    raw = os.environ.get(env_name, "")
    hosts: set[str] = set()
    for part in raw.split(","):
        token = part.strip().strip("[]")
        if not token or "*" in token or "/" in token:
            continue
        try:
            ip = ipaddress.ip_address(token)
        except ValueError:
            continue
        if ip.is_unspecified:
            continue
        hosts.add(token.lower())
    return hosts


def _note_private_lan(hostname: str, service: str, reason: str) -> None:
    print(
        f"[egress] private LAN host allowed for {service}: {hostname} via {reason}",
        file=sys.stderr,
    )
    event = {
        "type": "router.private_lan",
        "service": service,
        "score": 0.2,
        "payload": {"host": hostname, "reason": reason},
    }
    _append_chain(event)
    _notify_sentinel(event)


def _append_chain(event: dict) -> None:
    try:
        _CHAIN_FILE.parent.mkdir(parents=True, exist_ok=True)
        previous = "0" * 64
        if _CHAIN_FILE.exists() and _CHAIN_FILE.stat().st_size:
            previous = json.loads(_CHAIN_FILE.read_text().splitlines()[-1]).get("hash", previous)
        digest = hashlib.sha256(
            f"{previous}{json.dumps(event, sort_keys=True)}".encode()
        ).hexdigest()
        record = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "hash": digest,
            "prev": previous,
            **event,
        }
        with _CHAIN_FILE.open("a") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
    except OSError:
        return


def _notify_sentinel(event: dict) -> None:
    if os.environ.get("RANCH_SENTINEL_ENABLED", "0") != "1":
        return
    url = os.environ.get("RANCH_SENTINEL_URL", "http://127.0.0.1:8001/sense")
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or parsed.hostname not in _LOOPBACK_NAMES:
        return
    headers = {"Content-Type": "application/json"}
    token = os.environ.get("RANCH_SENTINEL_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    outgoing = Request(
        url,
        data=json.dumps(event).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urlopen(outgoing, timeout=0.5):
            return
    except (OSError, URLError, TimeoutError):
        return


def _is_loopback_only(host: str) -> bool:
    """True for the watchdog health names: 127.0.0.1, ::1, and localhost."""
    return (host or "").strip().lower() in {"127.0.0.1", "::1", "localhost"}


def _is_allowed_host(
    host: str,
    allow_private: bool = False,
    *,
    service: str = "allowlist",
    allowlist_env: str = "RANCH_HOST_ALLOWLIST",
) -> bool:
    """Allow loopback by default. Private hosts need an opt-in or an explicit list."""
    name = (host or "").strip().lower()
    if not name:
        return False
    try:
        ip = ipaddress.ip_address(name)
    except ValueError:
        ip = None
    if ip is not None and ip.is_unspecified:
        return False
    if name in _LOOPBACK_NAMES or (ip is not None and ip.is_loopback):
        return True
    if name in _explicit_hosts(allowlist_env):
        _note_private_lan(name, service, "explicit-allowlist")
        return True
    private_opt_in = allow_private or os.environ.get("RANCH_ALLOW_PRIVATE_LAN", "0") == "1"
    if private_opt_in and ip is not None and _rfc1918(ip):
        _note_private_lan(name, service, "RANCH_ALLOW_PRIVATE_LAN")
        return True
    development = os.environ.get("ENVIRONMENT", "").lower() == "development"
    if private_opt_in and development and (name == _DEV_LAN or name.endswith(".local")):
        _note_private_lan(name, service, "development-lan")
        return True
    return False

"""Return 503 when PropertyManager is quarantined. Off unless RANCH_SENTINEL_ENABLED=1."""

from __future__ import annotations

import os

import redis
from flask import jsonify


def quarantine_response(service: str):
    if os.environ.get("RANCH_SENTINEL_ENABLED", "0") != "1":
        return None
    try:
        client = redis.Redis(
            host="127.0.0.1",
            port=6379,
            decode_responses=True,
            socket_connect_timeout=0.05,
            socket_timeout=0.05,
        )
        if client.get(f"openclaw:security:quarantined:{service}") == "1":
            return jsonify({"error": "quarantined"}), 503
    except Exception:
        return None
    return None

"""Authentication seam for PropertyManager API (dev stub + API key)."""

from __future__ import annotations

import hmac
import json
import logging
import os
import secrets
from functools import wraps
from typing import Callable
from urllib.error import URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from flask import g, request

from errors import error_response

logger = logging.getLogger("propertymanager.auth")

API_KEY = os.environ.get("PROPERTYMANAGER_API_KEY", "").strip()
REVIEW_API_KEY = os.environ.get("PROPERTYMANAGER_REVIEW_API_KEY", "").strip()
_AUTH_DISABLED_REQUESTED = os.environ.get("PROPERTYMANAGER_AUTH_DISABLED", "").strip().lower() in {
    "1",
    "true",
    "yes",
}


def _notify_sentinel(event: dict) -> None:
    if os.environ.get("RANCH_SENTINEL_ENABLED", "0") != "1":
        return
    url = os.environ.get("RANCH_SENTINEL_URL", "http://127.0.0.1:8001/sense")
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        return
    payload = json.dumps(event).encode("utf-8")
    outgoing = Request(url, data=payload, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urlopen(outgoing, timeout=0.5):
            return
    except (OSError, URLError, TimeoutError):
        return


if _AUTH_DISABLED_REQUESTED and os.environ.get("ENVIRONMENT") != "development":
    _notify_sentinel({
        "type": "prop.auth_disabled_prod",
        "service": "propertymanager",
        "score": 1.0,
        "payload": {"environment": os.environ.get("ENVIRONMENT")},
    })
    raise RuntimeError(
        "PROPERTYMANAGER_AUTH_DISABLED is refused unless ENVIRONMENT=development"
    )

AUTH_DISABLED = _AUTH_DISABLED_REQUESTED


def _load_operator_pin() -> str:
    configured = os.environ.get("PROPERTYMANAGER_OPERATOR_PIN", "").strip()
    if configured:
        return configured
    if os.environ.get("ENVIRONMENT") == "development":
        logger.warning(
            "PROPERTYMANAGER_OPERATOR_PIN is unset; generated a temporary 16-character development PIN"
        )
        return secrets.token_hex(8)
    return ""


DEV_OPERATOR_PIN = _load_operator_pin()


def auth_required(*, allow_pin: bool = False) -> Callable:
    """Require API key or Bearer token for mutating endpoints."""

    def decorator(fn: Callable) -> Callable:
        @wraps(fn)
        def wrapper(*args, **kwargs):
            if AUTH_DISABLED:
                g.operator_identity = request.headers.get("X-Operator-Identity", "dev-anonymous")
                g.integration_identity = request.headers.get("X-Integration-Identity")
                return fn(*args, **kwargs)

            identity = _resolve_identity(allow_pin=allow_pin)
            if identity is None:
                return error_response(
                    "UNAUTHORIZED",
                    "Authentication required. Set Authorization: Bearer <api_key> or X-API-Key header.",
                    status=401,
                )
            g.operator_identity = identity.get("operator")
            g.integration_identity = identity.get("integration")
            return fn(*args, **kwargs)

        return wrapper

    return decorator


def review_required() -> Callable:
    """Require the human-review credential and bind its server-side identity."""

    def decorator(fn: Callable) -> Callable:
        @wraps(fn)
        def wrapper(*args, **kwargs):
            if AUTH_DISABLED:
                g.operator_identity = review_principal_identity()
                g.integration_identity = None
                return fn(*args, **kwargs)

            api_key = _request_api_key()
            if not REVIEW_API_KEY or (
                API_KEY and hmac.compare_digest(REVIEW_API_KEY, API_KEY)
            ):
                return error_response(
                    "REVIEW_AUTH_NOT_CONFIGURED",
                    "Human review authentication is not configured.",
                    status=503,
                )
            if not api_key or not hmac.compare_digest(api_key, REVIEW_API_KEY):
                return error_response(
                    "UNAUTHORIZED_REVIEW",
                    "Human review authentication required.",
                    status=401,
                )
            g.operator_identity = review_principal_identity()
            g.integration_identity = None
            return fn(*args, **kwargs)

        return wrapper

    return decorator


def _request_api_key() -> str:
    api_key = request.headers.get("X-API-Key") or ""
    auth_header = request.headers.get("Authorization") or ""
    if auth_header.lower().startswith("bearer "):
        api_key = auth_header[7:].strip()
    return api_key


def _resolve_identity(*, allow_pin: bool) -> dict[str, str | None] | None:
    api_key = _request_api_key()

    if API_KEY and api_key and hmac.compare_digest(api_key, API_KEY):
        return {
            "operator": request.headers.get("X-Operator-Identity", "api-key-operator"),
            "integration": request.headers.get("X-Integration-Identity"),
        }

    if allow_pin:
        pin = request.headers.get("X-Operator-PIN") or request.form.get("operator_pin") or ""
        if pin and DEV_OPERATOR_PIN and hmac.compare_digest(pin, DEV_OPERATOR_PIN):
            return {
                "operator": request.headers.get("X-Operator-Identity", "qr-operator"),
                "integration": "dashboard-qr",
            }
        if pin:
            _notify_sentinel({
                "type": "prop.pin_bruteforce",
                "service": "propertymanager",
                "score": 1.0,
                "payload": {},
            })

    return None


def auth_status() -> dict:
    return {
        "auth_required": not AUTH_DISABLED,
        "auth_mode": "disabled" if AUTH_DISABLED else "api_key",
        "pin_auth_supported": bool(DEV_OPERATOR_PIN),
        "review_auth_configured": bool(
            REVIEW_API_KEY
            and not (API_KEY and hmac.compare_digest(REVIEW_API_KEY, API_KEY))
        ),
    }


def server_submitter_identity() -> str:
    """Return the DEV submitter identity without trusting a caller header.

    This is deliberately separate from the legacy operator-display header used
    by existing task routes. Work-request provenance must be server-derived.
    """
    return os.environ.get("PROPERTYMANAGER_DEV_SUBMITTER_ID", "dev-api-submitters").strip() or "dev-api-submitters"


def review_principal_identity() -> str:
    """Identify review actions from server configuration, never a caller header."""
    return os.environ.get(
        "PROPERTYMANAGER_DEV_REVIEW_PRINCIPAL", "propertymanager-review-api-key"
    ).strip() or "propertymanager-review-api-key"

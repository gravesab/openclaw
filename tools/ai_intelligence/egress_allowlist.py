"""Compatibility wrapper. The host policy lives in tools.security.allowlist."""

from __future__ import annotations

from tools.security.allowlist import _is_allowed_host


def host_allowed(hostname: str, *, service: str, allowlist_env: str) -> bool:
    return _is_allowed_host(
        hostname,
        allow_private=False,
        service=service,
        allowlist_env=allowlist_env,
    )

"""Stack-environment isolation for AI provider endpoints.

DEV reaches DEV, PROD reaches PROD. Each stack keeps loopback, private
RFC1918, and .local egress, but the other stack's infrastructure hosts are
always blocked. Third-party cloud hosts (OpenRouter) are reachable from
either stack; privacy tiers still decide whether cloud may be used.
"""

from __future__ import annotations

import ipaddress
from enum import Enum
from os import environ
from urllib.parse import urlparse


class AIEnvironmentError(ValueError):
    """Raised when stack-environment endpoint policy is violated."""


class AIStackEnv(str, Enum):
    """Which stack this process serves."""

    DEVELOPMENT = "development"
    PRODUCTION = "production"


AI_INTELLIGENCE_ENVIRONMENT_ENV = "OPENCLAW_AI_INTELLIGENCE_ENVIRONMENT"

# Infrastructure hosts owned by the OTHER stack. Loopback stays shared
# because each box's loopback is its own; Tailscale IPs and mDNS names
# are stack-identifying and must never cross.
DEV_BLOCKED_HOSTS = frozenset(
    {
        "100.85.36.72",
        "intelmini",
        "intelmini.local",
    }
)
PROD_BLOCKED_HOSTS = frozenset(
    {
        "100.85.188.74",
    }
)

# Third-party cloud endpoints. Not stack infrastructure, so no cross-env
# link; reachable from either stack when privacy policy allows cloud.
CLOUD_HOSTS = frozenset(
    {
        "openrouter.ai",
    }
)

_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})

# Tailscale fleet range. CGNAT space is not RFC1918, and ipaddress does
# not count it as private, so it needs its own allowance.
_TAILSCALE_NETWORK = ipaddress.ip_network("100.64.0.0/10")


def stack_env_from_env() -> AIStackEnv:
    """Read the serving stack from the environment (default development)."""

    raw = environ.get(AI_INTELLIGENCE_ENVIRONMENT_ENV, "development")
    normalized = raw.strip().lower()
    if normalized in {"development", "dev"}:
        return AIStackEnv.DEVELOPMENT
    if normalized in {"production", "prod"}:
        return AIStackEnv.PRODUCTION
    raise AIEnvironmentError(
        f"Unknown {AI_INTELLIGENCE_ENVIRONMENT_ENV}: {raw!r} "
        "(expected development or production)"
    )


def blocked_hosts(env: AIStackEnv) -> frozenset[str]:
    """Return the infrastructure hosts the given stack must not reach."""

    if env is AIStackEnv.DEVELOPMENT:
        return DEV_BLOCKED_HOSTS
    if env is AIStackEnv.PRODUCTION:
        return PROD_BLOCKED_HOSTS
    raise AIEnvironmentError(f"Unsupported stack environment: {env}")


def is_host_allowed(hostname: str, env: AIStackEnv) -> bool:
    """Return whether the stack may reach a host (no scheme needed).

    Shared by URL endpoints and host:port stores (vector Postgres,
    tasks API) so one blocklist decides everywhere.
    """

    host = (hostname or "").lower()
    if not host:
        return False
    if host in blocked_hosts(env):
        return False
    if host in CLOUD_HOSTS:
        return True
    if host in _LOOPBACK_HOSTS:
        return True
    if host.endswith(".local"):
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return (
        ip.is_loopback or ip.is_private or ip in _TAILSCALE_NETWORK
    )


def is_endpoint_allowed(url: str, env: AIStackEnv) -> bool:
    """Return whether the stack may open an AI endpoint URL."""

    try:
        parsed = urlparse(url)
    except ValueError:
        return False
    if parsed.scheme == "file":
        # Handbook file paths: local disk only (empty or localhost
        # host) can never cross stacks; remote file hosts stay out.
        return (parsed.hostname or "").lower() in {"", "localhost"}
    if parsed.scheme not in {"http", "https"}:
        return False
    return is_host_allowed(parsed.hostname or "", env)


def assert_endpoint_allowed(url: str, env: AIStackEnv) -> None:
    """Raise AIEnvironmentError when the stack must not reach the URL."""

    if is_endpoint_allowed(url, env):
        return
    parsed = urlparse(url)
    hostname = (parsed.hostname or url).lower()
    if hostname in blocked_hosts(env):
        raise AIEnvironmentError(
            f"Cross-environment endpoint blocked for "
            f"{env.value} stack: {hostname}"
        )
    raise AIEnvironmentError(
        f"Endpoint not allowed for {env.value} stack: {hostname}"
    )

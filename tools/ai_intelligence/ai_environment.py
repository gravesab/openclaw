"""Stack-environment isolation for AI provider endpoints.

DEV reaches DEV, PROD reaches PROD. Each stack may use loopback, its own
pinned infrastructure host, and the pinned cloud hosts. Any other private
address needs RANCH_ALLOW_PRIVATE_LAN=1 or an explicit host list. The other
stack's infrastructure hosts stay blocked either way.
"""

from __future__ import annotations

from enum import Enum
from os import environ
from urllib.parse import urlparse

from tools.security.allowlist import _is_allowed_host


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

# Each stack's own server, pinned by exact Tailscale IP. No CGNAT range
# and no mDNS names: only these hosts pass without an opt-in.
DEV_OWN_HOSTS = frozenset({"100.85.188.74"})
PROD_OWN_HOSTS = frozenset({"100.85.36.72"})

# Third-party cloud endpoints. Not stack infrastructure, so either stack
# may reach them; privacy tiers still decide whether cloud may be used.
CLOUD_HOSTS = frozenset({"openrouter.ai"})

_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


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


def own_hosts(env: AIStackEnv) -> frozenset[str]:
    """Return the pinned infrastructure hosts the given stack owns."""

    if env is AIStackEnv.DEVELOPMENT:
        return DEV_OWN_HOSTS
    if env is AIStackEnv.PRODUCTION:
        return PROD_OWN_HOSTS
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
    if host in _LOOPBACK_HOSTS:
        return True
    if host in own_hosts(env) or host in CLOUD_HOSTS:
        return True
    return _is_allowed_host(
        host,
        service="ai_environment",
        allowlist_env="RANCH_HOST_ALLOWLIST",
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

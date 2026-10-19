"""In-memory RanchBrain API sessions (P3.1, single-process DEV).

A fresh Google ID token is exchanged once for an opaque ``rbs_`` bearer.
Data requests present that bearer and do not re-check the five-minute
Google freshness rule. The token is tenant-bound and lives only in memory.
"""

from __future__ import annotations

import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from threading import Lock
from typing import Callable, Protocol

from ..tenancy import VerifiedPrincipal


SESSION_PREFIX = "rbs_"
SESSION_TTL = timedelta(hours=8)


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


@dataclass(frozen=True)
class ApiSession:
    token: str
    tenant_id: str
    principal: VerifiedPrincipal
    expires_at: datetime


class SessionStore(Protocol):
    def issue(self, *, principal: VerifiedPrincipal, tenant_id: str) -> ApiSession: ...

    def get(self, token: str) -> ApiSession | None: ...


class MemorySessionStore:
    """Process-local sessions. One DEV process is the whole deployment."""

    def __init__(self, *, clock: Callable[[], datetime] | None = None, ttl: timedelta = SESSION_TTL) -> None:
        self._clock = clock or _utcnow
        self._ttl = ttl
        self._lock = Lock()
        self._sessions: dict[str, ApiSession] = {}

    def issue(self, *, principal: VerifiedPrincipal, tenant_id: str) -> ApiSession:
        now = self._clock()
        expires_at = now + self._ttl
        # The Google token's own expiry is shorter than the session. Data
        # calls authorize this window, not a fresh Google login.
        session_principal = VerifiedPrincipal(
            id=principal.id,
            principal_type=principal.principal_type,
            environment=principal.environment,
            lifecycle_state="active",
            assurance_profile=principal.assurance_profile,
            session_reference=principal.session_reference,
            valid_from=now if now < expires_at else principal.valid_from,
            valid_until=expires_at,
            correlation_id=principal.correlation_id,
        )
        token = SESSION_PREFIX + secrets.token_urlsafe(32)
        session = ApiSession(
            token=token,
            tenant_id=tenant_id,
            principal=session_principal,
            expires_at=expires_at,
        )
        with self._lock:
            self._purge_locked(now)
            self._sessions[token] = session
        return session

    def get(self, token: str) -> ApiSession | None:
        now = self._clock()
        with self._lock:
            self._purge_locked(now)
            session = self._sessions.get(token)
            if session is None or session.expires_at <= now:
                self._sessions.pop(token, None)
                return None
            return session

    def _purge_locked(self, now: datetime) -> None:
        expired = [token for token, session in self._sessions.items() if session.expires_at <= now]
        for token in expired:
            del self._sessions[token]

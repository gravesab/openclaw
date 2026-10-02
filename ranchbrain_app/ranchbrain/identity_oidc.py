"""Google OIDC bootstrap identity adapter (DEV).

Verifies a Google ID token and emits the shared ``VerifiedPrincipal``
contract. Claim validation is implemented here; cryptographic signature
verification is injected through ``TokenSignatureVerifier``. The adapter
refuses to verify when no signature verifier is configured, so there is no
silent unsigned path. A JOSE-backed verifier plugs in once a crypto
dependency is approved — signature verification is never hand-rolled here.

Only ``sub``, ``iss``, ``aud``, ``exp``, ``iat``, ``amr``, and ``auth_time``
are read. Email, display name, and other presentation attributes are ignored
and must never establish authority.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Callable, Mapping, Protocol

from .tenancy import TenancyError, VerifiedPrincipal


GOOGLE_OIDC_ISSUER = "https://accounts.google.com"

_DEFAULT_AUTH_FRESHNESS = timedelta(minutes=5)
_DEFAULT_CLOCK_SKEW_LEEWAY = timedelta(seconds=60)


class TokenSignatureVerifier(Protocol):
    """Verifies a compact JWS assertion and returns its payload claims."""

    def verify_and_decode(self, assertion: str) -> Mapping[str, object]: ...


@dataclass(frozen=True)
class OidcConfiguration:
    """DEV bootstrap enrollment settings. Values come from DEV configuration."""

    audience: str
    environment: str
    issuer: str = GOOGLE_OIDC_ISSUER
    max_auth_age: timedelta = _DEFAULT_AUTH_FRESHNESS
    clock_skew_leeway: timedelta = _DEFAULT_CLOCK_SKEW_LEEWAY

    def __post_init__(self) -> None:
        if not isinstance(self.audience, str) or not self.audience.strip():
            raise TenancyError("OIDC configuration requires a non-empty audience")
        if not isinstance(self.environment, str) or not self.environment.strip():
            raise TenancyError("OIDC configuration requires a non-empty environment")
        if not isinstance(self.issuer, str) or not self.issuer.strip():
            raise TenancyError("OIDC configuration requires a non-empty issuer")


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _require_int_claim(claims: Mapping[str, object], name: str) -> int:
    value = claims.get(name)
    if isinstance(value, bool) or not isinstance(value, int):
        raise TenancyError(f"OIDC claim {name!r} must be an integer timestamp")
    return value


class GoogleOidcIdentityAdapter:
    """DEV bootstrap adapter implementing the ``VerifiedPrincipal`` contract."""

    def __init__(
        self,
        config: OidcConfiguration,
        signature_verifier: TokenSignatureVerifier | None = None,
        clock: Callable[[], datetime] = _utcnow,
    ) -> None:
        self._config = config
        self._signature_verifier = signature_verifier
        self._clock = clock

    def verify(self, assertion: str, *, now: datetime | None = None) -> VerifiedPrincipal:
        if not isinstance(assertion, str) or not assertion.strip():
            raise TenancyError("OIDC assertion must be a non-empty token")
        if self._signature_verifier is None:
            raise TenancyError("OIDC signature verifier is not configured")

        current_time = now if now is not None else self._clock()
        if current_time.tzinfo is None or current_time.utcoffset() is None:
            raise TenancyError("OIDC verification time must be timezone-aware")

        try:
            claims = self._signature_verifier.verify_and_decode(assertion)
        except TenancyError:
            raise
        except Exception as error:
            raise TenancyError("OIDC signature verification failed") from error
        if not isinstance(claims, Mapping):
            raise TenancyError("OIDC verified claims must be a mapping")

        return self._principal_from_claims(claims, current_time)

    def _principal_from_claims(self, claims: Mapping[str, object], now: datetime) -> VerifiedPrincipal:
        config = self._config
        leeway = config.clock_skew_leeway

        issuer = claims.get("iss")
        if issuer != config.issuer:
            raise TenancyError("OIDC issuer is not trusted")
        if claims.get("aud") != config.audience:
            raise TenancyError("OIDC audience does not match this deployment")

        subject = claims.get("sub")
        if not isinstance(subject, str) or not subject.strip():
            raise TenancyError("OIDC subject must be a non-empty immutable id")

        issued_at = _require_int_claim(claims, "iat")
        expires_at = _require_int_claim(claims, "exp")
        valid_from = datetime.fromtimestamp(issued_at, timezone.utc)
        valid_until = datetime.fromtimestamp(expires_at, timezone.utc)
        if issued_at > (now + leeway).timestamp():
            raise TenancyError("OIDC token was issued in the future")
        if now >= valid_until + leeway:
            raise TenancyError("OIDC token is expired")

        assurance = claims.get("amr")
        if not isinstance(assurance, list) or "mfa" not in assurance:
            raise TenancyError("OIDC enrollment requires multi-factor assurance")

        auth_time = _require_int_claim(claims, "auth_time")
        authenticated_at = datetime.fromtimestamp(auth_time, timezone.utc)
        if authenticated_at > now + leeway:
            raise TenancyError("OIDC authentication time is in the future")
        if now - authenticated_at > config.max_auth_age:
            raise TenancyError("OIDC authentication is stale")

        return VerifiedPrincipal(
            id=f"google-oidc:{subject}",
            principal_type="human",
            environment=config.environment,
            lifecycle_state="active",
            assurance_profile="mfa-fresh",
            session_reference=f"login:{subject}:{auth_time}",
            valid_from=valid_from,
            valid_until=valid_until,
            correlation_id=f"oidc:{issued_at}:{subject}",
        )

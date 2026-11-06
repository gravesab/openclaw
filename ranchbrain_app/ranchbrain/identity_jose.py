"""JOSE-backed ``TokenSignatureVerifier`` for Google ID tokens (DEV).

Signature verification only. Claim policy (iss, aud, exp, iat, amr,
auth_time) stays in ``identity_oidc.GoogleOidcIdentityAdapter`` so there is
one owner of it and it uses the adapter's injected clock.

Backed by PyJWT (``PyJWT[crypto]``). Keys come from Google's published JWKS
(``jwks_uri`` in https://accounts.google.com/.well-known/openid-configuration).
Rotation: PyJWKClient caches the key set and, on an unknown ``kid``, forces
one refetch subject to a cooldown, so a newly rotated key is picked up
without a restart and a flood of bogus ``kid`` values cannot hammer Google.
"""

from __future__ import annotations

from typing import Mapping, Protocol

import jwt
from jwt import PyJWK, PyJWKClient

from .tenancy import TenancyError

GOOGLE_JWKS_URI = "https://www.googleapis.com/oauth2/v3/certs"
# Google's discovery document lists RS256 as the only ID-token algorithm.
# Hard-coded on purpose: never derive allowed algorithms from the token.
GOOGLE_ID_TOKEN_ALGORITHMS = ("RS256",)

_JWKS_CACHE_SECONDS = 3600
_JWKS_TIMEOUT_SECONDS = 5.0
_UNKNOWN_KID_COOLDOWN_SECONDS = 30.0
_MAX_TOKEN_CHARS = 8192

# Signature only; the adapter validates every claim with its own clock.
_SIGNATURE_ONLY = {
    "verify_signature": True,
    "verify_exp": False,
    "verify_nbf": False,
    "verify_iat": False,
    "verify_aud": False,
    "verify_iss": False,
    "verify_sub": False,
    "verify_jti": False,
    "enforce_minimum_key_length": True,
}


class SigningKeyProvider(Protocol):
    def get_signing_key(self, kid: str) -> PyJWK: ...


def google_jwks_client(uri: str = GOOGLE_JWKS_URI) -> PyJWKClient:
    if not uri.startswith("https://"):
        raise TenancyError("JWKS URI must use https")
    return PyJWKClient(
        uri,
        cache_jwk_set=True,
        lifespan=_JWKS_CACHE_SECONDS,
        timeout=_JWKS_TIMEOUT_SECONDS,
        cooldown_duration=_UNKNOWN_KID_COOLDOWN_SECONDS,
    )


class JoseSignatureVerifier:
    """Verifies a compact JWS against a JWKS and returns its payload."""

    def __init__(
        self,
        keys: SigningKeyProvider,
        algorithms: tuple[str, ...] = GOOGLE_ID_TOKEN_ALGORITHMS,
    ) -> None:
        if not algorithms or any(a.lower() == "none" or a.startswith("HS") for a in algorithms):
            raise TenancyError("only asymmetric JWS algorithms are allowed")
        self._keys = keys
        self._algorithms = list(algorithms)

    def verify_and_decode(self, assertion: str) -> Mapping[str, object]:
        if not isinstance(assertion, str) or len(assertion) > _MAX_TOKEN_CHARS:
            raise TenancyError("OIDC assertion is malformed")
        try:
            header = jwt.get_unverified_header(assertion)
        except jwt.PyJWTError as error:
            raise TenancyError("OIDC assertion is malformed") from error
        # Reject before any key fetch so junk tokens never reach the network.
        if header.get("alg") not in self._algorithms:
            raise TenancyError("OIDC assertion algorithm is not allowed")
        kid = header.get("kid")
        if not isinstance(kid, str) or not kid:
            raise TenancyError("OIDC assertion has no key id")
        try:
            key = self._keys.get_signing_key(kid)
            claims = jwt.decode(assertion, key, algorithms=self._algorithms, options=_SIGNATURE_ONLY)
        except jwt.PyJWTError as error:
            raise TenancyError("OIDC signature verification failed") from error
        if not isinstance(claims, dict):
            raise TenancyError("OIDC verified claims must be a mapping")
        return claims

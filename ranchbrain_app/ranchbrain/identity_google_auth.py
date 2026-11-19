"""JOSE verification for Google ID tokens via the approved google-auth pin.

The library checks signature, expiry, and audience. Policy checks (MFA,
auth_time freshness, issuer pinning) stay in GoogleOidcIdentityAdapter.
`verify_and_decode` does not fetch anything. Process start may load Google's
published certificates once and pass them in.
"""

from __future__ import annotations

import json
from typing import Mapping
from urllib.request import urlopen

GOOGLE_CERTS_URL = "https://www.googleapis.com/oauth2/v1/certs"


def fetch_google_certs(url: str = GOOGLE_CERTS_URL) -> dict[str, str]:
    """Load Google's published certificate map. Public keys only."""

    with urlopen(url, timeout=10) as response:
        payload = json.load(response)
    if not isinstance(payload, dict) or not payload:
        raise RuntimeError("Google certificate payload was empty")
    if not all(isinstance(key, str) and isinstance(value, str) for key, value in payload.items()):
        raise RuntimeError("Google certificate payload was not a kid-to-PEM map")
    return payload


def require_google_auth():
    """Return google.auth.jwt, or raise if the approved library is absent."""

    try:
        from google.auth import jwt as google_jwt
    except ImportError as error:
        raise RuntimeError(
            "google-auth is not installed; refusing to verify OIDC signatures"
        ) from error
    return google_jwt


class GoogleAuthTokenVerifier:
    """TokenSignatureVerifier backed by google-auth and caller-supplied certs."""

    def __init__(self, *, certs: Mapping[str, str | bytes] | str | bytes, audience: str) -> None:
        if not audience or not str(audience).strip():
            raise RuntimeError("Google OIDC audience is required")
        self._certs = certs
        self._audience = audience
        self._jwt = require_google_auth()

    def verify_and_decode(self, assertion: str) -> Mapping[str, object]:
        claims = self._jwt.decode(assertion, certs=self._certs, verify=True, audience=self._audience)
        if not isinstance(claims, Mapping):
            raise RuntimeError("google-auth returned non-mapping claims")
        return claims

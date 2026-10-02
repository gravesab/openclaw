from datetime import datetime, timedelta, timezone

import pytest

from ranchbrain.identity_oidc import (
    GOOGLE_OIDC_ISSUER,
    GoogleOidcIdentityAdapter,
    OidcConfiguration,
)
from ranchbrain.tenancy import TenancyError, VerifiedPrincipal


NOW = datetime(2026, 8, 27, 14, tzinfo=timezone.utc)


def claims(**overrides):
    values = {
        "iss": GOOGLE_OIDC_ISSUER,
        "aud": "dev-client-id",
        "sub": "google-sub-123",
        "iat": int((NOW - timedelta(minutes=1)).timestamp()),
        "exp": int((NOW + timedelta(minutes=9)).timestamp()),
        "amr": ["pwd", "mfa"],
        "auth_time": int((NOW - timedelta(minutes=1)).timestamp()),
        "email": "andrew@example.com",
        "name": "Andrew",
    }
    values.update(overrides)
    return values


class StubVerifier:
    def __init__(self, result=None, error=None):
        self._result = result
        self._error = error
        self.seen = []

    def verify_and_decode(self, assertion):
        self.seen.append(assertion)
        if self._error is not None:
            raise self._error
        return self._result


def adapter(verifier, **config_overrides):
    values = {"audience": "dev-client-id", "environment": "development"}
    values.update(config_overrides)
    return GoogleOidcIdentityAdapter(OidcConfiguration(**values), verifier)


def test_valid_token_emits_verified_principal_from_sub_only():
    principal = adapter(StubVerifier(claims())).verify("token", now=NOW)

    assert isinstance(principal, VerifiedPrincipal)
    assert principal.id == "google-oidc:google-sub-123"
    assert principal.environment == "development"
    assert principal.assurance_profile == "mfa-fresh"
    assert principal.lifecycle_state == "active"
    assert principal.is_active_at(NOW)
    assert "andrew@example.com" not in repr(principal)
    assert "Andrew" not in principal.id


def test_refuses_to_verify_without_signature_verifier():
    bare = GoogleOidcIdentityAdapter(OidcConfiguration(audience="dev-client-id", environment="development"))

    with pytest.raises(TenancyError, match="signature verifier is not configured"):
        bare.verify("token", now=NOW)


def test_rejects_empty_assertion_before_touching_verifier():
    verifier = StubVerifier(claims())

    with pytest.raises(TenancyError, match="non-empty token"):
        adapter(verifier).verify("   ", now=NOW)
    assert verifier.seen == []


def test_wraps_unexpected_verifier_failure_without_leaking():
    verifier = StubVerifier(error=ValueError("boom"))

    with pytest.raises(TenancyError, match="signature verification failed"):
        adapter(verifier).verify("token", now=NOW)


def test_rejects_non_mapping_claims():
    with pytest.raises(TenancyError, match="must be a mapping"):
        adapter(StubVerifier(["not", "a", "mapping"])).verify("token", now=NOW)


@pytest.mark.parametrize(
    "override",
    [
        {"iss": "https://evil.example.com"},
        {"iss": "accounts.google.com"},
        {"aud": "other-client-id"},
        {"aud": ["dev-client-id"]},
        {"sub": ""},
        {"sub": None},
        {"exp": int((NOW - timedelta(minutes=5)).timestamp())},
        {"iat": int((NOW + timedelta(hours=1)).timestamp())},
        {"exp": "not-an-int"},
        {"iat": True},
        {"amr": ["pwd"]},
        {"amr": "mfa"},
        {"amr": None},
        {"auth_time": int((NOW - timedelta(minutes=30)).timestamp())},
        {"auth_time": int((NOW + timedelta(hours=1)).timestamp())},
        {"auth_time": None},
        {"auth_time": True},
    ],
)
def test_denies_untrusted_or_stale_claims(override):
    with pytest.raises(TenancyError):
        adapter(StubVerifier(claims(**override))).verify("token", now=NOW)


def test_rejects_empty_audience_or_environment_in_config():
    with pytest.raises(TenancyError, match="non-empty audience"):
        OidcConfiguration(audience="  ", environment="development")
    with pytest.raises(TenancyError, match="non-empty environment"):
        OidcConfiguration(audience="dev-client-id", environment="")


def test_rejects_naive_verification_time():
    with pytest.raises(TenancyError, match="timezone-aware"):
        adapter(StubVerifier(claims())).verify("token", now=datetime(2026, 8, 27, 14))

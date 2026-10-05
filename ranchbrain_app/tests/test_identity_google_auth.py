"""google-auth verifier against a local certificate. No network."""

from datetime import datetime, timedelta, timezone

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from google.auth.crypt import RSASigner

from ranchbrain.identity_google_auth import GoogleAuthTokenVerifier, require_google_auth
from ranchbrain.identity_oidc import GOOGLE_OIDC_ISSUER, GoogleOidcIdentityAdapter, OidcConfiguration
from ranchbrain.tenancy import TenancyError


AUD = "ranchbrain-dev"


def _material():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    now = datetime.now(timezone.utc)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "ranchbrain-test")])
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=1))
        .not_valid_after(now + timedelta(days=1))
        .sign(key, hashes.SHA256())
    )
    private_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    cert_pem = cert.public_bytes(serialization.Encoding.PEM)
    return private_pem, cert_pem


def _token(private_pem: bytes, *, kid: str = "test-key", **overrides):
    now = datetime.now(timezone.utc)
    payload = {
        "iss": GOOGLE_OIDC_ISSUER,
        "aud": AUD,
        "sub": "subject-1",
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=5)).timestamp()),
        "amr": ["pwd", "mfa"],
        "auth_time": int(now.timestamp()),
    }
    payload.update(overrides)
    signer = RSASigner.from_string(private_pem, key_id=kid)
    jwt = require_google_auth()
    encoded = jwt.encode(signer, payload)
    return encoded.decode("ascii") if isinstance(encoded, bytes) else encoded


def test_local_cert_verifies_and_adapter_keeps_mfa_policy():
    private_pem, cert_pem = _material()
    verifier = GoogleAuthTokenVerifier(certs={"test-key": cert_pem}, audience=AUD)
    adapter = GoogleOidcIdentityAdapter(
        OidcConfiguration(audience=AUD, environment="dev"),
        verifier,
    )
    principal = adapter.verify(_token(private_pem))
    assert principal.id == "google-oidc:subject-1"
    assert principal.assurance_profile == "mfa-fresh"

    with pytest.raises(TenancyError, match="multi-factor"):
        adapter.verify(_token(private_pem, amr=["pwd"]))


def test_bad_signature_is_rejected():
    private_pem, cert_pem = _material()
    other_pem, _ = _material()
    verifier = GoogleAuthTokenVerifier(certs={"test-key": cert_pem}, audience=AUD)
    with pytest.raises(Exception):
        verifier.verify_and_decode(_token(other_pem))


def test_require_google_auth_imports_the_library():
    module = require_google_auth()
    assert hasattr(module, "decode")


def test_main_refuses_to_serve(monkeypatch):
    import ranchbrain.api.server as server_mod
    import ranchbrain.identity_google_auth as google_auth_mod

    monkeypatch.delenv("RANCHBRAIN_OIDC_AUDIENCE", raising=False)
    assert server_mod.main() == 2

    def missing():
        raise RuntimeError("google-auth is not installed")

    monkeypatch.setenv("RANCHBRAIN_OIDC_AUDIENCE", "dev-client-id")
    monkeypatch.setattr(google_auth_mod, "require_google_auth", missing)
    assert server_mod.main() == 2

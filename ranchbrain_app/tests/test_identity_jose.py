"""JOSE signature verifier: real RSA keys, real PyJWKClient, stubbed fetch only."""

import base64
import json
from datetime import datetime, timedelta, timezone

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from ranchbrain.identity_jose import JoseSignatureVerifier, google_jwks_client
from ranchbrain.identity_oidc import GoogleOidcIdentityAdapter, OidcConfiguration
from ranchbrain.tenancy import TenancyError

NOW = datetime(2026, 11, 6, 15, 0, tzinfo=timezone.utc)


def rsa_key(bits=2048):
    return rsa.generate_private_key(public_exponent=65537, key_size=bits)


KEY_A, KEY_B, OTHER = rsa_key(), rsa_key(), rsa_key()


def jwk(private, kid):
    data = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(private.public_key()))
    return {**data, "kid": kid, "use": "sig", "alg": "RS256"}


def claims(**overrides):
    values = {
        "iss": "https://accounts.google.com", "aud": "dev-client-id", "sub": "1234567890",
        "iat": int(NOW.timestamp()) - 30, "exp": int(NOW.timestamp()) + 3600,
        "amr": ["pwd", "mfa"], "auth_time": int(NOW.timestamp()) - 60,
    }
    values.update(overrides)
    return values


def sign(private, kid, payload=None, alg="RS256"):
    return jwt.encode(payload or claims(), private, algorithm=alg, headers={"kid": kid})


class Keys:
    """A real PyJWKClient whose network fetch is replaced per instance."""

    def __init__(self, *key_sets):
        self.sets = list(key_sets)
        self.fetches = 0
        self.client = google_jwks_client()
        self.client.fetch_data = self._fetch

    def _fetch(self):
        self.fetches += 1
        index = min(self.fetches, len(self.sets)) - 1
        return {"keys": self.sets[index]}


def verifier(keys):
    return JoseSignatureVerifier(keys.client)


def b64(data):
    return base64.urlsafe_b64encode(json.dumps(data).encode()).rstrip(b"=").decode()


def test_valid_signature_returns_claims():
    keys = Keys([jwk(KEY_A, "a")])
    assert verifier(keys).verify_and_decode(sign(KEY_A, "a"))["sub"] == "1234567890"


def test_tampered_payload_is_rejected():
    head, _, sig = sign(KEY_A, "a").split(".")
    forged = f"{head}.{b64(claims(sub='attacker'))}.{sig}"
    with pytest.raises(TenancyError, match="signature verification failed"):
        verifier(Keys([jwk(KEY_A, "a")])).verify_and_decode(forged)


def test_wrong_key_with_known_kid_is_rejected():
    with pytest.raises(TenancyError, match="signature verification failed"):
        verifier(Keys([jwk(KEY_A, "a")])).verify_and_decode(sign(OTHER, "a"))


def test_unknown_kid_is_rejected():
    with pytest.raises(TenancyError, match="signature verification failed"):
        verifier(Keys([jwk(KEY_A, "a")])).verify_and_decode(sign(OTHER, "zzz"))


def test_rotated_key_is_picked_up_with_one_refetch():
    keys = Keys([jwk(KEY_A, "a")], [jwk(KEY_A, "a"), jwk(KEY_B, "b")])
    v = verifier(keys)
    v.verify_and_decode(sign(KEY_A, "a"))
    assert keys.fetches == 1
    assert v.verify_and_decode(sign(KEY_B, "b"))["sub"] == "1234567890"
    assert keys.fetches == 2
    v.verify_and_decode(sign(KEY_B, "b"))
    assert keys.fetches == 2  # cached


def test_unknown_kid_flood_respects_refetch_cooldown():
    keys = Keys([jwk(KEY_A, "a")])
    v = verifier(keys)
    v.verify_and_decode(sign(KEY_A, "a"))
    for kid in ("x1", "x2", "x3"):
        with pytest.raises(TenancyError):
            v.verify_and_decode(sign(OTHER, kid))
    assert keys.fetches <= 2


def test_alg_none_is_rejected_before_any_fetch():
    keys = Keys([jwk(KEY_A, "a")])
    token = f"{b64({'alg': 'none', 'kid': 'a'})}.{b64(claims())}."
    with pytest.raises(TenancyError, match="algorithm is not allowed"):
        verifier(keys).verify_and_decode(token)
    assert keys.fetches == 0


def test_hs256_algorithm_confusion_is_rejected_before_any_fetch():
    keys = Keys([jwk(KEY_A, "a")])
    public_pem = KEY_A.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    header = b64({"alg": "HS256", "kid": "a", "typ": "JWT"})
    payload = b64(claims())
    import hmac, hashlib
    sig = base64.urlsafe_b64encode(
        hmac.new(public_pem, f"{header}.{payload}".encode(), hashlib.sha256).digest()
    ).rstrip(b"=").decode()
    with pytest.raises(TenancyError, match="algorithm is not allowed"):
        verifier(keys).verify_and_decode(f"{header}.{payload}.{sig}")
    assert keys.fetches == 0


@pytest.mark.parametrize("token", ["", "not-a-jwt", "a.b", "x" * 9000])
def test_malformed_tokens_are_rejected_before_any_fetch(token):
    keys = Keys([jwk(KEY_A, "a")])
    with pytest.raises(TenancyError):
        verifier(keys).verify_and_decode(token)
    assert keys.fetches == 0


def test_missing_kid_is_rejected():
    token = jwt.encode(claims(), KEY_A, algorithm="RS256")
    with pytest.raises(TenancyError, match="no key id"):
        verifier(Keys([jwk(KEY_A, "a")])).verify_and_decode(token)


def test_short_rsa_key_is_rejected():
    weak = rsa_key(1024)
    with pytest.raises(TenancyError):
        verifier(Keys([jwk(weak, "w")])).verify_and_decode(sign(weak, "w"))


@pytest.mark.parametrize("algorithms", [(), ("none",), ("HS256",), ("RS256", "HS256")])
def test_constructor_refuses_symmetric_or_none(algorithms):
    with pytest.raises(TenancyError):
        JoseSignatureVerifier(Keys([]).client, algorithms=algorithms)


def test_jwks_uri_must_be_https():
    with pytest.raises(TenancyError):
        google_jwks_client("http://www.googleapis.com/oauth2/v3/certs")


def test_end_to_end_with_oidc_adapter():
    adapter = GoogleOidcIdentityAdapter(
        OidcConfiguration(audience="dev-client-id", environment="development"),
        verifier(Keys([jwk(KEY_A, "a")])),
    )
    principal = adapter.verify(sign(KEY_A, "a"), now=NOW)
    assert principal.id == "google-oidc:1234567890"
    with pytest.raises(TenancyError):
        adapter.verify(sign(KEY_A, "a", claims(aud="someone-else")), now=NOW)
    with pytest.raises(TenancyError):
        adapter.verify(sign(OTHER, "a"), now=NOW)

"""P3 server entry point: fail-closed config, loopback/tailnet bind only."""

import json
import socket

import pytest

from ranchbrain.api import server
from ranchbrain.tenancy import TenancyError


class FakeVerifier:
    def verify_and_decode(self, assertion):
        raise TenancyError("not used")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture
def membership_file(tmp_path):
    path = tmp_path / "memberships.json"
    path.write_text(json.dumps({
        "users": [{"id": "u1", "principal_id": "google-oidc:123"}],
        "tenants": [{"id": "t1"}],
        "memberships": [{"tenant_id": "t1", "user_id": "u1", "role": "owner"}],
    }))
    return str(path)


def env(membership_file, **extra):
    return {"RANCHBRAIN_OIDC_AUDIENCE": "dev-client-id", "RANCHBRAIN_MEMBERSHIP_FILE": membership_file, **extra}


def test_defaults_are_loopback_5063_development(membership_file):
    config = server.config_from_env(env(membership_file), verifier=FakeVerifier())
    assert (config.host, config.port, config.oidc.environment) == ("127.0.0.1", 5063, "development")
    assert config.oidc.audience == "dev-client-id"


@pytest.mark.parametrize("missing", ["RANCHBRAIN_OIDC_AUDIENCE", "RANCHBRAIN_MEMBERSHIP_FILE"])
def test_missing_required_config_refuses(membership_file, missing):
    values = env(membership_file)
    values[missing] = " "
    with pytest.raises(TenancyError):
        server.config_from_env(values, verifier=FakeVerifier())


@pytest.mark.parametrize("host", ["100.85.188.74", "127.0.0.1", "::1"])
def test_loopback_and_tailnet_hosts_are_allowed(membership_file, host):
    assert server.config_from_env(env(membership_file, RANCHBRAIN_API_HOST=host), verifier=FakeVerifier()).host == host


@pytest.mark.parametrize("host", ["0.0.0.0", "::", "192.168.50.10", "172.17.0.1", "100.128.0.1", "localhost", "example.com"])
def test_wildcard_lan_and_names_are_refused(membership_file, host):
    with pytest.raises(TenancyError, match="bind host"):
        server.config_from_env(env(membership_file, RANCHBRAIN_API_HOST=host), verifier=FakeVerifier())


@pytest.mark.parametrize("port", ["80", "0", "70000", "abc"])
def test_bad_ports_are_refused(membership_file, port):
    with pytest.raises(TenancyError):
        server.config_from_env(env(membership_file, RANCHBRAIN_API_PORT=port), verifier=FakeVerifier())


def test_malformed_membership_file_refuses(tmp_path):
    bad = tmp_path / "m.json"
    bad.write_text("{not json")
    with pytest.raises(TenancyError, match="membership file"):
        server.config_from_env(env(str(bad)), verifier=FakeVerifier())


def test_main_exits_2_without_config(capsys):
    assert server.main({}, verifier_factory=FakeVerifier) == 2
    assert "refusing to start" in capsys.readouterr().err


def test_main_serves_on_loopback_and_closes(membership_file):
    port = free_port()
    seen = []

    def serve(srv):
        seen.append(srv.server_address)

    assert server.main(env(membership_file, RANCHBRAIN_API_PORT=str(port)), verifier_factory=FakeVerifier, serve=serve) == 0
    assert seen == [("127.0.0.1", port)]
    with socket.socket() as s:  # socket released after server_close()
        s.bind(("127.0.0.1", port))


def test_default_verifier_is_jose_backed(monkeypatch):
    from ranchbrain import identity_jose

    built = []
    monkeypatch.setattr(identity_jose, "google_jwks_client", lambda: built.append("jwks") or object())
    assert server.main({}) == 2  # config missing, but the verifier was built without any network call
    assert built == ["jwks"]

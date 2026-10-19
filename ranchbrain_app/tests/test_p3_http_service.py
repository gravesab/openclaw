"""P3 HTTP service acceptance (12 cases, stdlib live-server fixture).

Storage is redirected to tmp_path by the autouse fixture in conftest.py.
Every case runs a real ThreadingHTTPServer on an ephemeral loopback port
with urllib as the client — no new dependencies. Membership and OIDC are
faked at the seams the service injects (MembershipStore, TokenSignatureVerifier).
"""

import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

import ranchbrain.api.server as server_mod
import ranchbrain.memory_store as memory_store_mod
from ranchbrain.api.membership import MembershipStoreError, StaticMembershipStore
from ranchbrain.api.sessions import SESSION_PREFIX, MemorySessionStore, SESSION_TTL
from ranchbrain.api.server import ServiceConfig, create_server
from ranchbrain.identity_oidc import GOOGLE_OIDC_ISSUER, OidcConfiguration
from ranchbrain.memory_store import list_memories, remember, save_memory
from ranchbrain.models import Memory
from ranchbrain.profile_manager import PROFILES, IndexProfile
from ranchbrain.tenancy import Capability, ROLE_CAPABILITIES, Role, Tenant, TenantMembership, User

A = "tenant-a"
B = "tenant-b"
C = "tenant-c"
SUB = "sub123"
PRINCIPAL = f"google-oidc:{SUB}"
AUD = "test-audience"


class FakeVerifier:
    """Mint Google-shaped claims per token name. Unknown tokens fail closed."""

    def verify_and_decode(self, assertion):
        now = datetime.now(timezone.utc)
        base = {
            "iss": GOOGLE_OIDC_ISSUER,
            "aud": AUD,
            "sub": SUB,
            "iat": int((now - timedelta(seconds=60)).timestamp()),
            "exp": int((now + timedelta(hours=1)).timestamp()),
            "amr": ["pwd", "mfa"],
            "auth_time": int((now - timedelta(seconds=60)).timestamp()),
        }
        variants = {
            "tok-good": {},
            "tok-expired": {"exp": int((now - timedelta(hours=1)).timestamp())},
            "tok-no-mfa": {"amr": ["pwd"]},
            "tok-wrong-aud": {"aud": "other-audience"},
            "tok-future-iat": {"iat": int((now + timedelta(hours=1)).timestamp())},
            "tok-stale": {"auth_time": int((now - timedelta(minutes=10)).timestamp())},
        }
        if assertion not in variants:
            raise Exception("bad signature")
        return {**base, **variants[assertion]}


class FailingStore:
    def snapshot(self):
        raise MembershipStoreError("simulated outage")


def membership_facts():
    users = [User(id="u1", principal_id=PRINCIPAL)]
    tenants = [
        Tenant(id=A, slug="a", display_name="Tenant A"),
        Tenant(id=B, slug="b", display_name="Tenant B"),
        Tenant(id=C, slug="c", display_name="Tenant C"),
    ]
    memberships = [
        TenantMembership(tenant_id=A, user_id="u1", role=Role.OWNER),
        TenantMembership(tenant_id=B, user_id="u1", role=Role.VIEWER),
    ]
    return users, tenants, memberships


def seed(title, body, tenant_id=A, module="property", category="maintenance"):
    return remember(module=module, category=category, title=title, body=body,
                    tenant_id=tenant_id)


class LiveServer:
    def __init__(self, config, time_fn=None):
        self._server = create_server(config, time_fn=time_fn)
        self._thread = threading.Thread(target=self._server.serve_forever,
                                        kwargs={"poll_interval": 0.05}, daemon=True)

    def __enter__(self):
        self._thread.start()
        host, port = self._server.server_address
        self.base = f"http://{host}:{port}"
        return self

    def __exit__(self, *exc):
        self._server.shutdown()
        self._thread.join(timeout=5)
        self._server.server_close()

    def get(self, path, token="tok-good", tenant=A, headers=None):
        heads = dict(headers or {})
        if token is not None:
            heads["Authorization"] = f"Bearer {token}"
        if tenant is not None:
            heads["X-Ranch-Tenant"] = tenant
        req = urllib.request.Request(self.base + path, headers=heads, method="GET")
        return self._open(req)

    def post(self, path, token="tok-good", tenant=A, headers=None):
        heads = dict(headers or {})
        if token is not None:
            heads["Authorization"] = f"Bearer {token}"
        if tenant is not None:
            heads["X-Ranch-Tenant"] = tenant
        req = urllib.request.Request(self.base + path, data=b"", headers=heads, method="POST")
        return self._open(req)

    def _open(self, req):
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return resp.status, _hdict(resp.headers), resp.read()
        except urllib.error.HTTPError as error:
            return error.code, _hdict(error.headers), error.read()


def _hdict(headers):
    return {k.lower(): v for k, v in headers.items()}


def _json(raw):
    return json.loads(raw.decode("utf-8"))


def _config(store=None, sessions=None, **limits):
    users, tenants, memberships = membership_facts()
    return ServiceConfig(
        oidc=OidcConfiguration(audience=AUD, environment="dev"),
        verifier=FakeVerifier(),
        memberships=store or StaticMembershipStore(
            users=tuple(users), tenants=tuple(tenants), memberships=tuple(memberships)),
        sessions=sessions,
        host="127.0.0.1", port=0, **limits)


def _search_path(profile, question):
    return f"/v1/search/{profile}/{urllib.parse.quote(question, safe='')}"


@pytest.fixture(autouse=True)
def _tmp_knowledge_profile(tmp_path, monkeypatch):
    """Redirect the knowledge profile roots at this test's tmp data tree.

    conftest patches the storage roots but PROFILES is built at import with
    the live tree; without this the indexer scans the wrong root (0 files).
    Same setitem pattern as seeded_profile in test_tenant_isolation.py.
    """
    base = PROFILES["knowledge"]
    monkeypatch.setitem(
        PROFILES, "knowledge",
        IndexProfile(
            name="knowledge",
            roots=(tmp_path / "ranchbrain-data",),
            include_top=set(base.include_top),
            exclude_top=set(base.exclude_top),
            exclude_any=set(base.exclude_any),
        ),
    )


# -- 12 acceptance cases ------------------------------------------------


def test_01_oidc_failures_rejected_401():
    with LiveServer(_config()) as svc:
        status, heads, raw = svc.get("/v1/memory/list", token=None)
        assert status == 401
        assert _json(raw)["code"] == "oidc_missing"
        assert "www-authenticate" in heads
        for token in ("tok-bogus", "tok-expired", "tok-no-mfa",
                      "tok-wrong-aud", "tok-future-iat"):
            status, _, raw = svc.get("/v1/memory/list", token=token)
            assert status == 401, token
            assert _json(raw)["code"] == "oidc_invalid", token


def test_02_missing_tenant_header_400():
    with LiveServer(_config()) as svc:
        for tenant in (None, "", "   "):
            status, _, raw = svc.get("/v1/memory/list", tenant=tenant)
            assert status == 400, repr(tenant)
            assert _json(raw)["code"] == "tenant_context_invalid"


def test_03_no_membership_403():
    with LiveServer(_config()) as svc:
        # tenant-c exists but u1 has no membership row there.
        status, _, raw = svc.get("/v1/memory/list", tenant=C)
        assert status == 403
        assert _json(raw)["code"] == "tenant_not_authorized"
        # Unknown tenant is the same verdict (never 500, never allow).
        status, _, raw = svc.get("/v1/memory/list", tenant="tenant-zzz")
        assert status == 403
        assert _json(raw)["code"] == "tenant_not_authorized"


def test_04_cross_tenant_fetch_matches_missing_404():
    made = seed("North pump seal weep", "Pump R-3 shows a seal weep at flange.")
    with LiveServer(_config()) as svc:
        cross_status, _, cross_raw = svc.get(f"/v1/memory/fetch/{made.memory_id}", tenant=B)
        miss_status, _, miss_raw = svc.get("/v1/memory/fetch/missing-id-xyz", tenant=A)
        assert cross_status == miss_status == 404
        cross, miss = _json(cross_raw), _json(miss_raw)
        assert cross["code"] == miss["code"] == "memory_not_found"
        assert cross["message"] == miss["message"]
        assert set(cross) == set(miss) == {"code", "message", "request_id"}


def test_05_tenant_isolation_across_endpoints():
    seed("North pump seal weep", "Pump R-3 shows a seal weep at flange.", tenant_id=A)
    seed("South valve calibration", "Valve V-9 calibration drifted high.", tenant_id=B)
    with LiveServer(_config()) as svc:
        _, _, raw = svc.get("/v1/memory/list", tenant=A)
        listed = _json(raw)
        assert listed["tenant_id"] == A
        assert [m["title"] for m in listed["memories"]] == ["North pump seal weep"]
        _, _, raw = svc.get("/v1/memory/list", tenant=B)
        assert [m["title"] for m in _json(raw)["memories"]] == ["South valve calibration"]

        _, _, raw = svc.get(_search_path("knowledge", "pump"), tenant=A)
        found = _json(raw)
        assert found["total"] > 0 and found["hits"], found
        _, _, raw = svc.get(_search_path("knowledge", "pump"), tenant=B)
        assert _json(raw)["total"] == 0 and _json(raw)["hits"] == []
        _, _, raw = svc.get(_search_path("knowledge", "valve"), tenant=B)
        assert _json(raw)["total"] > 0
        _, _, raw = svc.get(_search_path("knowledge", "valve"), tenant=A)
        assert _json(raw)["total"] == 0


def test_06_rate_limit_headers_present():
    seed("North pump seal weep", "Pump R-3 shows a seal weep at flange.")
    with LiveServer(_config()) as svc:
        status, heads, _ = svc.get("/v1/memory/list", tenant=A)
        assert status == 200
        assert heads["ratelimit-limit"] == "120"
        assert heads["ratelimit-remaining"] == "119"
        assert int(heads["ratelimit-reset"]) >= 1
        assert "x-ratelimit-limit" not in heads
        assert heads["x-ranch-tenant"] == A
        assert heads["x-request-id"]
        status, heads, _ = svc.get(_search_path("knowledge", "pump"), tenant=A)
        assert status == 200
        assert heads["ratelimit-limit"] == "60"
        status, heads, _ = svc.get("/v1/memory/fetch/missing-id-xyz", tenant=A)
        assert status == 404
        assert heads["ratelimit-limit"] == "120"
        assert heads["x-ranch-tenant"] == A


def test_07_quota_exceeded_429_with_retry_after():
    clock = [1000.0]
    config = _config(search_per_minute=3, memory_per_minute=100)
    with LiveServer(config, time_fn=lambda: clock[0]) as svc:
        path = _search_path("knowledge", "pump")
        for _ in range(3):
            status, _, _ = svc.get(path, tenant=A)
            assert status == 200
        status, heads, raw = svc.get(path, tenant=A)
        assert status == 429
        assert _json(raw)["code"] == "rate_limited"
        assert heads["ratelimit-remaining"] == "0"
        assert int(heads["retry-after"]) >= 1
        clock[0] += 61.0
        status, _, _ = svc.get(path, tenant=A)
        assert status == 200


def test_08_no_path_leak(tmp_path):
    made = seed("North pump seal weep", "Pump R-3 shows a seal weep at flange.")
    with LiveServer(_config()) as svc:
        bodies = []
        for path in ("/v1/memory/list",
                     f"/v1/memory/fetch/{made.memory_id}",
                     _search_path("knowledge", "pump")):
            status, _, raw = svc.get(path, tenant=A)
            assert status == 200, path
            bodies.append(raw.decode("utf-8"))
        for body in bodies:
            assert str(tmp_path) not in body
            assert "ranchbrain-data" not in body
        hits = json.loads(bodies[2])["hits"]
        assert hits and all("/" not in hit["source"] for hit in hits)


def test_09_validation_rejects_bad_input():
    with LiveServer(_config()) as svc:
        cases = [
            ("/v1/memory/list?module=../..", 400, "invalid_module"),
            ("/v1/memory/list?module=Has%20Space", 400, "invalid_module"),
            ("/v1/memory/list?limit=abc", 400, "invalid_limit"),
            ("/v1/memory/list?limit=0", 400, "invalid_limit"),
            (_search_path("nope", "pump"), 400, "invalid_profile"),
            (_search_path("knowledge", "x" * 501), 400, "question_too_long"),
            (_search_path("knowledge", "   "), 400, "invalid_question"),
            ("/v1/memory/fetch/", 400, "invalid_id"),
            ("/v1/nope", 404, "not_found"),
        ]
        for path, status_want, code_want in cases:
            status, _, raw = svc.get(path, tenant=A)
            assert status == status_want, path
            assert _json(raw)["code"] == code_want, path
            assert "Traceback" not in raw.decode("utf-8")
        status, _, _ = svc.get("/v1/memory/list?limit=10000", tenant=A)
        assert status == 200  # over-limit clamps, it does not reject


def test_10_fetch_id_semantics():
    for ident, title in (("pfx-aaa-1", "Alpha paddock note"),
                         ("pfx-aab-2", "Beta paddock note"),
                         ("dup-1", "Exact short id"),
                         ("dup-10", "Longer id sharing the prefix")):
        save_memory(Memory(module="property", category="maintenance", title=title,
                           body=f"Body for {title}.", tenant_id=A,
                           memory_type="event", tags=[], id=ident))
    exact = seed("North pump seal weep", "Pump R-3 shows a seal weep at flange.")
    with LiveServer(_config()) as svc:
        status, _, raw = svc.get(f"/v1/memory/fetch/{exact.memory_id}", tenant=A)
        assert status == 200
        assert _json(raw)["id"] == exact.memory_id
        status, _, raw = svc.get("/v1/memory/fetch/pfx-aaa", tenant=A)
        assert status == 200
        assert _json(raw)["id"] == "pfx-aaa-1"
        # Exact id wins even though "dup-10" also starts with "dup-1".
        status, _, raw = svc.get("/v1/memory/fetch/dup-1", tenant=A)
        assert status == 200
        assert _json(raw)["id"] == "dup-1"
        status, _, raw = svc.get("/v1/memory/fetch/zzz-nope", tenant=A)
        assert status == 404
        status, _, raw = svc.get("/v1/memory/fetch/pfx-", tenant=A)
        assert status == 409
        assert _json(raw)["code"] == "memory_id_ambiguous"


def test_11_json_schema_goldens():
    made = seed("North pump seal weep", "Pump R-3 shows a seal weep at flange.")
    with LiveServer(_config()) as svc:
        _, _, raw = svc.get("/v1/memory/list", tenant=A)
        listed = _json(raw)
        assert set(listed) == {"tenant_id", "count", "memories"}
        assert set(listed["memories"][0]) == {
            "id", "module", "category", "title", "memory_type",
            "tags", "created_at", "updated_at"}

        _, _, raw = svc.get(f"/v1/memory/fetch/{made.memory_id}", tenant=A)
        detail = _json(raw)
        assert set(detail) == {
            "id", "module", "category", "title", "memory_type", "tags",
            "created_at", "updated_at", "body", "references",
            "source_type", "tenant_id"}

        _, _, raw = svc.get(_search_path("knowledge", "pump"), tenant=A)
        found = _json(raw)
        assert set(found) == {"tenant_id", "profile", "total", "hits"}
        assert set(found["hits"][0]) == {
            "source", "line", "text", "modified_at", "indexed_at"}


def test_12_membership_store_down_503():
    config = _config(store=FailingStore())
    with LiveServer(config) as svc:
        status, heads, raw = svc.get("/v1/memory/list", tenant=A)
        assert status == 503
        assert _json(raw)["code"] == "store_unavailable"
        assert int(heads["retry-after"]) >= 1


# -- review regressions -------------------------------------------------


def test_rate_limit_reset_rounds_up():
    clock = [1000.2]  # 19.8s left in the [960, 1020) window
    with LiveServer(_config(memory_per_minute=1), time_fn=lambda: clock[0]) as svc:
        _, heads, _ = svc.get("/v1/memory/list", tenant=A)
        assert heads["ratelimit-reset"] == "20"
        status, heads, _ = svc.get("/v1/memory/list", tenant=A)
        assert status == 429
        assert heads["retry-after"] == "20"


def test_search_overrun_returns_503_within_budget(monkeypatch):
    release = threading.Event()

    def slow_search(*_args):
        release.wait(timeout=5)
        return [], 0

    monkeypatch.setattr(server_mod, "index_search", slow_search)
    monkeypatch.setattr(server_mod, "SEARCH_BUDGET_SECONDS", 0.2)
    try:
        with LiveServer(_config()) as svc:
            started = time.monotonic()
            status, heads, raw = svc.get(_search_path("knowledge", "pump"), tenant=A)
            elapsed = time.monotonic() - started
            assert status == 503
            assert _json(raw)["code"] == "index_unavailable"
            assert heads["retry-after"] == "5"
            assert elapsed < 2.0
    finally:
        release.set()


class Clock:
    def __init__(self):
        self.now = datetime.now(timezone.utc)

    def __call__(self):
        return self.now


def test_session_issue_use_expire_and_cross_tenant():
    made = seed("Session pump", "A labeled pump note.")
    clock = Clock()
    sessions = MemorySessionStore(clock=clock)
    with LiveServer(_config(sessions=sessions)) as svc:
        status, _, raw = svc.post("/v1/session", token="tok-stale", tenant=A)
        assert status == 401
        assert _json(raw)["code"] == "oidc_invalid"

        status, _, raw = svc.post("/v1/session", tenant=C)
        assert status == 403
        assert _json(raw)["code"] == "tenant_not_authorized"

        status, _, raw = svc.post("/v1/session", tenant=A)
        assert status == 200
        body = _json(raw)
        assert body["token"].startswith(SESSION_PREFIX)
        assert body["tenant_id"] == A
        assert body["expires_at"]

        status, _, raw = svc.get("/v1/memory/list", token=body["token"], tenant=A)
        assert status == 200
        assert _json(raw)["count"] == 1

        missing_status, _, missing_raw = svc.get(f"/v1/memory/fetch/{made.memory_id}-nope", tenant=A)
        cross_status, _, cross_raw = svc.get("/v1/memory/list", token=body["token"], tenant=B)
        assert cross_status == 404
        assert cross_status == missing_status
        assert _json(cross_raw)["code"] == _json(missing_raw)["code"] == "memory_not_found"
        assert _json(cross_raw)["message"] == _json(missing_raw)["message"]

        status, _, raw = svc.get("/v1/memory/list", token=SESSION_PREFIX + "unknown", tenant=A)
        assert status == 401
        assert _json(raw)["code"] == "session_invalid"

        clock.now += SESSION_TTL + timedelta(seconds=1)
        status, _, raw = svc.get("/v1/memory/list", token=body["token"], tenant=A)
        assert status == 401
        assert _json(raw)["code"] == "session_invalid"


# -- session route: ranch comes from membership ----------------------------


class RecordingSessionStore:
    """SessionStore that records issue() calls, delegating storage.

    The recording only observes how often the route under test issues; it
    never drives the route, so a zero count proves no session was issued.
    """

    def __init__(self, delegate=None):
        self._delegate = delegate or MemorySessionStore()
        self.issues = []

    def issue(self, *, principal, tenant_id):
        self.issues.append(tenant_id)
        return self._delegate.issue(principal=principal, tenant_id=tenant_id)

    def get(self, token):
        return self._delegate.get(token)


class DivergentSessionStore:
    """SessionStore that reports a different ranch than it was asked to issue.

    Records the resolved tenant_id the route passed to issue(), then
    returns a session object bound to another ranch, proving the route
    checks the return instead of trusting it.
    """

    def __init__(self, *, reported_tenant_id="tenant-zzz"):
        self._reported = reported_tenant_id
        self.issues = []

    def issue(self, *, principal, tenant_id):
        self.issues.append(tenant_id)
        return SimpleNamespace(
            token=SESSION_PREFIX + "divergent",
            tenant_id=self._reported,
            expires_at=datetime.now(timezone.utc) + SESSION_TTL,
        )

    def get(self, token):
        return None


class _PrincipalListStore:
    """Postgres-shaped store: principal listing works, snapshot is forbidden."""

    def __init__(self, users, tenants, memberships):
        self._users = users
        self._tenants = tenants
        self._memberships = memberships

    def snapshot(self):
        raise AssertionError("session route must not snapshot a principal-list store")

    def memberships_for_principal(self, *, issuer, subject, principal_id):
        assert issuer == GOOGLE_OIDC_ISSUER
        assert subject == SUB
        assert principal_id == PRINCIPAL
        return list(self._users), list(self._tenants), list(self._memberships)


def _tenancy_store(users, tenants, memberships, *, via_principal_list):
    if via_principal_list:
        return _PrincipalListStore(users, tenants, memberships)
    return StaticMembershipStore(users=tuple(users), tenants=tuple(tenants),
                                 memberships=tuple(memberships))


def _suspended_ranch_facts():
    users = [User(id="u1", principal_id=PRINCIPAL)]
    tenants = [Tenant(id=A, slug="a", display_name="Tenant A"),
               Tenant(id=B, slug="b", display_name="Tenant B", status="suspended")]
    memberships = [TenantMembership(tenant_id=A, user_id="u1", role=Role.OWNER),
                   TenantMembership(tenant_id=B, user_id="u1", role=Role.VIEWER)]
    return users, tenants, memberships


def _single_ranch_config(sessions=None, **limits):
    users = [User(id="u1", principal_id=PRINCIPAL)]
    tenants = [Tenant(id=A, slug="a", display_name="Tenant A")]
    memberships = [TenantMembership(tenant_id=A, user_id="u1", role=Role.OWNER)]
    return _config(
        store=StaticMembershipStore(users=tuple(users), tenants=tuple(tenants),
                                    memberships=tuple(memberships)),
        sessions=sessions, **limits)


@pytest.mark.parametrize("tenant", [None, "", "   ", A])
def test_session_single_ranch_hint_optional(tenant):
    sessions = RecordingSessionStore()
    with LiveServer(_single_ranch_config(sessions=sessions)) as svc:
        status, heads, raw = svc.post("/v1/session", tenant=tenant)
        assert status == 200, repr(tenant)
        body = _json(raw)
        assert set(body) == {"token", "expires_at", "tenant_id"}
        assert body["tenant_id"] == A
        assert body["token"].startswith(SESSION_PREFIX)
        assert body["expires_at"]
        assert heads["x-ranch-tenant"] == A
        assert sessions.issues == [A]


def test_session_hint_outside_membership_403_without_issue():
    sessions = RecordingSessionStore()
    with LiveServer(_config(sessions=sessions)) as svc:
        # tenant-c exists but u1 is no member; tenant-zzz exists nowhere.
        for tenant in (C, "tenant-zzz"):
            status, _, raw = svc.post("/v1/session", tenant=tenant)
            assert status == 403, tenant
            assert _json(raw)["code"] == "tenant_not_authorized", tenant
        assert sessions.issues == []


@pytest.mark.parametrize("tenant", [None, "", "   "])
def test_session_two_ranches_require_choice(tenant):
    sessions = RecordingSessionStore()
    with LiveServer(_config(sessions=sessions)) as svc:
        status, _, raw = svc.post("/v1/session", tenant=tenant)
        assert status == 400, repr(tenant)
        assert _json(raw)["code"] == "tenant_context_invalid", repr(tenant)
        assert sessions.issues == []


@pytest.mark.parametrize(("tenant", "want"), [(A, A), (B, B), ("  " + B + "  ", B)])
def test_session_two_ranches_hint_chooses(tenant, want):
    sessions = RecordingSessionStore()
    with LiveServer(_config(sessions=sessions)) as svc:
        status, heads, raw = svc.post("/v1/session", tenant=tenant)
        assert status == 200, repr(tenant)
        assert _json(raw)["tenant_id"] == want
        assert heads["x-ranch-tenant"] == want
        assert sessions.issues == [want]


@pytest.mark.parametrize("membership_status", ["suspended", "revoked"])
def test_session_inactive_membership_403_without_issue(membership_status):
    users = [User(id="u1", principal_id=PRINCIPAL)]
    tenants = [Tenant(id=A, slug="a", display_name="Tenant A")]
    memberships = [TenantMembership(tenant_id=A, user_id="u1", role=Role.OWNER,
                                    status=membership_status)]
    sessions = RecordingSessionStore()
    config = _config(store=StaticMembershipStore(users=tuple(users), tenants=tuple(tenants),
                                                 memberships=tuple(memberships)),
                     sessions=sessions)
    with LiveServer(config) as svc:
        status, _, raw = svc.post("/v1/session", tenant=None)
        assert status == 403
        assert _json(raw)["code"] == "tenant_not_authorized"
        assert sessions.issues == []


def test_session_hint_at_suspended_membership_403_without_issue():
    users = [User(id="u1", principal_id=PRINCIPAL)]
    tenants = [Tenant(id=A, slug="a", display_name="Tenant A"),
               Tenant(id=B, slug="b", display_name="Tenant B")]
    memberships = [TenantMembership(tenant_id=A, user_id="u1", role=Role.OWNER,
                                    status="suspended"),
                   TenantMembership(tenant_id=B, user_id="u1", role=Role.VIEWER)]
    sessions = RecordingSessionStore()
    config = _config(store=StaticMembershipStore(users=tuple(users), tenants=tuple(tenants),
                                                 memberships=tuple(memberships)),
                     sessions=sessions)
    with LiveServer(config) as svc:
        status, _, raw = svc.post("/v1/session", tenant=A)
        assert status == 403
        assert _json(raw)["code"] == "tenant_not_authorized"
        assert sessions.issues == []
        status, _, raw = svc.post("/v1/session", tenant=B)
        assert status == 200
        assert _json(raw)["tenant_id"] == B
        assert sessions.issues == [B]


def test_session_rate_limit_charged_to_resolved_ranch():
    sessions = RecordingSessionStore()
    with LiveServer(_single_ranch_config(sessions=sessions, memory_per_minute=1)) as svc:
        status, heads, _ = svc.post("/v1/session", tenant=None)
        assert status == 200
        assert heads["ratelimit-remaining"] == "0"
        # The headerless issue charged ranch A's quota, not an empty-hint bucket.
        status, _, _ = svc.get("/v1/memory/list", tenant=A)
        assert status == 429


def test_session_rate_limit_follows_hint_choice():
    with LiveServer(_config(memory_per_minute=1)) as svc:
        status, _, _ = svc.post("/v1/session", tenant=B)
        assert status == 200
        status, _, _ = svc.get("/v1/memory/list", tenant=A)
        assert status == 200
        status, _, _ = svc.get("/v1/memory/list", tenant=B)
        assert status == 429


def test_session_denied_hint_charges_no_quota():
    with LiveServer(_config(memory_per_minute=1)) as svc:
        status, _, _ = svc.post("/v1/session", tenant=C)
        assert status == 403
        status, _, _ = svc.get("/v1/memory/list", tenant=A)
        assert status == 200


def test_session_role_without_memory_read_issues_nothing(monkeypatch):
    # No shipped role lacks memory.read; narrow the viewer to simulate a
    # future least-privilege role and prove the route gates issuance on it.
    narrowed = frozenset(set(ROLE_CAPABILITIES[Role.VIEWER]) - {Capability.MEMORY_READ})
    assert Capability.MEMORY_READ not in narrowed
    monkeypatch.setitem(ROLE_CAPABILITIES, Role.VIEWER, narrowed)
    sessions = RecordingSessionStore()
    with LiveServer(_config(sessions=sessions)) as svc:
        status, _, raw = svc.post("/v1/session", tenant=B)
        assert status == 403
        assert _json(raw)["code"] == "tenant_capability_forbidden"
        assert sessions.issues == []


def test_session_principal_list_store_never_snapshots():
    users = [User(id="u1", principal_id=PRINCIPAL)]
    tenants = [Tenant(id=A, slug="a", display_name="Tenant A")]
    memberships = [TenantMembership(tenant_id=A, user_id="u1", role=Role.OWNER)]
    sessions = RecordingSessionStore()
    config = _config(store=_PrincipalListStore(users, tenants, memberships), sessions=sessions)
    with LiveServer(config) as svc:
        status, heads, raw = svc.post("/v1/session", tenant=None)
        assert status == 200
        assert _json(raw)["tenant_id"] == A
        assert heads["x-ranch-tenant"] == A
        assert sessions.issues == [A]


def test_session_membership_store_down_503():
    with LiveServer(_config(store=FailingStore())) as svc:
        status, heads, raw = svc.post("/v1/session", tenant=None)
        assert status == 503
        assert _json(raw)["code"] == "store_unavailable"
        assert int(heads["retry-after"]) >= 1


def test_session_store_ranch_mismatch_is_403_without_store_ranch():
    sessions = DivergentSessionStore()
    with LiveServer(_single_ranch_config(sessions=sessions)) as svc:
        status, heads, raw = svc.post("/v1/session", tenant=None)
        assert status == 403
        body = _json(raw)
        assert body["code"] == "tenant_not_authorized"
        assert sessions.issues == [A]
        assert "tenant_id" not in body
        assert "tenant-zzz" not in raw.decode("utf-8")
        assert heads.get("x-ranch-tenant") != "tenant-zzz"


# -- GET routes: a session token carries its ranch -------------------------


def _issue_token(svc, tenant):
    status, _, raw = svc.post("/v1/session", tenant=tenant)
    assert status == 200
    return _json(raw)["token"]


@pytest.mark.parametrize("tenant", [None, "   "])
def test_session_token_lists_memory_without_header(tenant):
    seed("Barn note", "A labeled barn note.", tenant_id=B)
    with LiveServer(_config()) as svc:
        token = _issue_token(svc, B)
        status, heads, raw = svc.get("/v1/memory/list", token=token, tenant=tenant)
        assert status == 200, repr(tenant)
        assert _json(raw)["count"] == 1
        assert heads["x-ranch-tenant"] == B


def test_session_token_with_own_header_succeeds():
    seed("Barn note", "A labeled barn note.", tenant_id=B)
    with LiveServer(_config()) as svc:
        token = _issue_token(svc, B)
        status, heads, raw = svc.get("/v1/memory/list", token=token, tenant=B)
        assert status == 200
        assert _json(raw)["count"] == 1
        assert heads["x-ranch-tenant"] == B


def test_session_token_with_other_ranch_header_is_404():
    seed("Barn note", "A labeled barn note.", tenant_id=B)
    seed("Pump note", "A labeled pump note.", tenant_id=A)
    with LiveServer(_config()) as svc:
        token = _issue_token(svc, B)
        status, _, raw = svc.get("/v1/memory/list", token=token, tenant=A)
        assert status == 404
        body = _json(raw)
        assert body["code"] == "memory_not_found"
        assert "memories" not in body and "count" not in body


def test_session_token_get_charges_session_ranch_quota():
    with LiveServer(_config(memory_per_minute=2)) as svc:
        token = _issue_token(svc, B)
        status, _, _ = svc.get("/v1/memory/list", token=token, tenant=None)
        assert status == 200
        status, _, _ = svc.get("/v1/memory/list", token=token, tenant=None)
        assert status == 429
        status, _, _ = svc.get("/v1/memory/list", tenant=A)
        assert status == 200


def test_google_token_without_header_on_get_stays_400():
    with LiveServer(_config()) as svc:
        status, _, raw = svc.get("/v1/memory/list", tenant=None)
        assert status == 400
        assert _json(raw)["code"] == "tenant_context_invalid"


@pytest.mark.parametrize("via_principal_list", [False, True])
def test_session_suspended_only_ranch_403(via_principal_list):
    users = [User(id="u1", principal_id=PRINCIPAL)]
    tenants = [Tenant(id=A, slug="a", display_name="Tenant A", status="suspended")]
    memberships = [TenantMembership(tenant_id=A, user_id="u1", role=Role.OWNER)]
    sessions = RecordingSessionStore()
    config = _config(store=_tenancy_store(users, tenants, memberships,
                                           via_principal_list=via_principal_list),
                     sessions=sessions)
    with LiveServer(config) as svc:
        for tenant in (None, A):
            status, _, raw = svc.post("/v1/session", tenant=tenant)
            assert status == 403, (via_principal_list, tenant)
            assert _json(raw)["code"] == "tenant_not_authorized"
        assert sessions.issues == []


@pytest.mark.parametrize("via_principal_list", [False, True])
def test_session_hint_at_suspended_ranch_403(via_principal_list):
    users, tenants, memberships = _suspended_ranch_facts()
    sessions = RecordingSessionStore()
    config = _config(store=_tenancy_store(users, tenants, memberships,
                                           via_principal_list=via_principal_list),
                     sessions=sessions)
    with LiveServer(config) as svc:
        status, _, raw = svc.post("/v1/session", tenant=B)
        assert status == 403
        assert _json(raw)["code"] == "tenant_not_authorized"
        assert sessions.issues == []


@pytest.mark.parametrize("via_principal_list", [False, True])
def test_session_active_plus_suspended_no_hint_issues_active(via_principal_list):
    users, tenants, memberships = _suspended_ranch_facts()
    sessions = RecordingSessionStore()
    config = _config(store=_tenancy_store(users, tenants, memberships,
                                           via_principal_list=via_principal_list),
                     sessions=sessions)
    with LiveServer(config) as svc:
        status, heads, raw = svc.post("/v1/session", tenant=None)
        assert status == 200
        assert _json(raw)["tenant_id"] == A
        assert heads["x-ranch-tenant"] == A
        assert sessions.issues == [A]


@pytest.mark.parametrize("via_principal_list", [False, True])
def test_session_active_plus_suspended_hint_chooses_active(via_principal_list):
    users, tenants, memberships = _suspended_ranch_facts()
    sessions = RecordingSessionStore()
    config = _config(store=_tenancy_store(users, tenants, memberships,
                                           via_principal_list=via_principal_list),
                     sessions=sessions)
    with LiveServer(config) as svc:
        status, heads, raw = svc.post("/v1/session", tenant=A)
        assert status == 200
        assert _json(raw)["tenant_id"] == A
        assert heads["x-ranch-tenant"] == A
        assert sessions.issues == [A]


def test_list_excludes_archived_memories():
    made = save_memory(Memory(module="property", category="maintenance",
                              title="Old fence note", body="Retired note.",
                              tenant_id=A, memory_type="event", tags=[],
                              id="arch-list-1"))
    archive_dir = memory_store_mod.MEMORIES_DIR / "_archive" / "property"
    archive_dir.mkdir(parents=True)
    source = Path(made.path)
    source.rename(archive_dir / source.name)
    with LiveServer(_config()) as svc:
        status, _, raw = svc.get("/v1/memory/list", tenant=A)
        assert status == 200
        assert _json(raw)["count"] == 0
        assert _json(raw)["memories"] == []
        status, _, raw = svc.get("/v1/memory/fetch/arch-list-1", tenant=A)
        assert status == 404
        assert _json(raw)["code"] == "memory_not_found"


def test_fetch_ignores_archived_memories():
    made = save_memory(Memory(module="property", category="maintenance",
                              title="Old fence note", body="Retired note.",
                              tenant_id=A, memory_type="event", tags=[],
                              id="arch-only-1"))
    archive_dir = memory_store_mod.MEMORIES_DIR / "_archive" / "property"
    archive_dir.mkdir(parents=True)
    source = Path(made.path)
    source.rename(archive_dir / source.name)
    with LiveServer(_config()) as svc:
        status, _, raw = svc.get("/v1/memory/fetch/arch-only", tenant=A)
        assert status == 404
        assert _json(raw)["code"] == "memory_not_found"


def test_request_id_echo_is_sanitized():
    with LiveServer(_config()) as svc:
        _, heads, _ = svc.get("/v1/memory/list", tenant=A,
                              headers={"X-Request-ID": "client-req.42"})
        assert heads["x-request-id"] == "client-req.42"
        for bad in ("x" * 129, "has space", "semi;colon"):
            _, heads, raw = svc.get("/v1/memory/fetch/missing-id-xyz", tenant=A,
                                    headers={"X-Request-ID": bad})
            assert heads["x-request-id"] != bad
            assert _json(raw)["request_id"] == heads["x-request-id"]

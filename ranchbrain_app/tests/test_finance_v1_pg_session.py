"""Ranch Finance v1 PostgreSQL read session: statement order, binding, rollback."""

from datetime import date, datetime, timezone
from decimal import Decimal
from uuid import UUID

import pytest

from ranchbrain.finance.model import DomainCode, RecordStatus
from ranchbrain.finance.pg_session import finance_read_session
from ranchbrain.tenancy import Role, TenantContext

CONTEXT = TenantContext(
    tenant_id="11111111-1111-4111-8111-111111111111",
    user_id="user-a",
    principal_id="22222222-2222-4222-8222-222222222222",
    role=Role.VIEWER,
    environment="development",
    correlation_id="req-1",
)
HOSTILE = "x'); DROP TABLE ranchos.finance_transactions; --"


class FakeCursor:
    def __init__(self, results):
        self.statements = []
        self._results = list(results)
        self._current = []
        self.closed = False

    def execute(self, sql, parameters=()):
        self.statements.append((" ".join(sql.split()), parameters))
        # Only repository queries read ranchos tables; prologue statements return nothing.
        self._current = self._results.pop(0) if "FROM RANCHOS" in sql.upper() else []

    def fetchall(self):
        return self._current

    def fetchone(self):
        return self._current[0] if self._current else None

    def close(self):
        self.closed = True


class FakeConnection:
    def __init__(self, results=(), autocommit=False):
        self.autocommit = autocommit
        self.cursor_obj = FakeCursor(results)
        self.rolled_back = 0

    def cursor(self):
        return self.cursor_obj

    def rollback(self):
        self.rolled_back += 1


def test_session_prologue_is_read_only_runtime_and_tenant_bound():
    conn = FakeConnection()
    with finance_read_session(conn, CONTEXT):
        pass
    sql = [s for s, _ in conn.cursor_obj.statements]
    assert sql[0] == "SET TRANSACTION READ ONLY"
    assert conn.cursor_obj.statements[1:5] == [
        ("SELECT set_config(%s, %s, true)", ("role", "ranchos_dev_runtime")),
        ("SELECT set_config(%s, %s, true)", ("ranchos.principal_id", CONTEXT.principal_id)),
        ("SELECT set_config(%s, %s, true)", ("ranchos.environment", "development")),
        ("SELECT set_config(%s, %s, true)", ("ranchos.tenant_id", CONTEXT.tenant_id)),
    ]
    assert conn.rolled_back == 1 and conn.cursor_obj.closed


def test_session_rolls_back_on_error():
    conn = FakeConnection()
    with pytest.raises(RuntimeError):
        with finance_read_session(conn, CONTEXT):
            raise RuntimeError("boom")
    assert conn.rolled_back == 1 and conn.cursor_obj.closed


def test_autocommit_connection_is_refused():
    with pytest.raises(RuntimeError):
        with finance_read_session(FakeConnection(autocommit=True), CONTEXT):
            pass


def test_transactions_query_binds_every_value_and_maps_rows():
    row = (
        UUID("33333333-3333-4333-8333-333333333333"), UUID("44444444-4444-4444-8444-444444444444"),
        "ranch", None, None, "-12.50", "USD", "Feed", date(2026, 10, 3), "active",
    )
    conn = FakeConnection(results=[[row]])
    with finance_read_session(conn, CONTEXT) as repo:
        [tx] = repo.transactions_between(
            date(2026, 10, 1), date(2026, 11, 1), frozenset({DomainCode.ZERO_G, DomainCode.RANCH}), HOSTILE
        )
    sql, params = conn.cursor_obj.statements[-1]
    assert HOSTILE not in sql and "2026-10" not in sql
    assert params == (date(2026, 10, 1), date(2026, 11, 1), ["ranch", "zero_g"], HOSTILE, HOSTILE)
    assert "t.tenant_id = ranchos.require_uuid_setting('ranchos.tenant_id')" in sql
    assert tx.id == "33333333-3333-4333-8333-333333333333"
    assert tx.amount == Decimal("-12.50") and tx.domain_code is DomainCode.RANCH
    assert tx.record_status is RecordStatus.ACTIVE


def test_confirmed_transfer_ids_binds_sorted_list_and_skips_empty():
    conn = FakeConnection(results=[[("t-a",)]])
    with finance_read_session(conn, CONTEXT) as repo:
        assert repo.confirmed_transfer_ids(frozenset()) == frozenset()
        assert repo.confirmed_transfer_ids(frozenset({"t-b", "t-a"})) == frozenset({"t-a"})
    sql, params = conn.cursor_obj.statements[-1]
    assert "status = 'confirmed'" in sql and params == (["t-a", "t-b"],)


def test_revision_reports_latest_change_and_count():
    stamp = datetime(2026, 10, 3, 12, 0, tzinfo=timezone.utc)
    conn = FakeConnection(results=[[(stamp, 7)], [(None, 0)]])
    with finance_read_session(conn, CONTEXT) as repo:
        assert repo.revision() == f"{stamp.isoformat()}|7"
        assert repo.revision() == "empty|0"

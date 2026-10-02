"""Tenant isolation proof for P2 (memory store, index, search, graph, CLI).

Storage is redirected to tmp_path by tests/conftest.py, so every case runs
against a fresh empty tree. Membership and authorization live in
test_tenancy.py; here tenants are plain ids and the assertions are about
visibility and fail-closed behavior.

Titles, tags, and categories avoid the word "test" unless a case targets the
test-memory filter, because suggest_relationships hides test-like memories
by default.
"""

import json
from pathlib import Path

import pytest

from ranchbrain import memory_store as memory_store_mod
from ranchbrain.cli import cli_tenant_id, memory_cmd, remember_cmd
from ranchbrain.graph_search import graph_search
from ranchbrain.indexer import (
    build_index,
    index_path_for_profile,
    stamp_legacy_index_tenant,
)
from ranchbrain.memory_store import (
    find_backlinks,
    find_memory_by_id,
    link_memories,
    list_memories,
    memory_stats,
    remember,
    save_memory,
    stamp_legacy_memories_tenant,
)
from ranchbrain.models import Memory
from ranchbrain.profile_manager import PROFILES, IndexProfile
from ranchbrain.relationship_suggestions import suggest_relationships
from ranchbrain.search_engine import search as index_search
from ranchbrain.tenancy import TenancyError

A = "tenant-a"
B = "tenant-b"


def seed(title, body, tenant_id=A, tags=None, module="property",
         category="maintenance", memory_type="event"):
    return remember(
        module=module,
        category=category,
        title=title,
        body=body,
        memory_type=memory_type,
        tags=tags or [],
        tenant_id=tenant_id,
    )


@pytest.fixture()
def seeded_profile(tmp_path, monkeypatch):
    root = tmp_path / "docs"
    (root / "field").mkdir(parents=True)
    (root / "field" / "notes.txt").write_text("Alpha pasture fence line\nSecond line\n")
    (root / "field" / "barn.txt").write_text("Beta trough valve\n")
    monkeypatch.setitem(
        PROFILES,
        "iso",
        IndexProfile(
            name="iso",
            roots=(root,),
            include_top=set(),
            exclude_top=set(),
            exclude_any=set(),
        ),
    )
    return "iso"


@pytest.mark.parametrize("bad", [None, "", "   "])
def test_memory_store_apis_fail_closed_without_tenant(bad):
    tenant = bad if bad is not None else None
    with pytest.raises(TenancyError):
        remember(module="property", category="maintenance", title="t",
                 body="b", tenant_id=tenant)
    with pytest.raises(TenancyError):
        save_memory(Memory(module="property", category="maintenance",
                           title="t", body="b", tenant_id=bad or ""))
    with pytest.raises(TenancyError):
        list_memories(tenant_id=tenant)
    with pytest.raises(TenancyError):
        find_memory_by_id("abc123", tenant_id=tenant)
    with pytest.raises(TenancyError):
        memory_stats(tenant_id=tenant)
    with pytest.raises(TenancyError):
        link_memories("abc123", "def456", tenant_id=tenant)
    with pytest.raises(TenancyError):
        find_backlinks("abc123", tenant_id=tenant)
    with pytest.raises(TenancyError):
        stamp_legacy_memories_tenant(bad if bad is not None else None)


@pytest.mark.parametrize("bad", [None, "", "   "])
def test_search_and_graph_fail_closed_without_tenant(bad):
    tenant = bad if bad is not None else None
    with pytest.raises(TenancyError):
        graph_search("pasture", tenant_id=tenant)
    with pytest.raises(TenancyError):
        suggest_relationships("abc123", tenant_id=tenant)
    with pytest.raises(TenancyError):
        index_search("pasture", tenant_id=tenant)
    with pytest.raises(TenancyError):
        build_index("knowledge", tenant_id=tenant)
    with pytest.raises(TenancyError):
        stamp_legacy_index_tenant("knowledge", bad if bad is not None else None)


def test_cross_tenant_invisibility():
    a1 = seed("Shared title", "Alpha body one", tags=["alpha"], tenant_id=A)
    a2 = seed("Second alpha", "Alpha body two", tags=["alpha"], tenant_id=A)
    b1 = seed("Shared title", "Beta body", tags=["beta"], tenant_id=B)

    assert {m.id for _, m in list_memories(tenant_id=B)} == {b1.memory_id}
    assert {m.id for _, m in list_memories(tenant_id=A)} == {a1.memory_id, a2.memory_id}

    assert find_memory_by_id(a1.memory_id, tenant_id=B) is None
    found = find_memory_by_id(a1.memory_id, tenant_id=A)
    assert found is not None and found[1].id == a1.memory_id

    assert memory_stats(tenant_id=B)["total"] == 1
    assert memory_stats(tenant_id=A)["total"] == 2


def test_duplicates_scoped_per_tenant():
    kwargs = dict(module="property", category="maintenance", title="Fence",
                  body="Mend the north fence", tags=["fence"])
    first = remember(**kwargs, tenant_id=A)
    assert first.status == "created"
    again = remember(**kwargs, tenant_id=A)
    assert again.status == "duplicate"
    assert again.path == first.path
    other = remember(**kwargs, tenant_id=B)
    assert other.status == "created"


def test_links_and_backlinks_confined_to_tenant():
    src = seed("Alpha source", "source body", tenant_id=A)
    dst = seed("Alpha target", "target body", tenant_id=A)
    other = seed("Beta other", "target body", tenant_id=B)

    assert link_memories(src.memory_id, dst.memory_id, tenant_id=A) is True
    assert link_memories(src.memory_id, dst.memory_id, tenant_id=A) is False

    with pytest.raises(ValueError):
        link_memories(src.memory_id, other.memory_id, tenant_id=A)

    backlinks = find_backlinks(dst.memory_id, tenant_id=A)
    assert len(backlinks) == 1
    assert backlinks[0][1].id == src.memory_id

    with pytest.raises(ValueError):
        find_backlinks(dst.memory_id, tenant_id=B)


def test_graph_search_respects_tenant():
    src = seed("Orchard stump", "Grind the orchard stump",
               tags=["orchard"], tenant_id=A)
    dst = seed("Mulch delivery", "Mulch delivery scheduled",
               tags=["delivery"], tenant_id=A)
    link_memories(src.memory_id, dst.memory_id, tenant_id=A)
    seed("Unrelated beta", "Nothing shared here", tenant_id=B)

    assert graph_search("orchard", tenant_id=B) == []

    nodes = graph_search("orchard", tenant_id=A)
    assert {node.memory.id for node in nodes} == {src.memory_id, dst.memory_id}
    assert any(node.depth == 1 for node in nodes)


def test_suggestions_stay_in_tenant():
    src = seed("Barn roof", "Inspect the barn roof",
               tags=["barn-ops"], tenant_id=A)
    candidate = seed("Barn gutters", "Clean the barn gutters",
                     tags=["barn-ops"], tenant_id=A)
    seed("Barn paint", "Repaint the barn", tags=["barn-ops"], tenant_id=B)

    got = suggest_relationships(src.memory_id, min_score=20, tenant_id=A)
    ids = {item.memory.id for item in got}
    assert candidate.memory_id in ids
    beta_ids = {memory.id for _, memory in list_memories(tenant_id=B)}
    assert ids.isdisjoint(beta_ids)

    with pytest.raises(ValueError):
        suggest_relationships(src.memory_id, tenant_id=B)


def test_build_index_stamps_tenant(seeded_profile):
    records = build_index(seeded_profile, tenant_id=A)
    assert records
    assert all(record["tenant_id"] == A for record in records)
    stored = json.loads(index_path_for_profile(seeded_profile).read_text())
    assert stored
    assert all(record["tenant_id"] == A for record in stored)


def test_search_filters_by_tenant(seeded_profile):
    build_index(seeded_profile, tenant_id=A)
    path = index_path_for_profile(seeded_profile)
    records = json.loads(path.read_text())
    # Simulate a stamped mixed-tenant file: barn.txt belongs to tenant B.
    for record in records:
        if record["relative_path"].endswith("barn.txt"):
            record["tenant_id"] = B
    path.write_text(json.dumps(records))

    hits_a, _ = index_search("pasture", profile=seeded_profile, tenant_id=A)
    assert hits_a
    assert all(hit["tenant_id"] == A for hit in hits_a)

    hits_b, _ = index_search("pasture", profile=seeded_profile, tenant_id=B)
    assert hits_b == []

    hits_b2, _ = index_search("trough", profile=seeded_profile, tenant_id=B)
    assert hits_b2
    assert all(hit["tenant_id"] == B for hit in hits_b2)

    assert {"path", "line", "text", "tenant_id",
            "modified_at", "indexed_at"} <= set(hits_a[0])


def test_stamp_memories_idempotent():
    legacy = Memory(module="property", category="maintenance", title="Legacy",
                    body="Old record", tenant_id="")
    target = memory_store_mod.MEMORIES_DIR / "legacy.json"
    target.write_text(legacy.to_json())

    assert stamp_legacy_memories_tenant(A) == 1
    assert stamp_legacy_memories_tenant(A) == 0
    assert json.loads(target.read_text())["tenant_id"] == A


def test_stamp_memories_refuses_foreign_tenant():
    seed("Beta record", "Owned by B", tenant_id=B)
    with pytest.raises(TenancyError):
        stamp_legacy_memories_tenant(A)


def test_stamp_index_records():
    assert stamp_legacy_index_tenant("missing-profile", A) == 0

    prof_path = index_path_for_profile("legacyprof")
    prof_path.parent.mkdir(parents=True, exist_ok=True)
    prof_path.write_text(json.dumps([
        {"path": "x", "tenant_id": ""},
        {"path": "y", "tenant_id": B},
    ]))
    with pytest.raises(TenancyError):
        stamp_legacy_index_tenant("legacyprof", A)

    prof_path.write_text(json.dumps([{"path": "x", "tenant_id": ""}]))
    assert stamp_legacy_index_tenant("legacyprof", A) == 1
    assert stamp_legacy_index_tenant("legacyprof", A) == 0


def test_storage_stays_under_tmp(tmp_path):
    result = seed("Redirect proof", "nowhere near live data")
    assert str(Path(result.path)).startswith(str(tmp_path))


def test_cli_tenant_flag_and_env(monkeypatch):
    assert cli_tenant_id("  tenant-a ") == "tenant-a"
    monkeypatch.delenv("RANCHBRAIN_TENANT", raising=False)
    monkeypatch.setenv("RANCHBRAIN_TENANT", "tenant-b")
    assert cli_tenant_id("") == "tenant-b"


def test_cli_tenant_missing_exits_2(monkeypatch):
    monkeypatch.delenv("RANCHBRAIN_TENANT", raising=False)
    with pytest.raises(SystemExit) as exc:
        cli_tenant_id("")
    assert exc.value.code == 2


def test_memory_cmd_requires_tenant(monkeypatch):
    monkeypatch.delenv("RANCHBRAIN_TENANT", raising=False)
    with pytest.raises(SystemExit) as exc:
        memory_cmd(["show", "abc123"])
    assert exc.value.code == 2


def test_memory_cmd_list_and_stats_require_tenant(monkeypatch):
    monkeypatch.delenv("RANCHBRAIN_TENANT", raising=False)
    with pytest.raises(SystemExit) as exc:
        memory_cmd(["list"])
    assert exc.value.code == 2
    with pytest.raises(SystemExit) as exc:
        memory_cmd(["stats"])
    assert exc.value.code == 2


def test_cli_positive_paths(monkeypatch):
    monkeypatch.delenv("RANCHBRAIN_TENANT", raising=False)
    created = seed("CLI record", "Through the CLI", tenant_id=A)
    memory_cmd(["show", created.memory_id, "--tenant", A])
    memory_cmd(["list", "--tenant", A])
    memory_cmd(["stats", "--tenant", A])
    other = seed("CLI other", "Link target", tenant_id=A)
    memory_cmd(["link", created.memory_id, other.memory_id, "--tenant", A])
    remember_cmd(["--module", "property", "--title", "CLI remember",
                  "--body", "Remembered", "--tenant", A])

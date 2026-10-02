from ranchbrain.indexer import build_index
from ranchbrain.profile_manager import PROFILES, IndexProfile
from ranchbrain.search_engine import search

TENANT = "test-tenant"


def _seeded(tmp_path, monkeypatch):
    root = tmp_path / "docs"
    root.mkdir()
    (root / "time-machine.txt").write_text("Time Machine backup completed\n")
    (root / "code.txt").write_text("class MemoryResult:\n")
    monkeypatch.setitem(
        PROFILES,
        "search-test",
        IndexProfile(
            name="search-test",
            roots=(root,),
            include_top=set(),
            exclude_top=set(),
            exclude_any=set(),
        ),
    )
    build_index("search-test", tenant_id=TENANT)
    return "search-test"


def test_profile_search_finds_hit(tmp_path, monkeypatch):
    profile = _seeded(tmp_path, monkeypatch)
    hits, total = search("Time Machine", profile=profile, tenant_id=TENANT)
    assert isinstance(hits, list)
    assert isinstance(total, int)
    assert total >= 1
    assert any("Time Machine" in hit["text"] for hit in hits)


def test_profile_search_second_term(tmp_path, monkeypatch):
    profile = _seeded(tmp_path, monkeypatch)
    hits, total = search("MemoryResult", profile=profile, tenant_id=TENANT)
    assert isinstance(hits, list)
    assert isinstance(total, int)
    assert total >= 1

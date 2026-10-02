from ranchbrain.indexer import build_index
from ranchbrain.profile_manager import PROFILES, IndexProfile
from ranchbrain.search_engine import search

TENANT = "test-tenant"


def test_search_returns_line_matches(tmp_path, monkeypatch):
    root = tmp_path / "docs"
    root.mkdir()
    (root / "note.txt").write_text("nightly backup completed\n")
    monkeypatch.setitem(
        PROFILES,
        "engine-test",
        IndexProfile(
            name="engine-test",
            roots=(root,),
            include_top=set(),
            exclude_top=set(),
            exclude_any=set(),
        ),
    )
    build_index("engine-test", tenant_id=TENANT)
    hits, total = search("backup", profile="engine-test", tenant_id=TENANT)
    assert isinstance(hits, list)
    assert isinstance(total, int)
    assert total >= 1
    first = hits[0]
    assert isinstance(first["path"], str)
    assert isinstance(first["line"], int)
    assert isinstance(first["text"], str)

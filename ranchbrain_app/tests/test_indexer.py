from ranchbrain.indexer import build_index, index_path_for_profile, load_index
from ranchbrain.profile_manager import PROFILES, IndexProfile

TENANT = "test-tenant"


def _register(tmp_path, monkeypatch):
    root = tmp_path / "docs"
    root.mkdir()
    (root / "note.txt").write_text("Orchard fence line\n")
    monkeypatch.setitem(
        PROFILES,
        "iso-test",
        IndexProfile(
            name="iso-test",
            roots=(root,),
            include_top=set(),
            exclude_top=set(),
            exclude_any=set(),
        ),
    )
    return "iso-test"


def test_build_index_creates_json(tmp_path, monkeypatch):
    profile = _register(tmp_path, monkeypatch)
    records = build_index(profile, tenant_id=TENANT)
    assert isinstance(records, list)
    assert len(records) == 1
    assert index_path_for_profile(profile).exists()


def test_load_index_returns_list(tmp_path, monkeypatch):
    profile = _register(tmp_path, monkeypatch)
    build_index(profile, tenant_id=TENANT)
    records = load_index(profile)
    assert isinstance(records, list)
    assert len(records) == 1

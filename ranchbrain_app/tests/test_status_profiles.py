from ranchbrain.indexer import build_index, load_index
from ranchbrain.profile_manager import PROFILES, IndexProfile

TENANT = "test-tenant"


def test_profile_indexes_exist(tmp_path, monkeypatch):
    for name in ("knowledge", "code", "all"):
        root = tmp_path / name
        root.mkdir()
        (root / "note.txt").write_text(f"{name} line\n")
        monkeypatch.setitem(
            PROFILES,
            name,
            IndexProfile(
                name=name,
                roots=(root,),
                include_top=set(),
                exclude_top=set(),
                exclude_any=set(),
            ),
        )
        build_index(name, tenant_id=TENANT)
    assert len(load_index("knowledge")) > 0
    assert len(load_index("code")) > 0
    assert len(load_index("all")) > 0

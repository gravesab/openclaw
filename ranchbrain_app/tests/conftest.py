"""Autouse storage isolation for the RanchBrain test suite.

Every test gets a fresh data tree under pytest's tmp_path. No test may read
or write the live ~/ai/projects/openclaw/ranchbrain tree. Profile selection
stays explicit per test; only storage roots are redirected here.
"""

import pytest

from ranchbrain import graph_search as graph_search_mod
from ranchbrain import indexer as indexer_mod
from ranchbrain import memory_store as memory_store_mod


@pytest.fixture(autouse=True)
def _isolated_ranchbrain_storage(tmp_path, monkeypatch):
    data = tmp_path / "ranchbrain-data"
    memories = data / "memories"
    memories.mkdir(parents=True)
    # graph_search binds MEMORIES_DIR at import; patch both bindings.
    monkeypatch.setattr(memory_store_mod, "MEMORIES_DIR", memories)
    monkeypatch.setattr(graph_search_mod, "MEMORIES_DIR", memories)
    monkeypatch.setattr(indexer_mod, "RANCHBRAIN_DATA", data)
    monkeypatch.setattr(indexer_mod, "INDEX_PATH", data / "index" / "index.json")
    return data

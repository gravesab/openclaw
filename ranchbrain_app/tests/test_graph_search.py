from ranchbrain.graph_search import graph_search
from ranchbrain.memory_store import link_memories, remember

TENANT = "test-tenant"


def _seed_linked_pair():
    source = remember(
        module="property", category="maintenance", title="Burned large stump",
        body="Stump removal record.", memory_type="event", tags=["stump"],
        tenant_id=TENANT,
    )
    target = remember(
        module="property", category="maintenance", title="Mulch delivery",
        body="Mulch delivery scheduled.", memory_type="event", tags=["delivery"],
        tenant_id=TENANT,
    )
    link_memories(source.memory_id, target.memory_id, tenant_id=TENANT)
    return source, target


def test_graph_search_returns_nodes():
    _seed_linked_pair()
    nodes = graph_search("Burned large stump", max_depth=1, tenant_id=TENANT)

    assert isinstance(nodes, list)
    assert any(
        node.memory.title == "Burned large stump"
        and node.depth == 0
        for node in nodes
    )


def test_graph_search_expands_one_hop():
    _seed_linked_pair()
    nodes = graph_search("Burned large stump", max_depth=1, tenant_id=TENANT)

    assert any(node.depth == 1 for node in nodes)


def test_graph_search_depth_zero():
    _seed_linked_pair()
    nodes = graph_search("Burned large stump", max_depth=0, tenant_id=TENANT)

    assert nodes
    assert all(node.depth == 0 for node in nodes)


def test_graph_search_rejects_large_depth():
    import pytest

    with pytest.raises(ValueError):
        graph_search("Burned large stump", max_depth=6)


def test_graph_search_rejects_negative_depth():
    import pytest

    with pytest.raises(ValueError):
        graph_search("Burned large stump", max_depth=-1)

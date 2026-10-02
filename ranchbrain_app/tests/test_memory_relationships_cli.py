from ranchbrain.memory_store import find_memory_by_id, link_memories, remember

TENANT = "test-tenant"


def test_relationships_field_exists():
    source = remember(
        module="property", category="maintenance", title="CLI rel source",
        body="Source.", memory_type="event", tags=["cli-rel"],
        tenant_id=TENANT,
    )
    target = remember(
        module="property", category="maintenance", title="CLI rel target",
        body="Target.", memory_type="event", tags=["cli-rel"],
        tenant_id=TENANT,
    )
    link_memories(source.memory_id, target.memory_id, tenant_id=TENANT)
    result = find_memory_by_id(source.memory_id, tenant_id=TENANT)
    assert result is not None
    _, memory = result
    assert hasattr(memory, "relationships")
    assert len(memory.relationships) == 1
